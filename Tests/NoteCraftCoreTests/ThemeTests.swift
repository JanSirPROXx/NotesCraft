import Foundation
import Testing

@testable import NoteCraftCore

// MARK: colors

@Test func aColorReadsAndWritesItsHex() throws {
  let color = try #require(ThemeColor(hex: "#057AC7"))
  #expect(abs(color.red - 5.0 / 255) < 1e-9 && abs(color.blue - 199.0 / 255) < 1e-9)
  #expect(color.alpha == 1 && color.hex == "#057AC7")
  let clear = try #require(ThemeColor(hex: "FFFFFF80"))
  #expect(abs(clear.alpha - 128.0 / 255) < 1e-9 && clear.hex == "#FFFFFF80")
  #expect(ThemeColor(hex: "#12") == nil)
  #expect(ThemeColor(hex: "#GGGGGG") == nil)
  #expect(ThemeColor(hex: "") == nil)
}

// MARK: built-in themes

@Test func theStandardThemeHasEveryColorForBothSchemes() {
  for token in ThemeColorToken.allCases {
    #expect(Theme.standard.light[token] != nil, "light \(token)")
    #expect(Theme.standard.dark[token] != nil, "dark \(token)")
  }
}

@Test func everyBuiltInThemeIsCompleteAndValid() throws {
  var ids = Set<String>()
  for theme in Theme.builtIn {
    #expect(ThemeFile.isValid(id: theme.id))
    #expect(ids.insert(theme.id).inserted, "ids are unique")
    #expect(theme.isBuiltIn)
    for token in ThemeColorToken.allCases {
      #expect(theme.light[token] != nil && theme.dark[token] != nil, "\(theme.name) \(token)")
    }
    // What is written to a file is what is read back.
    var copy = try ThemeFile.parse(ThemeFile.encode(theme))
    copy.isBuiltIn = true
    #expect(copy == theme, "\(theme.name) survives its own file")
  }
}

@Test func textIsReadableOnItsBackground() {
  // Contrast ratio of a text color on its background, for every built-in theme and scheme.
  func luminance(_ c: ThemeColor) -> Double {
    func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
  }
  func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
    let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (hi + 0.05) / (lo + 0.05)
  }
  let pairs: [(ThemeColorToken, ThemeColorToken)] = [
    (.textPrimary, .background), (.textPrimary, .surface), (.textSecondary, .background),
    (.accentText, .accent), (.toolBarText, .toolBar), (.toolBarText, .tabBar),
    (.toolSelectionText, .toolSelection), (.quickBarText, .quickBar), (.sheetText, .sheet),
    (.sheetSecondaryText, .sheet),
  ]
  // A translucent background sits on the bar it is drawn over.
  func flat(_ c: ThemeColor, over base: ThemeColor) -> ThemeColor {
    ThemeColor(
      red: c.red * c.alpha + base.red * (1 - c.alpha),
      green: c.green * c.alpha + base.green * (1 - c.alpha),
      blue: c.blue * c.alpha + base.blue * (1 - c.alpha))
  }
  for theme in Theme.builtIn {
    for (name, palette) in [("light", theme.light), ("dark", theme.dark)] {
      for (text, background) in pairs {
        guard let t = palette[text], let b = palette[background] else { continue }
        let shown = background == .toolSelection ? flat(b, over: palette[.toolBar] ?? b) : b
        #expect(contrast(t, shown) >= 3.0, "\(theme.name) \(name): \(text) on \(background)")
      }
    }
  }
}

// MARK: schemes and fallbacks

@Test func aThemeWithOnePaletteIsThatSchemeWhateverIsPreferred() {
  let dark = Theme(id: "test.dark", name: "Dark", dark: [.accent: ThemeColor(hex: "#FF0000")!], schemes: [.dark])
  #expect(dark.scheme(preferring: .light) == .dark)
  #expect(dark.scheme(preferring: .dark) == .dark)
  let both = Theme.standard
  #expect(both.scheme(preferring: .light) == .light)
  #expect(both.scheme(preferring: .dark) == .dark)
}

