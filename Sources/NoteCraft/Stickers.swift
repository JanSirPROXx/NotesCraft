import NoteCraftCore
import SwiftUI

// What the elements tool inserts when the page is tapped.
enum StickerChoice: Equatable {
  case vector(ShapeKind)
  case emoji(String)
  case clip(UUID)
}

enum StickerCatalog {
  static let emoji = [
    "😀", "😂", "😍", "🤔", "😎", "🥳", "👍", "👏", "🙌", "💪", "❤️", "💔", "⭐️", "🌟", "✅", "❌", "❗️",
    "❓", "💡", "📌", "📎", "🔥", "🎉", "🎯", "🚀", "📚", "✏️", "📝", "🔔", "⏰", "🏆", "💯", "🌈", "☀️",
    "🌙", "🍀", "🎵", "📷",
  ]
}

// Outline preview of a shape or sticker for palettes.
struct ShapeIcon: View {
  let kind: ShapeKind
  var ink: InkColor = InkColor(red: 1, green: 1, blue: 1)

  var body: some View {
    Canvas { context, size in
      context.withCGContext { c in
        let reference = kind.defaultSize
        let scale = (min(size.width, size.height) - 10) / max(reference.x, reference.y)
        let spec = ShapeSpec(
          kind: kind, center: Point(size.width / 2, size.height / 2),
          width: reference.x * scale, height: kind.isLinear ? 0 : reference.y * scale)
        PageRenderer.stroke(
          kind.isSticker
            ? .sticker(spec) : .shape(spec, color: ink, width: 2), in: c)
      }
    }
  }
}

struct ShapePalette: View {
  @Binding var selection: ShapeKind?
  var onPick: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Shapes").font(.headline)
      Button {
        selection = nil
        onPick()
      } label: {
        Label("Freehand (snaps to exact shapes)", systemImage: "scribble")
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .padding(.horizontal, 10)
          .background(
            selection == nil ? Color.white.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), spacing: 8) {
        ForEach(ShapeKind.shapes, id: \.self) { kind in
          Button {
            selection = kind
            onPick()
          } label: {
            ShapeIcon(kind: kind).frame(width: 58, height: 52)
              .background(
                selection == kind ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityLabel(kind.title)
        }
      }
      Text("Tap the page to place a shape, or drag to size it. Then drag, stretch or rotate it.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(width: 290).preferredColorScheme(.dark)
  }
}
