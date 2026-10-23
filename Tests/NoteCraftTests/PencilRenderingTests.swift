import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

// One page rendered like the page cache does it: a y-down page at a retina scale.
@MainActor private struct Sheet {
  let width = 400
  let height = 120
  let scale = 2.0

  func alpha(_ page: Page) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * Int(scale) * height * Int(scale) * 4)
    bytes.withUnsafeMutableBytes { raw in
      let c = CGContext(
        data: raw.baseAddress, width: width * Int(scale), height: height * Int(scale),
        bitsPerComponent: 8, bytesPerRow: width * Int(scale) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.translateBy(x: 0, y: Double(height) * scale)
      c.scaleBy(x: scale, y: -scale)
      PageRenderer.render(page, assets: [:], in: c, includeBackground: false)
    }
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  }
}

private func pencil(
  from a: Point, to b: Point, width: Double = 2.5, color: InkColor = .ink,
  style: PenStyle = .pencil, id: UUID = UUID()
) -> Stroke {
  var stroke = Stroke(
    samples: (0..<60).map { i in
      let t = Double(i) / 59
      return Sample(
        point: Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t + 4 * sin(t * 9)))
    }, color: color, width: width, tool: .pen, style: style)
  stroke.id = id
  return stroke
}

private func page(_ strokes: [Stroke]) -> Page {
  var page = Page(paper: Paper(size: .a4, pattern: .blank))
  page.strokes = strokes
  return page
}

@MainActor @Test func pencilInkHasGrainWhereBallpointInkIsSolid() {
  let sheet = Sheet()
  // A thick line, judged by the pixels well inside it: the edges of any line are anti-aliased.
  func interior(_ style: PenStyle) -> [UInt8] {
    let alpha = sheet.alpha(
      page([pencil(from: Point(20, 50), to: Point(180, 60), width: 10, style: style)]))
    let columns = sheet.width * Int(sheet.scale)
    let rows = sheet.height * Int(sheet.scale)
    var inside: [UInt8] = []
    for y in 2..<(rows - 2) {
      for x in 2..<(columns - 2) {
        var covered = true
        search: for dy in -2...2 {
          for dx in -2...2 where alpha[(y + dy) * columns + x + dx] < 90 {
            covered = false
            break search
          }
        }
        if covered { inside.append(alpha[y * columns + x]) }
      }
    }
    return inside
  }
  let graphite = interior(.pencil)
  let solid = interior(.ballpoint)
  #expect(graphite.count > 3000)
  func spread(_ values: [UInt8]) -> Double {
    let mean = Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count)
    let variance = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)
    return variance.squareRoot()
  }
  #expect(spread(graphite) > 20, "grain: \(spread(graphite))")
  #expect(spread(solid) < 12, "solid ink: \(spread(solid))")
  // Graphite never covers the paper completely.
  #expect((graphite.max() ?? 255) < 240, "\(graphite.max() ?? 0)")
  #expect(solid.max() == 255)
}

@MainActor @Test func theSameStrokeAlwaysRendersTheSame() {
  let sheet = Sheet()
  let stroke = pencil(from: Point(20, 50), to: Point(180, 60))
  #expect(sheet.alpha(page([stroke])) == sheet.alpha(page([stroke])))
}

@MainActor @Test func grainStaysOnThePaperWhenAStrokeMovesByWholeTiles() {
  // The tile is anchored at the page origin, so a stroke moved by exactly one tile gets exactly the
  // same texture: the grain belongs to the paper, not to the stroke.
  let sheet = Sheet()
  let cell = PencilGrain.cell
  let a = pencil(from: Point(10, 40), to: Point(80, 55))
  let b = pencil(from: Point(10 + cell, 40), to: Point(80 + cell, 55))
  #expect(cell == 128)
  let wide = Sheet()
  let first = wide.alpha(page([a]))
  // Render b into a context shifted back by one cell: it must be pixel for pixel the first one.
  var bytes = [UInt8](repeating: 0, count: wide.width * 2 * wide.height * 2 * 4)
  bytes.withUnsafeMutableBytes { raw in
    let c = CGContext(
      data: raw.baseAddress, width: wide.width * 2, height: wide.height * 2, bitsPerComponent: 8,
      bytesPerRow: wide.width * 2 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: -cell * 2, y: Double(wide.height) * 2)
    c.scaleBy(x: 2, y: -2)
    PageRenderer.render(page([b]), assets: [:], in: c, includeBackground: false)
  }
  let second = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  var differing = 0
  for (x, y) in zip(first, second) where abs(Int(x) - Int(y)) > 2 { differing += 1 }
  #expect(differing == 0, "\(differing) of \(first.count) pixels differ")
}

