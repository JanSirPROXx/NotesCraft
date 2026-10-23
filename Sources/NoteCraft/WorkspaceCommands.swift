import NoteCraftCore
import SwiftUI

// What the menu bar and the hardware-keyboard shortcut overlay (hold ⌘ on iPad) can do in the
// notebook that is in front. The workspace publishes it as a focused scene value, so with several
// notebooks or windows the shortcut always reaches the one being used.
struct WorkspaceActions {
  struct ToolEntry: Identifiable {
    var tool: InkTool
    var title: String
    var id: InkTool { tool }
  }
  var tools: [ToolEntry]
  var selectTool: (InkTool) -> Void
  var toggleEraser: () -> Void
  var previousPage: () -> Void
  var nextPage: () -> Void
  var addPage: () -> Void
  var fitToWidth: () -> Void
  var canGoBack: Bool
  var canGoForward: Bool
}

private struct WorkspaceActionsKey: FocusedValueKey {
  typealias Value = WorkspaceActions
}

extension FocusedValues {
  var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActionsKey.self] }
    set { self[WorkspaceActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var actions

  var body: some Commands {
    CommandMenu("Tools") {
      // ⌘1…⌘9 in toolbar order; unmodified letters would collide with typing into text boxes.
      ForEach(Array((actions?.tools ?? []).enumerated()), id: \.element.id) { index, entry in
        if index < 9, let key = "123456789".dropFirst(index).first {
          Button(entry.title) { actions?.selectTool(entry.tool) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        }
      }
      Divider()
      Button("Switch to Eraser") { actions?.toggleEraser() }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(actions == nil)
    }
    CommandMenu("Page") {
      Button("Previous Page") { actions?.previousPage() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(actions?.canGoBack != true)
      Button("Next Page") { actions?.nextPage() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(actions?.canGoForward != true)
      Divider()
      Button("Fit to Width") { actions?.fitToWidth() }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(actions == nil)
      Divider()
      Button("Add Page") { actions?.addPage() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(actions == nil)
    }
  }
}
