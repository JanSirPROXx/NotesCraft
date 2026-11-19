import Foundation
import Testing

@testable import NoteCraftCore

// How the pen reads a reader's own pages: every stroke of exported pages is written again in the order
// it was written, and each "=" that closes a calculation is read like the live pen would read it. The
// numbers written after the "=" are the check: when the pen's answer equals what the reader wrote, the
// reading was right (a wrong reading that gives the right number is rare); when it differs, the pen
// misread something or the writer made a mistake; when nothing could be read, the pen would show "?".
//
//   NOTECRAFT_REALPAGES=<dir of pN.json> NOTECRAFT_REALPAGES_OUT=<report.tsv> \
//     swift test -c release -Xswiftc -enable-testing --filter RealPageAudit
//
// The pages are not in the repository (they are somebody's notes). Each `pN.json` is
// `{"strokes": [{"c": "k", "pl": [[[x, y], ...], ...]}, ...]}` in writing order, polylines being the
// centre lines of one pen stroke, in points; only black strokes (`"c": "k"`) are used.

private let directory = ProcessInfo.processInfo.environment["NOTECRAFT_REALPAGES"]
private let reportPath = ProcessInfo.processInfo.environment["NOTECRAFT_REALPAGES_OUT"]

private struct RawStroke: Decodable {
  var c: String
  var pl: [[[Double]]]
}
private struct RawPage: Decodable { var strokes: [RawStroke] }

// Handwriting in the exported pages is about 7 pt tall; on the iPad it is three times that.
private let scale = 3.0

private func strokes(of page: RawPage) -> [Stroke] {
  var out: [Stroke] = []
  for raw in page.strokes where raw.c == "k" {
    for line in raw.pl where !line.isEmpty {
      var s = Stroke(
        samples: line.map { Sample(point: Point($0[0] * scale, $0[1] * scale)) }, width: 0.9 * scale)
      s.calculator = true
      out.append(s)
    }
  }
  return out
}

private enum Verdict: String, CaseIterable {
  case verified, differs, unread, resultUnread, noResult, noGathering
}

