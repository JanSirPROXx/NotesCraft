import NoteCraftCore
import SwiftUI

// Where the reader teaches the calculator pen their handwriting: a symbol or a calculation is
// asked for, written on the pad, and saved with its text. Symbols are used at once; whole
// calculations are kept to test the pen against. It is shown full screen: a sheet takes a swipe
// across the pad for a swipe to close it, and cancels the stroke.
struct CalculatorTrainer: View {
  private enum Mode: String, CaseIterable { case symbols = "Symbols", calculations = "Calculations" }

  @State private var store = CalculatorCorpusStore.shared
  @State private var mode = Mode.symbols
  @State private var queue: [String] = []
  @State private var prompt = ""
  @State private var page = CalculatorTrainer.blankPage()
  @State private var rounds: UInt64 = 0
  @State private var confirmDelete = false
  @Environment(\.dismiss) private var dismiss

  private static func blankPage() -> Page {
    var page = Page(paper: Paper(pattern: .blank))
    page.backgroundSize = Point(640, 250)
    return page
  }

  var body: some View {
    VStack(spacing: 14) {
      Picker("What to write", selection: $mode) {
        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).frame(maxWidth: 360)
        .onChange(of: mode) { next() }

      VStack(spacing: 4) {
        Text(mode == .symbols ? "Write this symbol" : "Write this calculation")
          .font(.theme(.caption)).opacity(0.7)
        PromptView(label: prompt).frame(height: 76).accessibilityIdentifier("trainerPrompt")
      }

      NativeCanvas(
        configuration: CanvasConfiguration(
          page: page, assets: [:], tool: .pen, color: .blue, width: 2.5, style: .ballpoint,
          pencilOnly: false, selection: [],
          onStroke: { stroke in page.strokes.append(stroke) }, onGesture: { _ in }, onTap: { _ in }, calculator: true)
      )
      .aspectRatio(640.0 / 250.0, contentMode: .fit).frame(maxWidth: 640)
      .background(Color.white).clipShape(RoundedRectangle(cornerRadius: .corner(12)))
      .overlay(
        RoundedRectangle(cornerRadius: .corner(12)).stroke(Color.theme(.accent).opacity(0.5), lineWidth: 1.5)
          // The frame is only to look at: a touch on the pad belongs to the canvas under it.
          .allowsHitTesting(false))
      .accessibilityIdentifier("trainerPad")

      HStack(spacing: 14) {
        Button("Clear") { page = Self.blankPage() }.disabled(page.strokes.isEmpty)
        Button("Skip") { next() }
        Spacer()
        Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(page.strokes.isEmpty)
          .accessibilityIdentifier("trainerSave")
      }.frame(maxWidth: 640)

      VStack(spacing: 6) {
        Text("\(store.corpus.symbolCount) symbols and \(store.corpus.calculationCount) calculations saved")
          .font(.theme(.callout)).accessibilityIdentifier("trainerCount")
        Text("Write the way you write in a notebook. The pen uses what you save from the next calculation on.")
          .font(.theme(.caption)).opacity(0.7).multilineTextAlignment(.center)
      }.frame(maxWidth: 560)

      HStack(spacing: 18) {
        ShareLink(item: store.fileURL) { Label("Share samples", systemImage: "square.and.arrow.up") }
          .disabled(store.corpus.samples.isEmpty)
        Button("Delete all samples", role: .destructive) { confirmDelete = true }
          .disabled(store.corpus.samples.isEmpty)
      }.font(.theme(.callout))
      Spacer(minLength: 0)
    }
    .padding(24).frame(maxWidth: .infinity)
    .navigationTitle("Teach your handwriting")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }.accessibilityIdentifier("trainerDone")
      }
    }
    .onAppear { if prompt.isEmpty { next() } }
    .confirmationDialog("Delete every sample?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete all", role: .destructive) { store.removeAll() }
    } message: {
      Text("The pen goes back to reading with its stock shapes only.")
    }
  }

  private func save() {
    let strokes = page.strokes.map { $0.samples.map(\.point) }
    store.add(kind: mode == .symbols ? .symbol : .calculation, label: prompt, strokes: strokes)
    next()
  }

  // The next thing to write: symbols in rounds of all of them, calculations at random.
  private func next() {
    page = Self.blankPage()
    switch mode {
    case .symbols:
      if queue.isEmpty {
        rounds += 1
        // Start with the symbol written least so far.
        let counts = store.corpus.counts()
        queue = TrainingPrompts.symbolRound(seed: rounds + UInt64(store.corpus.samples.count))
          .sorted { counts[$0, default: 0] < counts[$1, default: 0] }
      }
      prompt = queue.removeFirst()
    case .calculations:
      rounds += 1
      prompt = TrainingPrompts.calculation(seed: rounds &* 7919 &+ UInt64(store.corpus.samples.count))
    }
  }
}

// A symbol or a calculation as it is to be written; a fraction stands over its bar.
private struct PromptView: View {
  var label: String

  var body: some View {
    if let (top, bottom) = fraction(label) {
      VStack(spacing: 3) {
        Text(TrainingPrompts.shown(top))
        Rectangle().frame(height: 3).frame(maxWidth: 140)
        Text(TrainingPrompts.shown(bottom))
      }.font(.system(size: 34, weight: .semibold, design: .rounded))
    } else {
      Text(TrainingPrompts.shown(label)).font(.system(size: 56, weight: .semibold, design: .rounded))
    }
  }

  // "(12+3)/(4)" is 12+3 over 4.
  private func fraction(_ text: String) -> (String, String)? {
    guard text.hasPrefix("("), text.hasSuffix(")"), let split = text.range(of: ")/(") else { return nil }
    let top = String(text[text.index(after: text.startIndex)..<split.lowerBound])
    let bottom = String(text[split.upperBound..<text.index(before: text.endIndex)])
    return top.isEmpty || bottom.isEmpty ? nil : (top, bottom)
  }
}

