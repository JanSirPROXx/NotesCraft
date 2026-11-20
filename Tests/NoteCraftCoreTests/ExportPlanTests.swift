import Foundation
import Testing

@testable import NoteCraftCore

@Suite struct ExportPlanTests {
  // Pages told apart by their size, so an order can be read off the result.
  private func notebook(_ count: Int) -> Notebook {
    var book = Notebook(title: "Physics", pages: [])
    for index in 0..<count {
      var page = Page()
      page.backgroundSize = Point(100 + Double(index), 200)
      book.pages.append(page)
    }
    return book
  }
  private func widths(_ package: NotebookPackage) -> [Double] {
    package.notebook.pages.map(\.dimensions.x)
  }

  @Test func theWholeNotebookTakesEveryPageInTheOrderOfTheNotebook() throws {
    let book = notebook(5)
    let plan = try ExportPlan(scope: .notebook, notebook: book)
    #expect(plan.pageIndexes == [0, 1, 2, 3, 4])
    #expect(plan.count == 5)
    let package = try plan.package(from: NotebookPackage(notebook: book))
    #expect(package.notebook.pages.map(\.id) == book.pages.map(\.id))
  }

  @Test func theOrderFollowsReorderingAndDeletion() throws {
    var book = notebook(4)
    book.pages.swapAt(0, 3)
    book.pages.remove(at: 1)
    let package = try ExportPlan(scope: .notebook, notebook: book)
      .package(from: NotebookPackage(notebook: book))
    #expect(widths(package) == [103, 102, 100])
  }

  @Test func onePageTakesOnlyThatPage() throws {
    let book = notebook(6)
    let plan = try ExportPlan(scope: .page(3), notebook: book)
    #expect(plan.pageIndexes == [3])
    let package = try plan.package(from: NotebookPackage(notebook: book))
    #expect(package.notebook.pages.map(\.id) == [book.pages[3].id])
    #expect(package.notebook.id == book.id)
  }

  @Test func aNotebookOfOnePageExportsThatPageWhicheverWayItIsAsked() throws {
    let book = notebook(1)
    for scope in [ExportScope.notebook, .page(0)] {
      let plan = try ExportPlan(scope: scope, notebook: book)
      #expect(plan.pageIndexes == [0])
      let package = try plan.package(from: NotebookPackage(notebook: book))
      #expect(package.notebook.pages.map(\.id) == [book.pages[0].id])
    }
  }

  @Test func aNotebookWithoutPagesHasNothingToExport() {
    let empty = notebook(0)
    #expect(throws: ExportError.nothingToExport) { try ExportPlan(scope: .notebook, notebook: empty) }
    #expect(throws: ExportError.nothingToExport) { try ExportPlan(scope: .page(0), notebook: empty) }
  }

  @Test func aPageThatIsNotThereIsRefused() {
    let book = notebook(3)
    #expect(throws: ExportError.noSuchPage(3)) { try ExportPlan(scope: .page(3), notebook: book) }
    #expect(throws: ExportError.noSuchPage(-1)) { try ExportPlan(scope: .page(-1), notebook: book) }
  }

  @Test func aPlanMadeBeforePagesWereDeletedDoesNotCutOutOfRange() throws {
    let plan = try ExportPlan(scope: .notebook, notebook: notebook(5))
    #expect(throws: ExportError.self) {
      try plan.package(from: NotebookPackage(notebook: notebook(2)))
    }
  }

  @Test func theAssetsStayWithTheCutNotebook() throws {
    var book = notebook(3)
    book.pages[2].backgroundPDF = "source.pdf"
    let assets = ["source.pdf": Data([1, 2, 3])]
    let package = try ExportPlan(scope: .page(2), notebook: book)
      .package(from: NotebookPackage(notebook: book, assets: assets))
    #expect(package.assets == assets)
    #expect(package.notebook.pages[0].backgroundPDF == "source.pdf")
  }

  @Test func theFileNameSaysWhichPageOnlyForOnePage() throws {
    let book = notebook(9)
    #expect(try ExportPlan(scope: .notebook, notebook: book).fileName(title: "Physics") == "Physics")
    let one = try ExportPlan(scope: .page(4), notebook: book).fileName(title: "Physics")
    #expect(one.hasPrefix("Physics") && one.hasSuffix("5"))
  }

  @Test func progressNeverLeavesItsRange() {
    #expect(ExportProgress(completed: 0, total: 0).fraction == 0)
    #expect(ExportProgress(completed: 5, total: 4) == ExportProgress(completed: 4, total: 4))
    #expect(ExportProgress(completed: -3, total: 4).completed == 0)
    let half = ExportProgress(completed: 50, total: 100)
    #expect(half.fraction == 0.5)
    #expect(!half.isRendered)
    #expect(half.current == 51)
    let done = ExportProgress(completed: 100, total: 100)
    #expect(done.isRendered)
    #expect(done.current == 100)
  }
}
