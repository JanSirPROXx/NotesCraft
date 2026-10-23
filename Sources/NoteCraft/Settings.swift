import NoteCraftCore
import SwiftUI

// The names of the preferences. The workspace and the settings screen read the same keys, so a
// switch flipped in one is flipped in the other.
enum Preferences {
  static let pencilOnly = "pencilOnlyDrawing"
  static let holdToShape = "holdToShape"
  static let scratchToErase = "scratchToErase"
  static let circleToLasso = "circleToLasso"
  static let gpuInk = "gpuInk"
  static let scribbleHint = "scribbleHint"
  static let horizontalPages = "horizontalNotebookPages"
  static let infiniteScroll = "infiniteScroll"
  static let stabilization = "penStabilization"
  static let pullToAddPage = "pullToAddPage"
  static let showPageIndicator = "showPageIndicator"
  static let showZoomIndicator = "showZoomIndicator"
  static let undoRedoPosition = "undoRedoPosition"
  static let toolbarOrder = "toolbarOrder"
  static let toolbarHidden = "toolbarHidden"
}

// Where undo and redo sit in the bar that floats over the page.
enum UndoRedoPosition: String, CaseIterable {
  case left, right
  var title: String { self == .left ? "Left" : "Right" }
}

extension InkTool {
  var symbol: String {
    switch self {
    case .pen: "pencil.tip"
    case .eraser: "eraser"
    case .highlighter: "highlighter"
    case .shapes: "square.on.circle"
    case .lasso: "lasso"
    case .elements: "star.square"
    case .image: "photo"
    case .text: "textformat"
    case .readOnly: "hand.draw"
    }
  }
  var title: String { self == .readOnly ? "Read only" : rawValue.capitalized }
}

// What the library tells the settings about where the notebooks live.
struct SettingsStorage {
  var activeName: String
  var addFolder: () -> Void
}

// All the preferences in one place, grouped the way people look for them. Whatever is here works
// without a notebook open; it is reached from the library and from the menu of a notebook.
struct SettingsView: View {
  var storage: SettingsStorage?
  @Environment(\.dismiss) private var dismiss
  @AppStorage(Preferences.horizontalPages) private var horizontal = false
  @AppStorage(Preferences.infiniteScroll) private var infinite = false
  @AppStorage(Preferences.pullToAddPage) private var pullToAddPage = true
  @AppStorage(Preferences.showPageIndicator) private var showPageIndicator = true
  @AppStorage(Preferences.showZoomIndicator) private var showZoomIndicator = true
  @AppStorage(Preferences.pencilOnly) private var pencilOnly = true
  @AppStorage(Preferences.gpuInk) private var gpuInk = true
  @AppStorage(Preferences.holdToShape) private var holdToShape = true
  @AppStorage(Preferences.scratchToErase) private var scratchToErase = true
  @AppStorage(Preferences.scribbleHint) private var scribbleHint = ScribbleHintMode.sometimes
  @AppStorage(Preferences.circleToLasso) private var circleToLasso = true
  @AppStorage(Preferences.stabilization) private var stabilization = 0.0
  @AppStorage(Preferences.undoRedoPosition) private var undoRedo = UndoRedoPosition.left

  init(storage: SettingsStorage? = nil) { self.storage = storage }

