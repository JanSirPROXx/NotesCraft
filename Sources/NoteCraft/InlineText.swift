import NoteCraftCore
import SwiftUI

// A text box being typed straight onto the page. It is committed to the notebook only when the
// user finishes, so typing never touches the undo history or re-renders the page.
struct InlineText: Equatable {
  var id: UUID?
  var origin: Point
  var text = ""
  var size: Double
  var width: Double
  var color: InkColor
}

struct InlineTextEditor: View {
  @Binding var draft: InlineText
  let scale: Double
  let offset: Point
  let pageHeight: Double
  let onDone: () -> Void
  let onDelete: () -> Void
  let onMore: () -> Void
  @FocusState private var focused: Bool
  @State private var palette = false

  private var fieldWidth: CGFloat { max(64, draft.width * scale) }
  private var top: CGFloat { draft.origin.y * scale + offset.y }
  private var left: CGFloat { draft.origin.x * scale + offset.x }

  private var toolbar: some View {
    HStack(spacing: 2) {
      Button {
        draft.size = max(8, draft.size - 2)
      } label: { Symbol("textformat.size.smaller").hitTarget(width: 40, height: 40) }
        .accessibilityLabel("Smaller text")
      Button {
        draft.size = min(120, draft.size + 2)
      } label: { Symbol("textformat.size.larger").hitTarget(width: 40, height: 40) }
        .accessibilityLabel("Larger text")
      Button {
        palette = true
      } label: {
        Circle().fill(draft.color.swiftUI).frame(width: 22, height: 22)
          .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
          .hitTarget(width: 40, height: 40)
      }
      .accessibilityLabel("Text color")
      .popover(isPresented: $palette) {
        ColorPalette(color: $draft.color).presentationCompactAdaptation(.popover)
      }
      Button(action: onMore) {
        Symbol("slider.horizontal.3").hitTarget(width: 40, height: 40)
      }.accessibilityLabel("More text options")
      Button(role: .destructive, action: onDelete) {
        Symbol("trash").hitTarget(width: 40, height: 40)
      }.accessibilityLabel("Delete text")
      Button(action: onDone) {
        Symbol("checkmark").fontWeight(.semibold).hitTarget(width: 40, height: 40)
      }.accessibilityLabel("Done editing text")
    }
    .font(.theme(17)).buttonStyle(.plain).foregroundStyle(Color.theme(.quickBarText))
    .padding(.horizontal, 6)
    .background(Color.theme(.quickBar), in: Capsule())
    .fixedSize()
  }

  var body: some View {
    // The bar sits above the box, or below it when the box is at the top edge of the page.
    let barAbove = top > 56
    VStack(alignment: .leading, spacing: 6) {
      if barAbove { toolbar }
      TextField("Type here", text: $draft.text, axis: .vertical)
        .font(.system(size: max(10, draft.size * scale)))
        .foregroundStyle(draft.color.swiftUI)
        .tint(.blue)
        .focused($focused)
        .lineLimit(1...12)
        .frame(width: fieldWidth, alignment: .leading)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue, lineWidth: 1.5))
        .accessibilityIdentifier("inlineTextField")
      if !barAbove { toolbar }
    }
    .offset(x: max(0, left - 6), y: barAbove ? max(0, top - 4 - 46) : max(0, top - 4))
    .onAppear { focused = true }
  }
}
