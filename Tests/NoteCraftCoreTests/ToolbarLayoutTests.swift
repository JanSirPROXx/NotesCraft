import Foundation
import Testing

@testable import NoteCraftCore

@Test func theStandardToolbarShowsEveryToolInTheStandardOrder() {
  let layout = ToolbarLayout(storedOrder: "", storedHidden: "")
  #expect(layout == .standard)
  #expect(layout.visible == InkTool.allCases)
  #expect(layout.isStandard)
}

@Test func aStoredLayoutComesBackAsItWasSaved() {
  var layout = ToolbarLayout.standard
  layout.order = [
    .text, .pen, .eraser, .highlighter, .shapes, .lasso, .elements, .image, .calculator, .readOnly,
  ]
  layout.setVisible(.shapes, false)
  layout.setVisible(.readOnly, false)
  let restored = ToolbarLayout(storedOrder: layout.storedOrder, storedHidden: layout.storedHidden)
  #expect(restored == layout)
  #expect(
    restored.visible == [.text, .pen, .eraser, .highlighter, .lasso, .elements, .image, .calculator])
}

@Test func aToolFromALaterVersionTurnsUpAtTheEnd() {
  // A bar saved before `readOnly` and `text` existed.
  let layout = ToolbarLayout(storedOrder: "eraser,pen,highlighter", storedHidden: "")
  #expect(Array(layout.order.prefix(3)) == [.eraser, .pen, .highlighter])
  #expect(Set(layout.order) == Set(InkTool.allCases))
  #expect(layout.order.count == InkTool.allCases.count)
  #expect(layout.visible.count == InkTool.allCases.count)
}

@Test func namesThatAreUnknownOrRepeatedAreIgnored() {
  let layout = ToolbarLayout(storedOrder: "pen,wand,pen,eraser", storedHidden: "wand,text")
  #expect(Array(layout.order.prefix(2)) == [.pen, .eraser])
  #expect(layout.order.count == InkTool.allCases.count)
  #expect(layout.hidden == [.text])
}

@Test func theLastToolOnTheBarCannotBeHidden() {
  var layout = ToolbarLayout.standard
  for tool in InkTool.allCases.dropLast() {
    let hidden = layout.setVisible(tool, false)
    #expect(hidden)
  }
  #expect(layout.visible == [InkTool.allCases.last!])
  #expect(!layout.canHide(InkTool.allCases.last!))
  let refused = layout.setVisible(InkTool.allCases.last!, false)
  #expect(!refused)
  #expect(layout.visible == [InkTool.allCases.last!])
}

@Test func aBarWithNothingShownStillHasThePen() {
  // Hand-edited preferences can hide everything.
  let all = InkTool.allCases.map(\.rawValue).joined(separator: ",")
  let layout = ToolbarLayout(storedOrder: "", storedHidden: all)
  #expect(layout.visible == [.pen])
}

@Test func showingAToolAgainPutsItBackWhereItWas() {
  var layout = ToolbarLayout.standard
  layout.setVisible(.lasso, false)
  #expect(!layout.visible.contains(.lasso))
  layout.setVisible(.lasso, true)
  #expect(layout == .standard)
}
