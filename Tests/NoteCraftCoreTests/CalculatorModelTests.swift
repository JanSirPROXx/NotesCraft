import Foundation
import Testing

@testable import NoteCraftCore

@Test func calculatorInkAndResultSurviveASave() throws {
  var ink = Stroke(samples: [Sample(point: Point(10, 20)), Sample(point: Point(30, 22))])
  ink.calculator = true
  var result = TextBox(origin: Point(60, 14), text: "40")
  result.calculation = CalculationLink(
    strokeIDs: [ink.id], expression: "12*3+4", state: .done, recognizerVersion: 1)
  var page = Page()
  page.strokes = [ink, Stroke(samples: [Sample(point: Point(1, 1))])]
  page.texts = [result]
  let original = NotebookPackage(notebook: Notebook(title: "Maths", pages: [page]))
  let decoded = try NotebookPackage(fileWrapper: original.fileWrapper())
  #expect(decoded.notebook == original.notebook)
  #expect(decoded.notebook.pages[0].strokes.map(\.calculator) == [true, false])
  #expect(decoded.notebook.pages[0].texts[0].calculation?.expression == "12*3+4")
}

@Test func calculatorInkIsStoredAsAPlainPenStroke() throws {
  var ink = Stroke(samples: [Sample(point: Point(10, 20))])
  ink.calculator = true
  let json = String(decoding: try JSONEncoder().encode(ink), as: UTF8.self)
  // An older build reads "pen" and ignores the marker, so the page stays readable there.
  #expect(json.contains("\"tool\":\"pen\""))
  #expect(json.contains("\"calculator\":true"))
  let plain = String(
    decoding: try JSONEncoder().encode(Stroke(samples: [Sample(point: Point(1, 1))])),
    as: UTF8.self)
  #expect(!plain.contains("calculator"))
}

@Test func filesWithoutTheCalculatorFieldsStillLoad() throws {
  let stroke = Stroke(samples: [Sample(point: Point(1, 1))])
  var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stroke)) as! [String: Any]
  data.removeValue(forKey: "calculator")
  let decoded = try JSONDecoder().decode(
    Stroke.self, from: JSONSerialization.data(withJSONObject: data))
  #expect(decoded.calculator == false)
  let box = try JSONEncoder().encode(TextBox(origin: Point(0, 0), text: "hi"))
  #expect(try JSONDecoder().decode(TextBox.self, from: box).calculation == nil)
}

@Test func theCalculatorToolIsOnTheBarWithoutMovingTheOthers() {
  let tools = ToolbarLayout.standard.visible
  #expect(tools.contains(.calculator))
  #expect(tools.first == .pen)
  #expect(tools.last == .readOnly)
  // A bar saved before the calculator existed gets it at the end of the known tools.
  let old = ToolbarLayout(storedOrder: "pen,eraser,highlighter", storedHidden: "")
  #expect(old.order.contains(.calculator))
}
