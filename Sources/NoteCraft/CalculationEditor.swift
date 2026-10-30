import NoteCraftCore
import SwiftUI

// What a tap on an answer opens: how the writing was read, to be corrected by hand. The answer
// shown underneath is the one the corrected calculation gives, so a wrong reading is a few keys
// away from the right number instead of a dead end.
struct CalculationEdit: Identifiable, Equatable {
  var id: UUID  // the answer's text box
  var expression: String
}

struct CalculationEditor: View {
  @State var expression: String
  var onApply: (CalculationOutcome) -> Void
  var onRemove: () -> Void
  var onCancel: () -> Void
  @FocusState private var focused: Bool

  private var outcome: CalculationOutcome { Calculator.outcome(forExpression: expression) }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Calculation").font(.theme(.title2).bold())
      VStack(alignment: .leading, spacing: 6) {
        TextField("e.g. 12×3+4", text: $expression)
          .textFieldStyle(.roundedBorder).font(.system(.title3, design: .monospaced))
          #if os(iOS)
            .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
          #endif
          .autocorrectionDisabled().focused($focused).accessibilityIdentifier("calculationField")
          .onSubmit(apply)
        Text("Use . for decimals, × ÷ ^ √ % and brackets.").font(.theme(.caption)).opacity(0.7)
      }
      HStack {
        Text("=").font(.theme(.title2))
        Text(outcome.state == .done ? outcome.text : "—").font(.theme(.title2).bold())
          .accessibilityIdentifier("calculationPreview")
        Spacer()
      }
      HStack {
        Button("Remove answer", role: .destructive, action: onRemove)
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Apply", action: apply).buttonStyle(.borderedProminent)
          .disabled(outcome.state != .done).accessibilityIdentifier("calculationApply")
      }
    }
    .padding(28).frame(minWidth: 320).themedSheet()
    .onAppear { focused = true }
    .presentationDetents([.height(330)])
  }

  private func apply() {
    guard outcome.state == .done else { return }
    onApply(outcome)
  }
}
