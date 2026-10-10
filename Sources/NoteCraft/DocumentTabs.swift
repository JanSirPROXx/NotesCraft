#if os(macOS)
  import SwiftUI
  import AppKit

  struct DocumentTabs: View {
    let currentTitle: String
    let addPage: () -> Void
    @State private var windows: [NSWindow] = []
    var body: some View {
      HStack(spacing: 0) {
        if windows.count > 1 {
          ForEach(windows, id: \.windowNumber) { window in
            Button {
              window.makeKeyAndOrderFront(nil)
            } label: {
              HStack {
                Image(systemName: "book.closed")
                Text(window.title).lineLimit(1)
              }.padding(.horizontal, 18).frame(maxWidth: 260, minHeight: 36).background(
                window.isKeyWindow ? Color.white.opacity(0.16) : .clear)
            }.buttonStyle(.plain)
          }
        } else {
          HStack {
            Image(systemName: "book.closed")
            Text(currentTitle).lineLimit(1)
            Spacer()
          }.padding(.horizontal, 18).frame(width: 260, height: 36).background(
            Color.white.opacity(0.16))
        }
        Spacer()
        Menu {
          Button("New notebook") { NSDocumentController.shared.newDocument(nil) }
          Button("Open notebook…") { NSDocumentController.shared.openDocument(nil) }
          Button("Add page") { addPage() }
          Button("Merge document windows") { NSApp.keyWindow?.mergeAllWindows(nil) }
        } label: {
          Image(systemName: "plus").padding(.horizontal, 16)
        }.menuStyle(.borderlessButton).frame(width: 48)
      }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
          _ in refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
          refresh()
        }
    }
    private func refresh() {
      windows = NSDocumentController.shared.documents.flatMap {
        $0.windowControllers.compactMap(\.window)
      }.filter { $0.isVisible }
    }
  }
#endif
