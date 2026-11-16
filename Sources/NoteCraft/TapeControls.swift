import NoteCraftCore
import SwiftUI

extension QuickPalette {
  // Washi colors: light enough for the pattern to show, strong enough to hide ink.
  static let tape: [InkColor] = ["#F6C945", "#F28B82", "#8FD3B6", "#8EC5F4", "#B9A7F0"]
    .compactMap { InkColor(hex: $0) }
}

// A short strip drawn by the page renderer, so a swatch is the tape that will be laid.
struct TapeSwatch: View {
  var pattern: TapePattern
  var color: InkColor

  var body: some View {
    Canvas { context, size in
      guard
        let strip = Stroke.tape(
          along: [Point(0, size.height / 2), Point(size.width, size.height / 2)], color: color,
          width: size.height, pattern: pattern, straight: true)
      else { return }
      context.withCGContext { PageRenderer.stroke(strip, in: $0) }
    }
  }
}

struct TapePatternPicker: View {
  @Binding var selection: TapePattern
  var color: InkColor
  var onPick: () -> Void = {}

  var body: some View {
    HStack(spacing: 6) {
      ForEach(TapePattern.allCases, id: \.self) { pattern in
        Button {
          selection = pattern
          onPick()
        } label: {
          VStack(spacing: 6) {
            TapeSwatch(pattern: pattern, color: color).frame(width: 50, height: 20)
            Text(pattern.title).font(.theme(.caption)).lineLimit(1).minimumScaleFactor(0.7)
          }
          .frame(width: 62, height: 60).contentShape(Rectangle())
          .background(
            selection == pattern ? Color.theme(.secondaryAccent).opacity(0.35) : .clear,
            in: RoundedRectangle(cornerRadius: .corner(8)))
        }
        .buttonStyle(.plain).accessibilityLabel(pattern.title)
        .accessibilityAddTraits(selection == pattern ? .isSelected : [])
        .accessibilityIdentifier("tapePattern-" + pattern.rawValue)
      }
    }
  }
}
