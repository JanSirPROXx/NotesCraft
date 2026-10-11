import NoteCraftCore
import SwiftUI

extension View {
  // `.buttonStyle(.plain)` hit-tests only drawn pixels, so a 4 pt dot or a clear padded circle
  // is nearly untappable. Every quick-bar control gets an explicit full-size touch area.
  func hitTarget(width: CGFloat = 44, height: CGFloat = 44) -> some View {
    frame(width: width, height: height).contentShape(Rectangle())
  }
}

extension InkColor {
  var hex: String {
    func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
  }
  var swiftUI: Color { Color(red: red, green: green, blue: blue) }
  init(_ color: Color) {
    #if os(macOS)
      let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
      self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    #else
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
      self.init(red: r, green: g, blue: b)
    #endif
  }
}

enum QuickPalette {
  static let quick: [InkColor] = [.ink, .blue, .red, .green, .yellow]
  static let full: [InkColor] = [
    "#1F2B3D", "#000000", "#6B7280", "#9CA3AF", "#FFFFFF", "#7C3AED",
    "#2563EB", "#0EA5E9", "#14B8A6", "#16A34A", "#84CC16", "#FACC15",
    "#F97316", "#DC2626", "#DB2777", "#92400E", "#BE185D", "#0F766E",
  ].compactMap { InkColor(hex: $0) }
}

struct QuickColorRow: View {
  @Binding var color: InkColor
  var accent: Color
  @State private var paletteOpen = false

  // The non-preset color the user picked stays reachable as a sixth swatch.
  private var swatches: [InkColor] {
    QuickPalette.quick.contains { $0.hex == color.hex } ? QuickPalette.quick
      : QuickPalette.quick + [color]
  }
  var body: some View {
    ForEach(Array(swatches.enumerated()), id: \.offset) { _, ink in
      let selected = ink.hex == color.hex
      Button {
        if selected { paletteOpen = true } else { color = ink }
      } label: {
        Circle().fill(ink.swiftUI).frame(width: 22, height: 22)
          .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
          .padding(4)
          .overlay(Circle().stroke(selected ? Color.white : .clear, lineWidth: 2))
          .hitTarget(width: 40)
      }
      .accessibilityLabel("Ink color \(ink.hex)")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .popover(isPresented: Binding(get: { selected && paletteOpen }, set: { paletteOpen = $0 })) {
        ColorPalette(color: $color).presentationCompactAdaptation(.popover)
      }
    }
  }
}

struct ColorPalette: View {
  @Binding var color: InkColor
  @State private var hex = ""
  @State private var custom = Color.black

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6), spacing: 8) {
        ForEach(Array(QuickPalette.full.enumerated()), id: \.offset) { _, ink in
          Button {
            color = ink
          } label: {
            Circle().fill(ink.swiftUI).frame(width: 30, height: 30)
              .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
              .overlay(
                Circle().stroke(Color.white, lineWidth: ink.hex == color.hex ? 2.5 : 0).padding(-3)
              )
              .hitTarget(width: 40, height: 40)
          }
          .buttonStyle(.plain).accessibilityLabel("Color \(ink.hex)")
        }
      }
      ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
      TextField("Hex, e.g. #265DD4", text: $hex)
        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.characters)
        #endif
        .onSubmit { if let parsed = InkColor(hex: hex) { color = parsed } }
    }
    .padding(18).frame(width: 322).preferredColorScheme(.dark)
    .onAppear {
      hex = color.hex
      custom = color.swiftUI
    }
    .onChange(of: custom) { color = InkColor(custom) }
    .onChange(of: color) { hex = color.hex }
  }
}

struct QuickWidthRow: View {
  @Binding var slots: [Double]
  @Binding var width: Double
  var range: ClosedRange<Double>
  var color: InkColor
  var highlighter: Bool
  @State private var editing: Int?

  private func diameter(_ value: Double) -> CGFloat {
    highlighter ? 8 + value * 0.5 : 4 + value * 1.3
  }
  var body: some View {
    ForEach(Array(slots.enumerated()), id: \.offset) { index, value in
      let selected = abs(width - value) < 0.01
      Button {
        if selected { editing = index } else { width = value }
      } label: {
        Circle().fill(Color.white).frame(width: diameter(value), height: diameter(value))
          .hitTarget(width: 38)
          .background(
            selected ? Color.white.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
      }
      .help("\(value.formatted()) pt")
      .accessibilityLabel("Thickness \(value.formatted()) points")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } })) {
        WidthEditor(
          value: Binding(
            get: { slots[index] },
            set: {
              slots[index] = $0
              width = $0
            }), range: range, color: color, highlighter: highlighter
        ).presentationCompactAdaptation(.popover)
      }
    }
  }
}

