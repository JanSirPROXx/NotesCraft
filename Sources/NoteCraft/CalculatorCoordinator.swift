import NoteCraftCore
import Observation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

// Runs a calculation from the moment a "=" is written to the moment the answer is on the page.
//
//   "=" finished → a short wait (the pen may go on writing) → glow + dots → read → answer written
//
// Reading happens off the main actor; this class only holds the few seconds of animation state the
// canvas shows, and hands the answer back through `insert`.
@MainActor @Observable final class CalculatorCoordinator {
  // What the canvases show; filtered by page where it is used.
  private(set) var activities: [CalculatorActivity] = []
  @ObservationIgnored var recognizer: any ExpressionRecognizing = CalculatorCoordinator.launchRecognizer()
  @ObservationIgnored private var waiting: Task<Void, Never>?

  // After the second bar of a "=" the pen may still add to it (an equation, a digit). Anything
  // written within this time cancels the request.
  static let patience = 0.3
  // The dots stay at least this long, so a reading that takes a few milliseconds still shows
  // that something happened instead of flashing.
  static let shortestReading = 0.5
  static let handwritingFont = "Noteworthy-Light"

  // UI tests have no handwriting to read: `--ui-test-calculator-reading=12*3+4` makes every request
  // read that calculation.
  private static func launchRecognizer() -> any ExpressionRecognizing {
    let prefix = "--ui-test-calculator-reading="
    if let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) {
      return FixedRecognizer(String(argument.dropFirst(prefix.count)))
    }
    return NoModelRecognizer()
  }

  // Pen down anywhere: the writing goes on, so a request that is still waiting is dropped.
  func penWentDown() {
    waiting?.cancel()
    waiting = nil
  }

  // `stroke` was just added to the page `pageID`. `page` returns the page as it is now and
  // `insert` puts the answer on it; neither is called after the work has been abandoned.
  func strokeEnded(
    _ stroke: Stroke, pageID: UUID, color: InkColor,
    page: @escaping @MainActor () -> Page?, insert: @escaping @MainActor (TextBox) -> Void
  ) {
    guard stroke.calculator else { return }
    waiting?.cancel()
    waiting = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.patience))
      guard !Task.isCancelled, let self, let current = page(),
        let gathering = CalculatorTrigger.gathering(for: stroke, on: current)
      else { return }
      await run(gathering, pageID: pageID, color: color, page: page, insert: insert)
    }
  }

  private func run(
    _ gathering: Gathering, pageID: UUID, color: InkColor,
    page: @MainActor () -> Page?, insert: @MainActor (TextBox) -> Void
  ) async {
    var activity = CalculatorActivity(pageID: pageID, gathering: gathering, color: color)
    activities.append(activity)
    let started = ContinuousClock.now
    let recognizer = recognizer
    let reading = await Task.detached(priority: .userInitiated) { await recognizer.read(gathering) }.value
    let outcome = Calculator.outcome(for: reading)
    let spent = started.duration(to: .now)
    let wanted = Duration.seconds(Self.shortestReading)
    if spent < wanted { try? await Task.sleep(for: wanted - spent) }

    // The writing may have been erased or moved on while the dots ran; then there is no answer.
    if let current = page(), Set(current.strokes.map(\.id)).isSuperset(of: gathering.strokeIDs) {
      let (font, ascender) = Self.answerFont()
      insert(
        Calculator.answerBox(
          for: outcome, gathering: gathering, color: color, fontName: font, ascender: ascender,
          recognizerVersion: recognizer.version))
    }
    finish(&activity)
  }

  private func finish(_ activity: inout CalculatorActivity) {
    let id = activity.id
    activity.phase = .answered
    if let index = activities.firstIndex(where: { $0.id == id }) { activities[index] = activity }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      self?.activities.removeAll { $0.id == id }
    }
  }

  // The ascender is a fraction of the size, because a text box is placed by its top edge.
  static func answerFont() -> (name: String?, ascender: Double) {
    #if canImport(UIKit)
      if let font = UIFont(name: handwritingFont, size: 100) {
        return (handwritingFont, Double(font.ascender) / 100)
      }
      return (nil, Double(UIFont.systemFont(ofSize: 100).ascender) / 100)
    #else
      if let font = NSFont(name: handwritingFont, size: 100) {
        return (handwritingFont, Double(font.ascender) / 100)
      }
      return (nil, Double(NSFont.systemFont(ofSize: 100).ascender) / 100)
    #endif
  }
}
