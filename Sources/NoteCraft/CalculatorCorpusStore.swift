import NoteCraftCore
import Observation
import SwiftUI

// The reader's handwriting samples for the calculator pen, kept in one file in Application
// Support. The recognizer reads against the stock shapes and these samples; every sample added
// is used from the next calculation on.
@MainActor @Observable final class CalculatorCorpusStore {
  static let shared = CalculatorCorpusStore()

  private(set) var corpus = Corpus()
  let fileURL: URL
  @ObservationIgnored private var classifier: SymbolClassifier?

  init(fileURL: URL? = nil) {
    let base =
      fileURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoteCraft", isDirectory: true)
      .appendingPathComponent("calculator-corpus.json")
    self.fileURL = base
    #if DEBUG
      if CommandLine.arguments.contains("--ui-test-reset-input") {
        try? FileManager.default.removeItem(at: base)
      }
    #endif
    if let data = try? Data(contentsOf: base), let loaded = try? Corpus.decoded(from: data) {
      corpus = loaded
    }
  }

  // Reads with the stock shapes and the reader's own symbols. The templates are made once and
  // again only after a sample was added.
  var recognizer: TemplateRecognizer {
    if classifier == nil { classifier = corpus.classifier() }
    return TemplateRecognizer(classifier: classifier!)
  }

  func warmUp() { _ = recognizer }

  func add(kind: CorpusSample.Kind, label: String, strokes: [[Point]]) {
    guard !strokes.isEmpty, !label.isEmpty else { return }
    corpus.samples.append(CorpusSample(kind: kind, label: label, strokes: strokes))
    if kind == .symbol { classifier = nil }
    save()
  }

  func removeAll() {
    corpus = Corpus()
    classifier = nil
    save()
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try corpus.encoded().write(to: fileURL, options: .atomic)
    } catch {
      // Losing a sample is not worth interrupting writing for; the next save tries again.
    }
  }
}
