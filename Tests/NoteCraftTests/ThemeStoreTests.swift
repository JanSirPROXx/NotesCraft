import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

private let repository = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let sunset = repository.appendingPathComponent("docs/themes/sunset.notecrafttheme")

@MainActor private func store() -> (ThemeStore, UserDefaults, URL) {
  let suite = "theme-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("themes-" + UUID().uuidString, isDirectory: true)
  return (ThemeStore(defaults: defaults, directory: directory), defaults, directory)
}

@MainActor @Test func theAppStartsInTheClassicThemeInDarkMode() {
  let (store, _, _) = store()
  #expect(store.current.id == Theme.standard.id)
  #expect(store.mode == .dark && store.scheme == .dark)
  #expect(store.palette[.background] == Theme.standard.dark[.background])
  #expect(store.preferredColorScheme == .dark)
}

@MainActor @Test func theModeChoosesThePaletteAndWhoDecidesTheScheme() {
  let (store, _, _) = store()
  store.setMode(.light)
  #expect(store.scheme == .light && store.preferredColorScheme == .light)
  #expect(store.palette[.background] == Theme.standard.light[.background])
  store.setMode(.system)
  // The device decides, for a theme that has both.
  #expect(store.preferredColorScheme == nil)
  #expect(store.scheme == store.systemScheme)
}

@MainActor @Test func anAddedThemeIsCheckedCopiedAndCanBeChosen() throws {
  let (store, _, directory) = store()
  defer { try? FileManager.default.removeItem(at: directory) }
  let theme = try store.install(from: sunset)
  #expect(theme.id == "com.example.sunset")
  #expect(store.themes.map(\.id).contains("com.example.sunset"))
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.example.sunset.notecrafttheme/theme.json").path))
  store.select(theme.id)
  store.setMode(.light)
  #expect(store.current.id == theme.id)
  #expect(store.palette[.accent]?.hex == "#E4572E")
  // A color the theme leaves out is the classic one.
  #expect(store.palette[.favorite] == Theme.standard.light[.favorite])
  store.setMode(.dark)
  #expect(store.palette[.accent]?.hex == "#FF7A4D")
  // Its icon swaps and its corners are rounder.
  #expect(store.symbolName("star") == "sparkles")
  #expect(store.symbolName("pencil") == "pencil")
  #expect(store.cornerRadius(10) == 16)
}

@MainActor @Test func anAddedThemeIsStillThereWhenTheAppStartsAgain() throws {
  let (first, defaults, directory) = store()
  defer { try? FileManager.default.removeItem(at: directory) }
  let theme = try first.install(from: sunset)
  first.select(theme.id)
  first.setAccent("#112233")
  let second = ThemeStore(defaults: defaults, directory: directory)
  #expect(second.current.id == theme.id)
  #expect(second.accentHex == "#112233")
  #expect(second.palette[.accent]?.hex == "#112233", "the reader's accent is on top of the theme's")
}

@MainActor @Test func removingTheThemeInUseGoesBackToTheStandardOne() throws {
  let (store, _, directory) = store()
  defer { try? FileManager.default.removeItem(at: directory) }
  let theme = try store.install(from: sunset)
  store.select(theme.id)
  store.remove(theme.id)
  #expect(store.current.id == Theme.standard.id)
  #expect(!store.themes.map(\.id).contains(theme.id))
}

@MainActor @Test func aThemeCannotTakeTheIdOfOneThatComesWithTheApp() throws {
  let (store, _, directory) = store()
  defer { try? FileManager.default.removeItem(at: directory) }
  let copy = FileManager.default.temporaryDirectory
    .appendingPathComponent("copy-" + UUID().uuidString + ".notecrafttheme")
  defer { try? FileManager.default.removeItem(at: copy) }
  try FileManager.default.copyItem(at: sunset, to: copy)
  let file = copy.appendingPathComponent("theme.json")
  let text = try String(contentsOf: file, encoding: .utf8)
    .replacingOccurrences(of: "com.example.sunset", with: "app.notecraft.sunset")
  try text.write(to: file, atomically: true, encoding: .utf8)
  #expect(throws: ThemeInstallError.self) { try store.install(from: copy) }
  #expect(store.installed.isEmpty)
}

@MainActor @Test func aFolderThatIsNotAThemeIsRefusedAndLeavesNothingBehind() throws {
  let (store, _, directory) = store()
  defer { try? FileManager.default.removeItem(at: directory) }
  let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: empty) }
  #expect(throws: ThemeError.notAThemeFile) { try store.install(from: empty) }
  #expect(store.installed.isEmpty)
}

@MainActor @Test func theReadersColorsCanBeTakenOffAgain() {
  let (store, _, _) = store()
  store.setAccent("#00FF00")
  store.setSecondary("#FF00FF")
  #expect(store.palette[.accent]?.hex == "#00FF00" && store.palette[.secondaryAccent]?.hex == "#FF00FF")
  store.setAccent(nil)
  store.setSecondary(nil)
  #expect(store.palette[.accent] == Theme.standard.dark[.accent])
}