  var body: some View {
    NavigationStack {
      Form {
        documentSection
        pencilSection
        gestureSection
        toolbarSection
        if let storage { storageSection(storage) }
        aboutSection
      }
      .navigationTitle("Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 560)
    #endif
  }

  private var documentSection: some View {
    Section {
      LabeledContent("Scrolling direction") {
        Picker("Scrolling direction", selection: $horizontal) {
          Text("Vertical").tag(false)
          Text("Horizontal").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240).disabled(infinite)
      }
      Toggle("Infinite scrolling", isOn: $infinite)
      Toggle("Add pages by pulling or swiping past the last one", isOn: $pullToAddPage)
        .disabled(infinite)
      Toggle("Show page number while scrolling", isOn: $showPageIndicator)
      Toggle("Show zoom while zooming", isOn: $showZoomIndicator)
    } header: {
      Text("Document")
    } footer: {
      Text(
        infinite
          ? "Infinite scrolling is one long sheet that grows as you write, so pages do not turn."
          : horizontal
            ? "Pages turn one at a time, side by side."
            : "Pages scroll in a column and zoom together, like a long document.")
    }
  }

  private var pencilSection: some View {
    Section {
      Toggle("Apple Pencil only", isOn: $pencilOnly)
      Toggle("Fast GPU ink", isOn: $gpuInk)
    } header: {
      Text("Apple Pencil")
    } footer: {
      Text(
        (pencilOnly
          ? "Apple Pencil writes and one finger moves the page. "
          : "One finger draws and two fingers move the page. ")
          + "Fast GPU ink draws the line you are writing on the GPU for the lowest latency. "
          + "What a double tap or squeeze of the Pencil does follows Settings ▸ Apple Pencil.")
    }
  }

  private var gestureSection: some View {
    Section {
      Toggle("Draw and hold for shapes", isOn: $holdToShape)
      Toggle("Scribble to erase", isOn: $scratchToErase)
      Picker("Scribble hint", selection: $scribbleHint) {
        ForEach(ScribbleHintMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }.disabled(!scratchToErase)
      Toggle("Circle to lasso", isOn: $circleToLasso)
      DraftSlider(title: "Stroke stabilization", value: $stabilization)
    } header: {
      Text("Pen and gestures")
    } footer: {
      Text(
        "Hold the pen still at the end of a line to straighten it into a shape. Scribble over ink "
          + "to erase it. Hold the pen still on a loop you drew to select what it encloses. "
          + "Stabilization steadies the line you write.")
    }
  }

  private var toolbarSection: some View {
    Section {
      NavigationLink("Customize toolbar") { ToolbarSettings() }
      Picker("Undo and redo", selection: $undoRedo) {
        ForEach(UndoRedoPosition.allCases, id: \.self) { Text($0.title).tag($0) }
      }
    } header: {
      Text("Toolbar")
    }
  }

  private func storageSection(_ storage: SettingsStorage) -> some View {
    Section {
      LabeledContent("Storage folder", value: storage.activeName)
      Button("Add storage folder…") {
        dismiss()
        storage.addFolder()
      }
    } header: {
      Text("Storage")
    } footer: {
      Text(
        "Notebooks are plain .notecraft packages in the folder you chose, so Files, iCloud Drive "
          + "and other apps can see and back them up.")
    }
  }

  private var aboutSection: some View {
    Section {
      LabeledContent("Version", value: Self.version)
    } header: {
      Text("About")
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(version) (\(build))"
  }
}

// Which tools the toolbar shows and in what order.
struct ToolbarSettings: View {
  @AppStorage(Preferences.toolbarOrder) private var storedOrder = ""
  @AppStorage(Preferences.toolbarHidden) private var storedHidden = ""

  private var layout: ToolbarLayout {
    ToolbarLayout(storedOrder: storedOrder, storedHidden: storedHidden)
  }
  private func save(_ layout: ToolbarLayout) {
    storedOrder = layout.storedOrder
    storedHidden = layout.storedHidden
  }

  var body: some View {
    List {
      Section {
        ForEach(layout.order, id: \.self) { tool in
          Toggle(
            isOn: Binding(
              get: { layout.isVisible(tool) },
              set: { shown in
                var changed = layout
                changed.setVisible(tool, shown)
                save(changed)
              })
          ) {
            Label(tool.title, systemImage: tool.symbol)
          }
          .disabled(layout.isVisible(tool) && !layout.canHide(tool))
        }
        .onMove { from, to in
          var changed = layout
          changed.order.move(fromOffsets: from, toOffset: to)
          save(changed)
        }
      } footer: {
        Text("Drag to reorder. The shortcuts ⌘1 to ⌘9 follow this order.")
      }
      Section {
        Button("Reset toolbar", role: .destructive) { save(.standard) }
          .disabled(layout.isStandard)
      }
    }
    .navigationTitle("Customize toolbar")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .environment(\.editMode, .constant(.active))
    #endif
  }
}
