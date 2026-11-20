import CoreGraphics
import Foundation
import ImageIO
import NoteCraftCore
import PDFKit
import Testing

@testable import NoteCraft

// A page told apart from the others by its width and a typed line, so the order of the PDF can be
// read off the file itself.
private func numberedPage(_ number: Int, strokes: Int = 0) -> Page {
  var page = Page(paper: Paper(pattern: .blank))
  page.backgroundSize = Point(300 + Double(number), 400)
  page.texts = [TextBox(origin: Point(20, 30), text: "page \(number)")]
  for stroke in 0..<strokes {
    let y = 60 + Double(stroke) * 3
    page.strokes.append(
      Stroke(
        samples: [Sample(point: Point(20, y)), Sample(point: Point(120, y + 8))], width: 1.5))
  }
  return page
}

private func notebook(_ numbers: Range<Int>, strokes: Int = 0) -> NotebookPackage {
  NotebookPackage(
    notebook: Notebook(title: "Export", pages: numbers.map { numberedPage($0, strokes: strokes) }))
}

private func pngData() throws -> Data {
  let context = try #require(
    CGContext(
      data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  return data as Data
}

private func exported(_ package: NotebookPackage, scope: ExportScope) async throws -> PDFDocument {
  let plan = try ExportPlan(scope: scope, notebook: package.notebook)
  let data = try await ExportWorker.shared.render(plan.package(from: package)) { _ in }
  return try #require(PDFDocument(data: data))
}

// What a viewer shows of a page apart from its paper: the kind, place and text of each annotation.
private func look(_ page: PDFPage) -> [String] {
  [page.bounds(for: .mediaBox).debugDescription]
    + page.annotations.map {
      "\($0.type ?? "?") \($0.bounds.debugDescription) \($0.contents ?? "")"
    }
}

@MainActor @Suite struct NotebookExportTests {
  @Test func theWholeNotebookIsOneFileWithEveryPageInOrder() async throws {
    let package = notebook(0..<7)
    let pdf = try await exported(package, scope: .notebook)
    #expect(pdf.pageCount == 7)
    for number in 0..<7 {
      let page = try #require(pdf.page(at: number))
      #expect(Double(page.bounds(for: .mediaBox).width) == 300 + Double(number))
      #expect(page.annotations.contains { $0.contents == "page \(number)" })
    }
  }

  @Test func pagesKeepTheOrderTheNotebookHasAfterReordering() async throws {
    var package = notebook(0..<5)
    package.notebook.pages.swapAt(0, 4)
    package.notebook.pages.remove(at: 2)
    let pdf = try await exported(package, scope: .notebook)
    #expect(pdf.pageCount == 4)
    let widths = (0..<4).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).width }
    #expect(widths == [304, 301, 303, 300])
  }

  @Test func oneChosenPageIsAFileOfOnePage() async throws {
    let pdf = try await exported(notebook(0..<6), scope: .page(3))
    #expect(pdf.pageCount == 1)
    let page = try #require(pdf.page(at: 0))
    #expect(page.bounds(for: .mediaBox).width == 303)
    #expect(page.annotations.contains { $0.contents == "page 3" })
  }

  @Test func aNotebookOfOnePageExportsThatPageEitherWay() async throws {
    let package = notebook(0..<1, strokes: 5)
    for scope in [ExportScope.notebook, .page(0)] {
      let pdf = try await exported(package, scope: scope)
      #expect(pdf.pageCount == 1)
      #expect(pdf.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count == 5)
    }
  }

  // Ink, typed text, a calculator answer, a picture, a filled shape and rotated text: each page of
  // the notebook PDF has what the same page exported alone has, because both go through one exporter.
  @Test func eachPageLooksLikeItsOwnSinglePageExport() async throws {
    var rich = numberedPage(0, strokes: 40)
    rich.strokes[0].tool = .highlighter
    rich.strokes[1].fillColor = .red
    var answer = TextBox(origin: Point(40, 300), text: "42")
    answer.calculation = CalculationLink(
      strokeIDs: rich.strokes.prefix(3).map(\.id), expression: "6*7", state: .done,
      recognizerVersion: 1)
    rich.texts.append(answer)
    var turned = TextBox(origin: Point(150, 200), text: "turned")
    turned.rotation = 0.5
    rich.texts.append(turned)
    rich.images = [PageAsset(filename: "dot.png", frame: Rect(x: 200, y: 40, width: 60, height: 45))]
    let package = NotebookPackage(
      notebook: Notebook(title: "Mixed", pages: [numberedPage(1, strokes: 3), rich, numberedPage(2)]),
      assets: ["dot.png": try pngData()])
    let whole = try await exported(package, scope: .notebook)
    #expect(whole.pageCount == 3)
    for index in 0..<3 {
      let alone = try await exported(package, scope: .page(index))
      let expected = look(try #require(alone.page(at: 0)))
      let actual = look(try #require(whole.page(at: index)))
      #expect(actual == expected, "page \(index)")
      #expect(actual.count > 1, "page \(index) has something on it")
    }
  }

  @Test func theReportCountsEveryPageOnceAndEndsComplete() async throws {
    final class Log: @unchecked Sendable {
      let lock = NSLock()
      var reports: [ExportProgress] = []
      func add(_ progress: ExportProgress) { lock.withLock { reports.append(progress) } }
    }
    let log = Log()
    _ = try await ExportWorker.shared.render(notebook(0..<5)) { log.add($0) }
    #expect(log.reports.map(\.completed) == [1, 2, 3, 4, 5])
    #expect(log.reports.allSatisfy { $0.total == 5 })
    #expect(log.reports.last?.isRendered == true)
  }

  @Test func aHookThatThrowsStopsTheExportAtThatPage() throws {
    var pagesDone = 0
    #expect(throws: CancellationError.self) {
      try PDFEditor.export(notebook(0..<20)) { progress in
        pagesDone = progress.completed
        if progress.completed == 3 { throw CancellationError() }
      }
    }
    #expect(pagesDone == 3)
  }

  @Test func theJobHandsOverTheFileOnceAndIsIdleAgain() async throws {
    let job = ExportJob()
    let package = notebook(0..<4)
    let plan = try ExportPlan(scope: .notebook, notebook: package.notebook)
    let result = await withCheckedContinuation { continuation in
      job.start(package, plan: plan) { continuation.resume(returning: $0) }
      #expect(job.isRunning)
    }
    let data = try result.get()
    #expect(PDFDocument(data: data)?.pageCount == 4)
    #expect(!job.isRunning)
  }

  @Test func aCancelledJobReportsNothingAndFreesTheJob() async throws {
    let job = ExportJob()
    let package = notebook(0..<30, strokes: 20)
    let plan = try ExportPlan(scope: .notebook, notebook: package.notebook)
    var finished = 0
    job.start(package, plan: plan) { _ in finished += 1 }
    job.cancel()
    #expect(job.phase == .stopping)
    while job.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished == 0)
    // It can be started again.
    let again = await withCheckedContinuation { continuation in
      job.start(
        package, plan: try! ExportPlan(scope: .page(1), notebook: package.notebook)
      ) { continuation.resume(returning: $0) }
    }
    #expect(PDFDocument(data: try again.get())?.pageCount == 1)
  }

  @Test func aJobGivenAnEmptyNotebookFailsWithoutRendering() throws {
    #expect(throws: ExportError.nothingToExport) {
      try ExportPlan(scope: .notebook, notebook: Notebook(title: "none", pages: []))
    }
  }

  @Test func aSecondStartWhileOneRunsIsIgnored() async throws {
    let job = ExportJob()
    let package = notebook(0..<3)
    let plan = try ExportPlan(scope: .notebook, notebook: package.notebook)
    var finished = 0
    job.start(package, plan: plan) { _ in finished += 1 }
    job.start(package, plan: plan) { _ in finished += 1 }
    while job.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished == 1)
  }
}
