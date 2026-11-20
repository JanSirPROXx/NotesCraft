import SwiftUI

enum ExportChoice: Hashable { case page, notebook }

// The one way to export: the page being read or the whole notebook, as a PDF. While it renders the
// sheet shows how far it is and offers to stop; it cannot be swiped away then.
struct ExportSheet: View {
  let pageNumber: Int
  let pageCount: Int
  @Binding var choice: ExportChoice
  let job: ExportJob
  let onExport: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Export").font(.theme(.title2).bold())
      if job.isRunning { progress } else { options }
    }
    .padding(28).frame(minWidth: 340, idealWidth: 440).themedSheet()
    .interactiveDismissDisabled(job.isRunning)
  }

  @ViewBuilder private var options: some View {
    if pageCount > 1 {
      Picker("What to export", selection: $choice) {
        Text("Current page").tag(ExportChoice.page)
        Text("Whole notebook").tag(ExportChoice.notebook)
      }
      .pickerStyle(.segmented).accessibilityIdentifier("exportScope")
    }
    Group {
      if pageCount > 1 && choice == .notebook {
        Text("All \(pageCount) pages in order, as one PDF.")
      } else {
        Text("Page \(pageNumber), as a PDF.")
      }
    }
    .font(.theme(.callout)).foregroundStyle(.secondary)
    HStack {
      Button("Cancel") { onClose() }.accessibilityIdentifier("exportClose")
      Spacer()
      Button("Export") { onExport() }
        .buttonStyle(.themedProminent).accessibilityIdentifier("exportStart")
    }
  }

  @ViewBuilder private var progress: some View {
    switch job.phase {
    case .rendering(let shown) where !shown.isRendered:
      ProgressView(value: shown.fraction).accessibilityIdentifier("exportProgress")
      Text("Rendering page \(shown.current) of \(shown.total)")
        .font(.theme(.callout)).foregroundStyle(.secondary)
    case .rendering:
      ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("exportProgress")
      Text("Writing the PDF…").font(.theme(.callout)).foregroundStyle(.secondary)
    case .stopping:
      ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("exportProgress")
      Text("Stopping…").font(.theme(.callout)).foregroundStyle(.secondary)
    case .idle:
      EmptyView()
    }
    HStack {
      Spacer()
      Button("Cancel", role: .cancel) { job.cancel() }
        .disabled(job.phase == .stopping).accessibilityIdentifier("exportCancel")
    }
  }
}