@MainActor @Test func strokesDrawnTogetherLookLikeStrokesDrawnOneByOne() {
  // A page draws consecutive pencil strokes in one grain pass; a committed stroke is drawn alone.
  // Strokes that do not touch must come out the same either way.
  let sheet = Sheet()
  let strokes = [
    pencil(from: Point(20, 30), to: Point(150, 38)), pencil(from: Point(20, 60), to: Point(150, 70)),
    pencil(from: Point(180, 40), to: Point(300, 90), color: .blue),
  ]
  let together = sheet.alpha(page(strokes))
  var one = [UInt8](repeating: 0, count: together.count)
  for stroke in strokes {
    let single = sheet.alpha(page([stroke]))
    for i in one.indices { one[i] = max(one[i], single[i]) }
  }
  var differing = 0
  for (x, y) in zip(together, one) where abs(Int(x) - Int(y)) > 2 { differing += 1 }
  #expect(differing == 0, "\(differing) pixels differ")
}

@MainActor @Test func inkDrawnAfterAPencilStrokeCoversIt() throws {
  // z-order: the run of pencil strokes is flushed before a pen stroke that follows it.
  var bytes = [UInt8](repeating: 0, count: 400 * 120 * 4)
  bytes.withUnsafeMutableBytes { raw in
    let c = CGContext(
      data: raw.baseAddress, width: 400, height: 120, bitsPerComponent: 8, bytesPerRow: 400 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: 120)
    c.scaleBy(x: 1, y: -1)
    let under = Stroke(
      samples: (0..<40).map { Sample(point: Point(20 + Double($0) * 4, 60)) }, color: .red,
      width: 9, tool: .pen, style: .pencil)
    let over = Stroke(
      samples: (0..<40).map { Sample(point: Point(20 + Double($0) * 4, 60)) },
      color: InkColor(red: 0, green: 0, blue: 1), width: 9, tool: .pen, style: .ballpoint)
    PageRenderer.render(page([under, over]), assets: [:], in: c, includeBackground: false)
  }
  // Inside the stroke every pixel is the solid blue pen ink, with nothing of the red pencil showing.
  for x in stride(from: 40, to: 160, by: 7) {
    let pixel = (60 * 400 + x) * 4
    #expect(bytes[pixel] < 10 && bytes[pixel + 2] > 240 && bytes[pixel + 3] == 255, "x \(x)")
  }
}

@MainActor @Test func aSinglePointDrawsADotAndAnEmptyStrokeDrawsNothing() {
  let sheet = Sheet()
  let dot = Stroke(
    samples: [Sample(point: Point(100, 60))], width: 8, tool: .pen, style: .pencil)
  let inked = sheet.alpha(page([dot])).filter { $0 > 0 }.count
  #expect(inked > 60, "a dot of 8 points leaves a mark: \(inked)")
  let empty = Stroke(samples: [], width: 8, tool: .pen, style: .pencil)
  #expect(sheet.alpha(page([empty])).allSatisfy { $0 == 0 })
}

@MainActor @Test func aShapeKeepsItsCleanOutlineEvenIfThePencilWasActive() {
  var shape = Stroke.shape(
    ShapeSpec(kind: .rectangle, center: Point(100, 60), width: 120, height: 50), color: .ink,
    width: 2)
  shape.style = .pencil
  #expect(!shape.isPencil)
  let sheet = Sheet()
  let edge = sheet.alpha(page([shape]))
  // The top edge, away from the corners, is as solid as any plain line.
  let y = Int((60 - 25) * sheet.scale)
  #expect(edge[y * sheet.width * 2 + 200] > 200)
}

@MainActor @Test func pencilInkSurvivesPDFExport() throws {
  var notebook = Notebook(pages: [page([pencil(from: Point(60, 100), to: Point(400, 140))])])
  notebook.pages[0].paper = Paper(size: .a4, pattern: .blank)
  let data = try PageRenderer.export(NotebookPackage(notebook: notebook))
  #expect(data.count > 1000)
  #expect(data.starts(with: Data("%PDF".utf8)))
}
