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
  static let calculatorColor = "calculatorColorHex"
  static let calculatorWidth = "calculatorWidth"
  static let calculatorIntroSeen = "calculatorIntroSeen"
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
    case .calculator: "plus.forwardslash.minus"
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
        appearanceSection
        if let storage { storageSection(storage) }
        marketplaceSection
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
    // A sheet keeps the scheme it was opened in unless it is told: here the reader can change it.
    .preferredColorScheme(ThemeStore.shared.preferredColorScheme)
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

  private var appearanceSection: some View {
    let store = ThemeStore.shared
    return Section {
      Picker(
        "Appearance",
        selection: Binding(get: { store.mode }, set: { store.setMode($0) })
      ) {
        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      NavigationLink {
        ThemeGallery()
      } label: {
        LabeledContent("Theme", value: store.current.name)
      }
      ColorPicker(
        "Accent color",
        selection: Binding(
          get: { Color.theme(.accent) },
          set: { store.setAccent(InkColor($0).hex) }), supportsOpacity: false)
      ColorPicker(
        "Second color",
        selection: Binding(
          get: { Color.theme(.secondaryAccent) },
          set: { store.setSecondary(InkColor($0).hex) }), supportsOpacity: false)
      if store.accentHex != nil || store.secondaryHex != nil {
        Button("Use the theme's colors") {
          store.setAccent(nil)
          store.setSecondary(nil)
        }
      }
    } header: {
      Text("Appearance")
    } footer: {
      Text(
        store.mode == .system
          ? "Light or dark as the iPad is set. A theme that is only light or only dark keeps its own."
          : "Themes change the colors, type and icons of the app, never what it does.")
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

  private var marketplaceSection: some View {
    Section {
      NavigationLink("Marketplace") { MarketplaceSettings() }
        .accessibilityIdentifier("marketplaceSettings")
    } header: {
      Text("Marketplace")
    } footer: {
      Text("Where the free themes, stickers, templates and planners are downloaded from.")
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
            Label { Text(tool.title) } icon: { Symbol(tool.symbol) }
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

// The themes to choose from, and a way to add one.
struct ThemeGallery: View {
  @State private var importing = false
  @State private var message: String?

  var body: some View {
    let store = ThemeStore.shared
    List {
      Section {
        ForEach(store.themes) { theme in
          Button {
            store.select(theme.id)
          } label: {
            HStack(spacing: 14) {
              ThemePreview(theme: theme)
              VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.theme(.body)).foregroundStyle(.primary)
                Text(Self.detail(theme)).font(.theme(.caption)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              if store.selectedID == theme.id {
                Symbol("checkmark").foregroundStyle(Color.accentColor)
              }
            }.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("theme-" + theme.id)
          .accessibilityAddTraits(store.selectedID == theme.id ? .isSelected : [])
          .swipeActions {
            if !theme.isBuiltIn {
              Button("Remove", role: .destructive) { store.remove(theme.id) }
            }
          }
        }
      } footer: {
        Text(
          "A theme is a folder ending in .notecrafttheme with a theme.json, and the fonts and icons "
            + "it names. Swipe an added theme to remove it.")
      }
      Section {
        Button("Add a theme…") { importing = true }.accessibilityIdentifier("addTheme")
      }
    }
    .navigationTitle("Theme")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .fileImporter(isPresented: $importing, allowedContentTypes: [.noteCraftTheme, .folder]) { result in
      do {
        let theme = try ThemeStore.shared.install(from: try result.get())
        ThemeStore.shared.select(theme.id)
      } catch { message = error.localizedDescription }
    }
    .alert(
      "This theme could not be added",
      isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    ) {
      Button("OK") { message = nil }
    } message: {
      Text(message ?? "")
    }
  }

  private static func detail(_ theme: Theme) -> String {
    var parts: [String] = []
    if !theme.author.isEmpty { parts.append(theme.author) }
    switch theme.schemes.count {
    case 2: parts.append("Light and dark")
    default: parts.append(theme.schemes.contains(.dark) ? "Dark" : "Light")
    }
    return parts.joined(separator: " · ")
  }
}

// A small picture of a theme: its background, bar, accent and text.
struct ThemePreview: View {
  let theme: Theme

  var body: some View {
    let store = ThemeStore.shared
    let preferred: ThemeScheme =
      switch store.mode {
      case .light: .light
      case .dark: .dark
      case .system: store.systemScheme
      }
    let palette = theme.palette(for: theme.scheme(preferring: preferred), base: .standard)
    func fill(_ token: ThemeColorToken) -> Color {
      guard let c = palette[token] else { return .clear }
      return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10).fill(fill(.background))
      VStack(alignment: .leading, spacing: 5) {
        RoundedRectangle(cornerRadius: 3).fill(fill(.toolBar)).frame(height: 10)
        HStack(spacing: 4) {
          Circle().fill(fill(.accent)).frame(width: 9, height: 9)
          Circle().fill(fill(.secondaryAccent)).frame(width: 9, height: 9)
          Circle().fill(fill(.favorite)).frame(width: 9, height: 9)
        }
        RoundedRectangle(cornerRadius: 2).fill(fill(.textPrimary)).frame(width: 36, height: 4)
        RoundedRectangle(cornerRadius: 2).fill(fill(.textSecondary)).frame(width: 24, height: 4)
      }.padding(7)
    }
    .frame(width: 64, height: 52)
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
  }
}
