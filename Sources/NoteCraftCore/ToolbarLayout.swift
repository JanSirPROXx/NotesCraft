import Foundation

// Which tools the toolbar shows and in what order. Kept as two short strings in the preferences, so
// a tool that a later version adds still turns up (at the end) for someone who customized the bar
// with an earlier one, and a stored name that no longer exists is ignored.
public struct ToolbarLayout: Equatable, Sendable {
  public var order: [InkTool]
  public var hidden: Set<InkTool>

  public static let standard = ToolbarLayout(order: InkTool.allCases, hidden: [])

  public init(order: [InkTool], hidden: Set<InkTool>) {
    self.order = order
    self.hidden = hidden
  }

  public init(storedOrder: String, storedHidden: String) {
    func tools(_ stored: String) -> [InkTool] {
      stored.split(separator: ",").compactMap { InkTool(rawValue: String($0)) }
    }
    var seen = Set<InkTool>()
    var order = tools(storedOrder).filter { seen.insert($0).inserted }
    order += InkTool.allCases.filter { !seen.contains($0) }
    self.order = order
    hidden = Set(tools(storedHidden))
  }

  public var storedOrder: String { order.map(\.rawValue).joined(separator: ",") }
  public var storedHidden: String {
    order.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",")
  }

  // What the bar shows. Never empty: with every tool hidden the pen stays.
  public var visible: [InkTool] {
    let shown = order.filter { !hidden.contains($0) }
    return shown.isEmpty ? [.pen] : shown
  }

  public func isVisible(_ tool: InkTool) -> Bool { visible.contains(tool) }

  // The last tool on the bar cannot be hidden: a toolbar without tools is a dead end.
  public func canHide(_ tool: InkTool) -> Bool {
    !(visible == [tool])
  }

  @discardableResult
  public mutating func setVisible(_ tool: InkTool, _ shown: Bool) -> Bool {
    if shown {
      hidden.remove(tool)
      return true
    }
    guard canHide(tool) else { return false }
    hidden.insert(tool)
    return true
  }

  public var isStandard: Bool { self == .standard }
}
