import Testing

@testable import NoteCraftCore

@Suite struct PageInsertionTests {
  private func notebook(_ count: Int) -> Notebook {
    Notebook(title: "n", pages: (0..<count).map { _ in Page() })
  }

  @Test func blankPageLandsBetweenTwoPdfPages() {
    var book = notebook(4)
    let ids = book.pages.map(\.id)
    var blank = Page(paper: Paper(pattern: .blank))
    blank.backgroundSize = Point(612, 792)
    let index = book.insertPage(blank, .after, current: 1)
    #expect(index == 2)
    #expect(book.pages.map(\.id) == [ids[0], ids[1], blank.id, ids[2], ids[3]])
  }

  @Test func beforeTheFirstPageAndAfterTheLast() {
    var book = notebook(3)
    let ids = book.pages.map(\.id)
    let first = Page()
    #expect(book.insertPage(first, .before, current: 0) == 0)
    #expect(book.pages.map(\.id) == [first.id] + ids)
    let last = Page()
    #expect(book.insertPage(last, .after, current: book.pages.count - 1) == 4)
    #expect(book.pages.last?.id == last.id)
  }

  @Test func theEndIgnoresWhereTheReaderIs() {
    var book = notebook(3)
    let added = Page()
    #expect(book.insertPage(added, .end, current: 0) == 3)
    #expect(book.pages.last?.id == added.id)
  }

  @Test func aStaleCurrentPageIsClamped() {
    var book = notebook(2)
    #expect(book.insertPage(Page(), .after, current: 99) == 2)
    #expect(book.insertPage(Page(), .before, current: -5) == 0)
  }

  @Test func templatePagesFollowTheSamePlace() throws {
    for position in PageInsertion.allCases {
      var target = NotebookPackage(notebook: notebook(4))
      let source = NotebookPackage(notebook: notebook(2))
      let first = try target.insertPages(of: source, after: position.following(current: 1))
      #expect(first == position.index(current: 1, count: 4))
      #expect(target.notebook.pages.count == 6)
    }
  }
}