// The slider owns a local draft and commits when released. Writing the shared value on every
// tick re-evaluates the whole workspace, which is what made thickness changes stutter.
struct WidthEditor: View {
  @Binding var value: Double
  var range: ClosedRange<Double>
  var color: InkColor
  var highlighter: Bool
  @State private var draft = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Thickness").font(.headline)
        Spacer()
        Text("\(draft.formatted(.number.precision(.fractionLength(1)))) pt").monospacedDigit()
      }
      Canvas { context, size in
        var path = Path()
        path.move(to: CGPoint(x: 18, y: size.height * 0.6))
        path.addCurve(
          to: CGPoint(x: size.width - 18, y: size.height * 0.4),
          control1: CGPoint(x: size.width * 0.35, y: size.height * 0.1),
          control2: CGPoint(x: size.width * 0.65, y: size.height * 0.95))
        context.stroke(
          path, with: .color(color.swiftUI.opacity(highlighter ? 0.45 : 1)),
          style: StrokeStyle(lineWidth: draft, lineCap: .round, lineJoin: .round))
      }
      .frame(height: 64).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
      Slider(value: $draft, in: range) { editing in
        if !editing { value = (draft * 10).rounded() / 10 }
      }
      .accessibilityLabel("Thickness")
    }
    .padding(18).frame(width: 300).preferredColorScheme(.dark)
    .onAppear { draft = value }
    .onDisappear { value = (draft * 10).rounded() / 10 }
  }
}

// Sliders keep a local draft and commit on release, like WidthEditor: each tick would otherwise
// re-evaluate the whole workspace.
struct DraftSlider: View {
  let title: String
  @Binding var value: Double
  var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
  @State private var draft = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(display(draft)).font(.caption).monospacedDigit()
      }
      Slider(value: $draft, in: 0...1) { editing in
        if !editing { value = draft }
      }
    }
    .onAppear { draft = value }
    .onChange(of: value) { draft = value }
    .onDisappear { value = draft }
  }
}

struct FountainPreview: View {
  let tip: PenTip
  let color: InkColor
  let width: Double
  var stabilization = 0.0

  var body: some View {
    Canvas { context, size in
      let samples = (0...90).map { i -> Sample in
        let t = Double(i) / 90
        // A pen stroke that starts slowly, speeds up through the middle and slows again.
        let eased = t * t * (3 - 2 * t)
        let x = 16 + eased * (size.width - 32)
        let y = size.height * (0.62 - 0.38 * sin(eased * .pi * 1.35 + 0.2) * (1 - eased * 0.2))
        let pressure = 0.12 + 0.4 * sin(t * .pi)
        return Sample(point: Point(x, y), pressure: pressure)
      }
      context.withCGContext { c in
        c.translateBy(x: 0, y: 0)
        PageRenderer.stroke(
          Stroke(
            samples: samples, color: color, width: max(1, width * 1.6), style: .fountain,
            tip: tip), in: c)
      }
    }
    .frame(height: 96).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct PenTipSettings: View {
  @Binding var sharpness: Double
  @Binding var pressure: Double
  @Binding var flatness: Double
  var color: InkColor
  var width: Double
  @State private var draftTip = PenTip.standard

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      FountainPreview(tip: draftTip, color: color, width: width)
      DraftSlider(title: "Tip sharpness", value: $sharpness)
      DraftSlider(title: "Pressure sensitivity", value: $pressure)
      DraftSlider(
        title: "Tip flatness", value: $flatness,
        display: { $0 < 0.02 ? "Round" : "\(Int(($0 * 100).rounded()))%" })
    }
    .onAppear { draftTip = PenTip(sharpness: sharpness, pressure: pressure, flatness: flatness) }
    .onChange(of: sharpness) { draftTip.sharpness = sharpness }
    .onChange(of: pressure) { draftTip.pressure = pressure }
    .onChange(of: flatness) { draftTip.flatness = flatness }
  }
}
