import Foundation

// The look of the app as data. A theme sets the colors of the chrome (for light and dark), the
// typeface, replacements for icons, and how round things are; it can not change what the app does or
// where things are. A theme is a folder with a `theme.json` and the fonts and icons it names, so
// anyone can make one without writing code (see docs/THEMES.md).

// What a color is for. These names are the public vocabulary of a theme file: a theme that leaves one
// out gets the color of the default theme, so a theme may change a single color.
public enum ThemeColorToken: String, CaseIterable, Codable, Sendable {
  // The library and everything that sits on the app's own background.
  case background, surface, surfaceRaised, field, separator
  case textPrimary, textSecondary, textTertiary
  // The main color of buttons and selections, the color that goes on top of it, a second color
  // for what is highlighted next to it, a bookmarked document, and what is destructive.
  case accent, accentText, secondaryAccent, favorite, danger
  // What shows around the pages of a notebook.
  case editorSurround
  // The two bars on top of a notebook, and the tool that is chosen in them.
  case tabBar, toolBar, toolBarText, toolSelection, toolSelectionText
  // The rounded bar of controls that floats over the page.
  case quickBar, quickBarText, quickBarOutline
  // Dialogs: renaming, creating, moving.
  case sheet, sheetText, sheetSecondaryText
}

public enum ThemeScheme: String, Codable, Sendable { case light, dark }

// A color with its alpha. Written as "#RRGGBB" or "#RRGGBBAA".
public struct ThemeColor: Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init?(hex: String) {
    var text = hex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6 || text.count == 8, let bits = UInt64(text, radix: 16) else {
      return nil
    }
    let withAlpha = text.count == 8
    let value = withAlpha ? bits : (bits << 8) | 0xFF
    red = Double((value >> 24) & 0xFF) / 255
    green = Double((value >> 16) & 0xFF) / 255
    blue = Double((value >> 8) & 0xFF) / 255
    alpha = Double(value & 0xFF) / 255
  }

  public var hex: String {
    func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    return alpha >= 0.999 ? base : base + String(format: "%02X", byte(alpha))
  }
}

public typealias ThemePalette = [ThemeColorToken: ThemeColor]

// The typeface: the system's, in one of its designs, or a font that came with the theme.
public struct ThemeTypography: Equatable, Sendable {
  public enum Design: String, Codable, Sendable { case standard, serif, rounded, monospaced }
  public var design: Design = .standard
  // A font family (or PostScript name) from the package's fonts; nil is the system font.
  public var family: String?
  // Font files inside the package, registered while the theme is in use.
  public var files: [String] = []
  // Every size is multiplied by this.
  public var scale = 1.0
  public init() {}
  public static let standard = ThemeTypography()
}

public enum ThemeIcon: Equatable, Sendable {
  // Another SF Symbol.
  case symbol(String)
  // An image in the package.
  case file(String)
}

public struct ThemeShape: Equatable, Sendable {
  // Corner radii are multiplied by this (0 is square, 1 is as designed, 2 is very round).
  public var cornerScale = 1.0
  public init() {}
  public static let standard = ThemeShape()
}

public struct Theme: Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var author = ""
  public var version = "1"
  public var light: ThemePalette
  public var dark: ThemePalette
  // The schemes the theme was made for. A theme with one palette is that scheme, whatever the
  // device or the reader prefers.
  public var schemes: Set<ThemeScheme>
  public var typography = ThemeTypography.standard
  // SF Symbol names to what replaces them.
  public var icons: [String: ThemeIcon] = [:]
  public var shape = ThemeShape.standard
  public var isBuiltIn = false

  public init(
    id: String, name: String, light: ThemePalette = [:], dark: ThemePalette = [:],
    schemes: Set<ThemeScheme> = [.light, .dark]
  ) {
    self.id = id
    self.name = name
    self.light = light
    self.dark = dark
    self.schemes = schemes
  }

  // The scheme the app is drawn in: the reader's, if the theme has it, else the one it has.
  public func scheme(preferring preferred: ThemeScheme) -> ThemeScheme {
    if schemes.contains(preferred) { return preferred }
    return schemes.contains(.dark) ? .dark : .light
  }

  // The colors for a scheme, with anything the theme leaves out taken from `base`.
  public func palette(for scheme: ThemeScheme, base: Theme?) -> ThemePalette {
    var result = (scheme == .dark ? base?.dark : base?.light) ?? [:]
    for (token, color) in scheme == .dark ? dark : light { result[token] = color }
    return result
  }
}
