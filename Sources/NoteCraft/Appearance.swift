import CoreText
import NoteCraftCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

extension UTType {
  // A theme is a folder with a `.notecrafttheme` extension (see docs/THEMES.md).
  static let noteCraftTheme = UTType(exportedAs: "app.notecraft.theme", conformingTo: .package)
}

// Whether the app is drawn light, dark, or as the device is set.
enum AppearanceMode: String, CaseIterable {
  case system, light, dark
  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

// The theme in use, and what the app draws with: colors, type and icons are asked of this store
// wherever they are used, so a view that reads them is redrawn when the theme changes.
@MainActor @Observable final class ThemeStore {
  static let shared = ThemeStore()

  struct Installed: Identifiable {
    var theme: Theme
    var url: URL
    var id: String { theme.id }
  }

  private(set) var installed: [Installed] = []
  private(set) var selectedID: String
  private(set) var mode: AppearanceMode
  // Colors that replace the theme's accent and second color, as "#RRGGBB"; nil keeps the theme's.
  private(set) var accentHex: String?
  private(set) var secondaryHex: String?
  private(set) var systemScheme = ThemeScheme.dark
  private(set) var current = Theme.standard
  private(set) var scheme = ThemeScheme.dark
  private(set) var palette: ThemePalette = Theme.standard.dark

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var registeredFonts: [URL] = []
  @ObservationIgnored private var iconCache: [String: PlatformImage] = [:]

  private enum Key {
    static let theme = "appearanceTheme"
    static let mode = "appearanceMode"
    static let accent = "appearanceAccent"
    static let secondary = "appearanceSecondary"
  }

  init(defaults: UserDefaults = .standard, directory: URL? = nil) {
    self.defaults = defaults
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NotesCraft/Themes", isDirectory: true)
    selectedID = defaults.string(forKey: Key.theme) ?? Theme.standard.id
    // The look the app has always had is dark; Light and System are the reader's to ask for.
    mode = defaults.string(forKey: Key.mode).flatMap(AppearanceMode.init) ?? .dark
    accentHex = defaults.string(forKey: Key.accent)
    secondaryHex = defaults.string(forKey: Key.secondary)
    reloadInstalled()
    rebuild()
    refreshSystemScheme()
  }

  var themes: [Theme] { Theme.builtIn + installed.map(\.theme) }

  // MARK: choosing

  func select(_ id: String) {
    guard themes.contains(where: { $0.id == id }) else { return }
    selectedID = id
    defaults.set(id, forKey: Key.theme)
    rebuild()
  }

  func setMode(_ new: AppearanceMode) {
    mode = new
    defaults.set(new.rawValue, forKey: Key.mode)
    rebuild()
  }

  func setAccent(_ hex: String?) {
    accentHex = hex
    defaults.set(hex, forKey: Key.accent)
    rebuild()
  }

  func setSecondary(_ hex: String?) {
    secondaryHex = hex
    defaults.set(hex, forKey: Key.secondary)
    rebuild()
  }

  // What the device is set to. The screen's own traits are asked, not the app's: those include
  // the scheme the app has asked for.
  func refreshSystemScheme() {
    #if canImport(UIKit)
      let new: ThemeScheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    #else
      let new: ThemeScheme =
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    #endif
    guard new != systemScheme else { return }
    systemScheme = new
    rebuild()
  }

  // nil lets the device decide; a theme that is only light or only dark decides for itself.
  var preferredColorScheme: ColorScheme? {
    if mode == .system && current.schemes.count == 2 { return nil }
    return scheme == .dark ? .dark : .light
  }

  private func rebuild() {
    if !themes.contains(where: { $0.id == selectedID }) { selectedID = Theme.standard.id }
    current = themes.first { $0.id == selectedID } ?? .standard
    let preferred: ThemeScheme =
      switch mode {
      case .light: .light
      case .dark: .dark
      case .system: systemScheme
      }
    scheme = current.scheme(preferring: preferred)
    var colors = current.palette(for: scheme, base: .standard)
    if let accentHex, let color = ThemeColor(hex: accentHex) { colors[.accent] = color }
    if let secondaryHex, let color = ThemeColor(hex: secondaryHex) {
      colors[.secondaryAccent] = color
    }
    palette = colors
    iconCache = [:]
    registerFonts()
  }

