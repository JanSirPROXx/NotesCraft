import NoteCraftCore
import SwiftUI

// A PDF of a whole notebook is minutes of PDFKit work on a full one, so it never runs on the main
// actor and not on `DocumentRenderWorker` either: that one also saves PDFs and makes the library's
// covers, which would wait behind an export.
actor ExportWorker {
  static let shared = ExportWorker()

  // Cancellation is looked at after every page and once more when the file is written: PDFKit
  // writes a document in one call that cannot be stopped, so a cancel that arrives during it is
  // answered when it returns, and the bytes are dropped.
  func render(
    _ package: NotebookPackage, report: @escaping @Sendable (ExportProgress) -> Void
  ) throws -> Data {
    let data = try autoreleasepool {
      try PDFEditor.export(package) { progress in
        try Task.checkCancellation()
        report(progress)
      }
    }
    try Task.checkCancellation()
    return data
  }
}

// One export at a time; what the sheet shows while it runs.
@MainActor @Observable final class ExportJob {
  enum Phase: Equatable {
    case idle
    case rendering(ExportProgress)
    case stopping
  }
  private(set) var phase = Phase.idle
  var isRunning: Bool { phase != .idle }
  private var task: Task<Void, Never>?

  // `finished` is called on the main actor with the bytes or the reason it failed, and not at all
  // for an export that was cancelled.
  func start(
    _ package: NotebookPackage, plan: ExportPlan,
    finished: @escaping @MainActor (Result<Data, any Error>) -> Void
  ) {
    guard !isRunning else { return }
    let cut: NotebookPackage
    do { cut = try plan.package(from: package) } catch {
      finished(.failure(error))
      return
    }
    phase = .rendering(ExportProgress(completed: 0, total: plan.count))
    task = Task { [weak self] in
      let result: Result<Data, any Error>
      do {
        result = .success(
          try await ExportWorker.shared.render(cut) { progress in
            Task { @MainActor in self?.advance(progress) }
          })
      } catch { result = .failure(error) }
      guard let self else { return }
      let wasCancelled = phase == .stopping
      phase = .idle
      task = nil
      if !wasCancelled { finished(result) }
    }
  }

  func cancel() {
    guard case .rendering = phase else { return }
    phase = .stopping
    task?.cancel()
  }

  // Reports hop to the main actor one task each and may land late; a page count never goes down.
  private func advance(_ progress: ExportProgress) {
    guard case .rendering(let shown) = phase, progress.completed > shown.completed else { return }
    phase = .rendering(progress)
  }
}