@Test(.enabled(if: directory != nil)) func theReadersOwnPagesAreReadAndChecked() throws {
  let dir = try #require(directory)
  let reader = LineReader(classifier: NeuralSymbolClassifier())
  var counts: [Verdict: Int] = [:]
  var perPage: [Int: [Verdict: Int]] = [:]
  var rows: [String] = ["page\tstroke\tverdict\tread\tshown\tresult\tresultText"]

  func value(_ text: String) -> Decimal? {
    if case .success(let v) = Expression.evaluate(text) { return v.value }
    return nil
  }

  for n in 1...133 {
    guard let data = FileManager.default.contents(atPath: "\(dir)/p\(n).json"),
      let raw = try? JSONDecoder().decode(RawPage.self, from: data)
    else { continue }
    let all = strokes(of: raw)
    // Every "=" of the page, whatever was written before or after it: what stands left of it is the
    // calculation, what stands right of it on its line the result. The live pen only fires when the
    // "=" is written last; here the line is read as if it had been.
    for (i, stroke) in all.enumerated() {
      guard let mark = CalculatorTrigger.equalsMark(endingWith: stroke, in: Array(all[0...i])) else { continue }
      let markRight = mark.bounds.x + mark.bounds.width
      let ids = Set(mark.strokeIDs)
      let open = all.filter { ids.contains($0.id) || $0.bounds.x + $0.bounds.width <= markRight - 0.25 * mark.bounds.width }
      guard let gathering = CalculatorTrigger.gather(mark: mark, open: open, solved: [], barriers: []) else {
        counts[.noGathering, default: 0] += 1
        perPage[n, default: [:]][.noGathering, default: 0] += 1
        rows.append("\(n)\t\(i)\tnoGathering\t\t\t\t")
        continue
      }

      let reading = reader.read(gathering)
      let outcome = Calculator.outcome(for: reading)

      // What stands after the "=", on its line: strokes in the band, taken left to right while the gap stays small.
      let cy = gathering.mark.bounds.y + gathering.mark.bounds.height / 2
      let right = gathering.mark.bounds.x + gathering.mark.bounds.width
      let candidates = all.filter {
        let b = $0.bounds
        return !ids.contains($0.id) && abs(b.y + b.height / 2 - cy) <= 0.9 * gathering.glyphHeight
          && b.x >= right - 0.3 * gathering.glyphHeight
      }.sorted { $0.bounds.x < $1.bounds.x }
      var written: [Stroke] = []
      var edge = right
      for s in candidates {
        let b = s.bounds
        guard b.x - edge <= 1.3 * gathering.glyphHeight, written.count < 24 else { break }
        written.append(s)
        edge = max(edge, b.x + b.width)
      }
      // Writing order inside the result matters to the reader, so it is restored.
      let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
      written.sort { order[$0.id]! < order[$1.id]! }

      var verdict = Verdict.noResult
      var resultText = ""
      if !written.isEmpty {
        let after = Gathering(
          strokes: written, writing: written, mark: gathering.mark, bounds: gathering.mark.bounds,
          glyphHeight: gathering.glyphHeight, baseline: gathering.baseline)
        let resultReading = reader.read(after)
        resultText = resultReading?.expression ?? ""
        if outcome.state != .done {
          verdict = .unread
        } else if let a = value(outcome.expression), let b = resultReading.flatMap({ value($0.expression) }) {
          verdict = abs(a - b) < 0.000001 ? .verified : .differs
        } else {
          verdict = .resultUnread
        }
      }
      counts[verdict, default: 0] += 1
      perPage[n, default: [:]][verdict, default: 0] += 1
      rows.append(
        "\(n)\t\(i)\t\(verdict.rawValue)\t\(reading?.expression ?? "")\t\(outcome.text)\t\(resultText)\t\(written.count)")
    }
  }

  let total = counts.values.reduce(0, +)
  let withResult = total - counts[.noResult, default: 0] - counts[.noGathering, default: 0]
  var summary = "\"=\" written: \(total), of those with a calculation gathered: \(total - counts[.noGathering, default: 0]), with something written after it: \(withResult)\n"
  for v in Verdict.allCases { summary += "  \(v.rawValue): \(counts[v, default: 0])\n" }
  let best = perPage.sorted { ($0.value[.verified] ?? 0) > ($1.value[.verified] ?? 0) }.prefix(12)
    .map { "p\($0.key): \($0.value[.verified] ?? 0) of \($0.value.values.reduce(0, +))" }
  summary += "  pages with most verified: \(best.joined(separator: ", "))\n"
  print(summary)
  if let reportPath { try? rows.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8) }
  #expect(total > 0)
}

// What the pretrained network says of each cut symbol of the same pages: `NOTECRAFT_SYMBOLS_IN` is a list
// of `{"id", "pl": [[[x, y], ...], ...]}` (one entry per symbol, one polyline per stroke), the report has
// one line per symbol: id, the 17 probabilities (the 16 symbols, then "not a symbol").
private let symbolsIn = ProcessInfo.processInfo.environment["NOTECRAFT_SYMBOLS_IN"]
private let symbolsOut = ProcessInfo.processInfo.environment["NOTECRAFT_SYMBOLS_OUT"]

private struct RawSymbol: Decodable {
  var id: Int
  var pl: [[[Double]]]
}

@Test(.enabled(if: symbolsIn != nil && symbolsOut != nil)) func theNetworkReadsEachCutSymbol() throws {
  let input = try #require(symbolsIn)
  let output = try #require(symbolsOut)
  let data = try #require(FileManager.default.contents(atPath: input))
  let symbols = try JSONDecoder().decode([RawSymbol].self, from: data)
  let net = SymbolNet.bundled
  var lines: [String] = ["id\t" + (SymbolNet.symbols + ["reject"]).joined(separator: "\t")]
  for s in symbols {
    let strokes = s.pl.map { $0.map { Point($0[0], $0[1]) } }
    guard let picture = SymbolRaster.render(strokes) else { continue }
    let p = net.probabilities(picture)
    lines.append("\(s.id)\t" + p.map { String(format: "%.4f", $0) }.joined(separator: "\t"))
  }
  try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
  #expect(lines.count > 1)
}