  // MARK: what the app draws with

  func color(_ token: ThemeColorToken) -> Color {
    guard let c = palette[token] else { return .clear }
    return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
  }

  // The same color for drawing into a context (the selection on the page, say).
  func cgColor(_ token: ThemeColorToken) -> CGColor {
    guard let c = palette[token] else { return CGColor(gray: 0, alpha: 0) }
    return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
  }

  private func design(_ design: ThemeTypography.Design) -> Font.Design {
    switch design {
    case .standard: .default
    case .serif: .serif
    case .rounded: .rounded
    case .monospaced: .monospaced
    }
  }

  func font(size: CGFloat, weight: Font.Weight) -> Font {
    let type = current.typography
    let scaled = size * type.scale
    if let family = type.family { return Font.custom(family, size: scaled).weight(weight) }
    return Font.system(size: scaled, weight: weight, design: design(type.design))
  }

  private static let sizes: [Font.TextStyle: CGFloat] = [
    .largeTitle: 34, .title: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
    .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11,
  ]

  func font(style: Font.TextStyle) -> Font {
    let type = current.typography
    if type == .standard { return .system(style) }
    let size = Self.sizes[style] ?? 17
    let weight: Font.Weight = style == .headline ? .semibold : .regular
    if let family = type.family {
      return Font.custom(family, size: size * type.scale, relativeTo: style).weight(weight)
    }
    return .system(size: size * type.scale, weight: weight, design: design(type.design))
  }

  func cornerRadius(_ base: CGFloat) -> CGFloat { base * current.shape.cornerScale }

  // The symbol to use for a symbol name: another symbol if the theme swaps it.
  func symbolName(_ name: String) -> String {
    if case .symbol(let other) = current.icons[name] { return other }
    return name
  }

  func iconImage(for name: String) -> PlatformImage? {
    guard case .file(let path) = current.icons[name] else { return nil }
    if let cached = iconCache[path] { return cached }
    guard let root = packageURL(of: current.id),
      let url = try? ThemePackage.resolve(path, in: root),
      let image = Self.loadIcon(url)
    else { return nil }
    iconCache[path] = image
    return image
  }

  private static func loadIcon(_ url: URL) -> PlatformImage? {
    #if canImport(UIKit)
      if url.pathExtension.lowercased() == "pdf" {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
          return nil
        }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let target = CGSize(width: 66, height: 66 * box.height / box.width)
        return UIGraphicsImageRenderer(size: target).image { context in
          let c = context.cgContext
          c.translateBy(x: 0, y: target.height)
          c.scaleBy(x: target.width / box.width, y: -target.height / box.height)
          c.drawPDFPage(page)
        }
      }
      return UIImage(contentsOfFile: url.path)
    #else
      return nil
    #endif
  }

  // MARK: installed themes

  private func packageURL(of id: String) -> URL? { installed.first { $0.id == id }?.url }