@Test func aThemeThatLeavesAColorOutGetsTheOneOfTheBase() throws {
  let theme = Theme(
    id: "test.accent", name: "Accent", light: [.accent: ThemeColor(hex: "#FF0000")!],
    dark: [.accent: ThemeColor(hex: "#00FF00")!])
  let light = theme.palette(for: .light, base: .standard)
  #expect(light[.accent]?.hex == "#FF0000")
  #expect(light[.background] == Theme.standard.light[.background])
  #expect(light.count == ThemeColorToken.allCases.count)
  #expect(theme.palette(for: .dark, base: .standard)[.accent]?.hex == "#00FF00")
}

// MARK: the theme file

private func file(_ json: String) -> Data { Data(json.utf8) }

@Test func aMinimalThemeFileIsReadAndFallsBackForTheRest() throws {
  let theme = try ThemeFile.parse(file("""
    {"format": 1, "id": "com.example.red", "name": "Red",
     "colors": {"light": {"accent": "#FF0000"}}}
    """))
  #expect(theme.id == "com.example.red" && theme.name == "Red")
  #expect(theme.schemes == [.light], "one palette, one scheme")
  #expect(theme.light[.accent]?.hex == "#FF0000")
  #expect(!theme.isBuiltIn)
}

@Test func aThemeOfOnlyFontsAndIconsHasNoOpinionOnLightAndDark() throws {
  let theme = try ThemeFile.parse(file("""
    {"format": 1, "id": "com.example.type", "name": "Type",
     "typography": {"design": "serif", "scale": 1.1}}
    """))
  #expect(theme.schemes == [.light, .dark])
  #expect(theme.typography.design == .serif && theme.typography.scale == 1.1)
}

@Test func valuesAreKeptInRange() throws {
  let theme = try ThemeFile.parse(file("""
    {"format": 1, "id": "com.example.range", "name": "Range",
     "typography": {"scale": 5}, "shape": {"cornerScale": 99}}
    """))
  #expect(theme.typography.scale == 1.3 && theme.shape.cornerScale == 2.5)
}

@Test func iconsAreSymbolsOrFiles() throws {
  let theme = try ThemeFile.parse(file("""
    {"format": 1, "id": "com.example.icons", "name": "Icons",
     "icons": {"pencil.tip": "icons/pen.png", "sidebar.left": "symbol:rectangle.leftthird.inset.filled"}}
    """))
  #expect(theme.icons["pencil.tip"] == .file("icons/pen.png"))
  #expect(theme.icons["sidebar.left"] == .symbol("rectangle.leftthird.inset.filled"))
}

@Test func aColorTokenFromALaterVersionIsIgnored() throws {
  let theme = try ThemeFile.parse(file("""
    {"format": 1, "id": "com.example.future", "name": "Future",
     "colors": {"dark": {"accent": "#FF0000", "holographicGlow": "#00FF00"}}}
    """))
  #expect(theme.dark.count == 1)
}

@Test func badThemeFilesAreRefusedWithAnExplanation() {
  func error(_ json: String) -> ThemeError? {
    do { _ = try ThemeFile.parse(file(json)); return nil } catch { return error as? ThemeError }
  }
  #expect(error("not json") == .notAThemeFile)
  #expect(error(#"{"format": 2, "id": "com.example.x", "name": "X"}"#) == .unsupportedFormat(2))
  #expect(error(#"{"format": 1, "id": "Bad Id", "name": "X"}"#) == .invalidID("Bad Id"))
  #expect(error(#"{"format": 1, "id": "ab", "name": "X"}"#) == .invalidID("ab"))
  #expect(error(#"{"format": 1, "id": "com.example.x", "name": "  "}"#) == .missingName)
  #expect(error(#"{"format": 1, "id": "com.example.x", "name": "X", "colors": {"dark": {"accent": "red"}}}"#) == .invalidColor(token: "dark.accent", value: "red"))
  #expect(error(#"{"format": 1, "id": "com.example.x", "name": "X", "icons": {"a": "symbol:"}}"#) == .invalidIcon("a"))
  let big = String(repeating: " ", count: ThemeFile.maxBytes + 1)
  #expect(error(big) == .tooLarge("theme.json"))
}

// MARK: the package

private func package(
  _ json: String, files: [String: Data] = [:], line: Int = #line
) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("theme-\(UUID().uuidString).notecrafttheme")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data(json.utf8).write(to: root.appendingPathComponent("theme.json"))
  for (path, data) in files {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }
  return root
}

private let header = #"{"format": 1, "id": "com.example.pack", "name": "Pack""#