  private func reloadInstalled() {
    let fm = FileManager.default
    let urls =
      (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    installed = urls.filter { $0.pathExtension == "notecrafttheme" }.sorted {
      $0.lastPathComponent < $1.lastPathComponent
    }.compactMap { url in
      guard let theme = try? ThemePackage.load(from: url) else { return nil }
      return Installed(theme: theme, url: url)
    }
  }

  // Checks a theme package and keeps a copy of it, replacing an installed theme with the same id.
  @discardableResult
  func install(from source: URL) throws -> Theme {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let theme = try ThemePackage.load(from: source)
    guard !theme.id.hasPrefix("app.notecraft.") else {
      throw ThemeInstallError.reservedID(theme.id)
    }
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(theme.id + ".notecrafttheme")
    let staging = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
    try fm.copyItem(at: source, to: staging)
    defer { try? fm.removeItem(at: staging) }
    // What was copied is checked again: a folder can change between the check and the copy.
    let checked = try ThemePackage.load(from: staging)
    guard checked.id == theme.id else { throw ThemeError.notAThemeFile }
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.moveItem(at: staging, to: destination)
    reloadInstalled()
    if selectedID == theme.id { rebuild() }
    return theme
  }

  func remove(_ id: String) {
    guard let url = packageURL(of: id) else { return }
    try? FileManager.default.removeItem(at: url)
    reloadInstalled()
    rebuild()
  }

  // MARK: fonts of the theme in use

  private func registerFonts() {
    for url in registeredFonts {
      CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }
    registeredFonts = []
    guard !current.typography.files.isEmpty, let root = packageURL(of: current.id) else { return }
    for path in current.typography.files {
      guard let url = try? ThemePackage.resolve(path, in: root) else { continue }
      if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { registeredFonts.append(url) }
    }
  }
}

enum ThemeInstallError: LocalizedError {
  case reservedID(String)
  var errorDescription: String? {
    switch self {
    case .reservedID(let id): "“\(id)” belongs to the themes that come with the app. Choose another id."
    }
  }
}

// MARK: use in views

extension Color {
  // The color the theme gives to what a thing is for.
  @MainActor static func theme(_ token: ThemeColorToken) -> Color { ThemeStore.shared.color(token) }
}

extension Font {
  @MainActor static func theme(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    ThemeStore.shared.font(size: size, weight: weight)
  }
  @MainActor static func theme(_ style: Font.TextStyle) -> Font {
    ThemeStore.shared.font(style: style)
  }
}

enum Icon {
  // For the places that only take a symbol name, like the items of a menu.
  @MainActor static func name(_ symbol: String) -> String { ThemeStore.shared.symbolName(symbol) }
}

// An icon the theme may replace: by another symbol or by an image of its own, 22 points square.
struct Symbol: View {
  let name: String
  init(_ name: String) { self.name = name }
  var body: some View {
    let store = ThemeStore.shared
    if let image = store.iconImage(for: name) {
      Image(platformImage: image).renderingMode(.template).resizable().scaledToFit()
        .frame(width: 22, height: 22)
    } else {
      Image(systemName: store.symbolName(name))
    }
  }
}

extension Image {
  init(platformImage: PlatformImage) {
    #if canImport(UIKit)
      self.init(uiImage: platformImage)
    #else
      self.init(nsImage: platformImage)
    #endif
  }
}

// A title and an icon, with the icon the theme's.
struct ThemedLabel: View {
  let title: String
  let symbol: String
  init(_ title: String, _ symbol: String) {
    self.title = title
    self.symbol = symbol
  }
  var body: some View { Label { Text(title) } icon: { Symbol(symbol) } }
}

// The theme's corner radius for a shape that is `base` points round as designed.
extension CGFloat {
  @MainActor static func corner(_ base: CGFloat) -> CGFloat { ThemeStore.shared.cornerRadius(base) }
}

// Tells the theme store what the device is set to, and draws the app in the theme's scheme.
struct ThemedRoot<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    let store = ThemeStore.shared
    content
      .preferredColorScheme(store.preferredColorScheme)
      .onAppear { store.refreshSystemScheme() }
      .onChange(of: colorScheme) { store.refreshSystemScheme() }
      .tint(Color.theme(.accent))
  }
}

// The main button of a dialog or a screen, in the theme's accent.
struct ThemedProminentStyle: ButtonStyle {
  var horizontal: CGFloat = 16
  var vertical: CGFloat = 8
  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration, horizontal: horizontal, vertical: vertical)
  }
  private struct Styled: View {
    let configuration: ButtonStyleConfiguration
    let horizontal: CGFloat
    let vertical: CGFloat
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      configuration.label.foregroundStyle(Color.theme(.accentText))
        .padding(.horizontal, horizontal).padding(.vertical, vertical)
        .background(Color.theme(.accent), in: RoundedRectangle(cornerRadius: .corner(10)))
        .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        .contentShape(Rectangle())
    }
  }
}

extension ButtonStyle where Self == ThemedProminentStyle {
  static var themedProminent: ThemedProminentStyle { ThemedProminentStyle() }
  static func themedProminent(horizontal: CGFloat, vertical: CGFloat) -> ThemedProminentStyle {
    ThemedProminentStyle(horizontal: horizontal, vertical: vertical)
  }
}

extension View {
  // A dialog in the theme's sheet colors.
  func themedSheet() -> some View {
    foregroundStyle(Color.theme(.sheetText)).background(Color.theme(.sheet))
  }
}

#if canImport(UIKit)
  extension UIColor {
    @MainActor static func theme(_ token: ThemeColorToken) -> UIColor {
      guard let c = ThemeStore.shared.palette[token] else { return .clear }
      return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
  }
#endif