@Test func aPackageWithItsFontAndIconIsLoaded() throws {
  let root = try package(
    header + #", "typography": {"family": "Fira", "files": ["fonts/Fira.ttf"]}, "icons": {"pencil.tip": "icons/pen.png"}}"#,
    files: ["fonts/Fira.ttf": Data(count: 100), "icons/pen.png": Data(count: 100)])
  defer { try? FileManager.default.removeItem(at: root) }
  let theme = try ThemePackage.load(from: root)
  #expect(theme.typography.family == "Fira" && theme.icons["pencil.tip"] == .file("icons/pen.png"))
}

@Test func aFileTheThemeNamesMustBeThere() throws {
  let root = try package(header + #", "icons": {"pencil.tip": "icons/pen.png"}}"#)
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(throws: ThemeError.missingFile("icons/pen.png")) { try ThemePackage.load(from: root) }
}

@Test func aPathCannotLeaveThePackage() throws {
  for path in ["../secret.png", "/etc/passwd", "icons/../../x.png", "a\\b.png"] {
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
    let root = try package(header + #", "icons": {"pencil.tip": "\#(escaped)"}}"#)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ThemeError.invalidPath(path), "\(path)") { try ThemePackage.load(from: root) }
  }
}

@Test func aPackageCannotHoldAnythingThatCouldRun() throws {
  let root = try package(header + "}", files: ["run.sh": Data("echo".utf8)])
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(throws: ThemeError.unsupportedFile("run.sh")) { try ThemePackage.load(from: root) }
}

@Test func aSymbolicLinkInAPackageIsRefused() throws {
  let root = try package(header + "}")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("link.png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
  #expect(throws: ThemeError.unsupportedFile("link.png")) { try ThemePackage.load(from: root) }
}

@Test func anIconThatIsNotAnImageAndAFontThatIsNotAFontAreRefused() throws {
  let icon = try package(header + #", "icons": {"a": "fonts/x.ttf"}}"#, files: ["fonts/x.ttf": Data(count: 4)])
  defer { try? FileManager.default.removeItem(at: icon) }
  #expect(throws: ThemeError.unsupportedFile("fonts/x.ttf")) { try ThemePackage.load(from: icon) }
  let font = try package(header + #", "typography": {"files": ["icons/x.png"]}}"#, files: ["icons/x.png": Data(count: 4)])
  defer { try? FileManager.default.removeItem(at: font) }
  #expect(throws: ThemeError.unsupportedFile("icons/x.png")) { try ThemePackage.load(from: font) }
}

@Test func aPackageThatIsTooBigIsRefused() throws {
  let root = try package(header + "}", files: ["icons/big.png": Data(count: ThemePackage.maxTotalBytes + 1)])
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(throws: ThemeError.tooLarge("The package")) { try ThemePackage.load(from: root) }
}

@Test func aFolderWithoutAThemeFileIsNotATheme() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(throws: ThemeError.notAThemeFile) { try ThemePackage.load(from: root) }
}

// MARK: the example in the documentation

private let repository = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func theExampleThemeOfTheGuideIsAValidPackage() throws {
  let folder = repository.appendingPathComponent("docs/themes/sunset.notecrafttheme")
  let theme = try ThemePackage.load(from: folder)
  #expect(theme.id == "com.example.sunset" && theme.name == "Sunset")
  #expect(theme.schemes == [.light, .dark])
  #expect(theme.typography.design == .rounded)
  #expect(theme.icons["pencil.tip"] == .file("icons/pen.png"))
  #expect(theme.icons["star"] == .symbol("sparkles"))
  #expect(theme.shape.cornerScale == 1.6)
  // Everything the guide asks of a theme: text that can be read.
  func luminance(_ c: ThemeColor) -> Double {
    func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
  }
  func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
    (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
  }
  for scheme in [ThemeScheme.light, .dark] {
    let palette = theme.palette(for: scheme, base: .standard)
    for (text, background) in [
      (ThemeColorToken.textPrimary, ThemeColorToken.background), (.textPrimary, .surface),
      (.accentText, .accent), (.toolBarText, .toolBar), (.toolSelectionText, .toolSelection),
      (.quickBarText, .quickBar), (.sheetText, .sheet),
    ] {
      let ratio = contrast(palette[text]!, palette[background]!)
      #expect(ratio >= 3, "\(scheme) \(text) on \(background): \(ratio)")
    }
  }
}
