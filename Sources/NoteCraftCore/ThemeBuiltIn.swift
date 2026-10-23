import Foundation

extension Theme {
  private static func palette(_ pairs: KeyValuePairs<ThemeColorToken, String>) -> ThemePalette {
    var result: ThemePalette = [:]
    for (token, hex) in pairs { result[token] = ThemeColor(hex: hex) }
    return result
  }

  // How the app has always looked: a near-black library and a blue bar over the notebook. It is
  // also the theme every other theme falls back to for a color it does not set.
  public static let classic: Theme = {
    var theme = Theme(
      id: "app.notecraft.classic", name: "Classic",
      light: palette([
        .background: "#F2F2F7", .surface: "#FFFFFF", .surfaceRaised: "#E5E5EA", .field: "#E3E3E8",
        .separator: "#D1D1D6", .textPrimary: "#1C1C1E", .textSecondary: "#6C6C70",
        .textTertiary: "#8E8E93", .accent: "#0A6EC4", .accentText: "#FFFFFF",
        .secondaryAccent: "#1B8FCF", .favorite: "#E0A100", .danger: "#D93025",
        .editorSurround: "#D8DADD", .tabBar: "#DCE3EF", .toolBar: "#EEF2F8",
        .toolBarText: "#1F335C", .toolSelection: "#2B4A78", .toolSelectionText: "#FFFFFF",
        .quickBar: "#FFFFFF", .quickBarText: "#1C1C1E", .quickBarOutline: "#0000002E",
        .sheet: "#F2F2F7", .sheetText: "#1C1C1E", .sheetSecondaryText: "#6C6C70",
      ]),
      dark: palette([
        .background: "#060606", .surface: "#0E0E0E", .surfaceRaised: "#2E2E2E", .field: "#1C1C1C",
        .separator: "#2E2E2E", .textPrimary: "#FFFFFF", .textSecondary: "#A1A1A1",
        .textTertiary: "#737373", .accent: "#057AC7", .accentText: "#FFFFFF",
        .secondaryAccent: "#32ADE6", .favorite: "#FFCC00", .danger: "#FF453A",
        .editorSurround: "#1B1C1D", .tabBar: "#1F335C", .toolBar: "#2B4A78",
        .toolBarText: "#FFFFFF", .toolSelection: "#FFFFFFD9", .toolSelectionText: "#1F335C",
        .quickBar: "#292B2E", .quickBarText: "#FFFFFF", .quickBarOutline: "#FFFFFF2E",
        .sheet: "#1C1C1E", .sheetText: "#FFFFFF", .sheetSecondaryText: "#98989F",
      ]))
    theme.author = "NotesCraft"
    theme.isBuiltIn = true
    return theme
  }()

  // Warm paper tones and a serif typeface.
  public static let sepia: Theme = {
    var theme = Theme(
      id: "app.notecraft.sepia", name: "Sepia",
      light: palette([
        .background: "#F4ECD8", .surface: "#FBF5E6", .surfaceRaised: "#E9DFC4", .field: "#EDE3CB",
        .separator: "#D8CCAE", .textPrimary: "#3B2F20", .textSecondary: "#7A6A52",
        .textTertiary: "#A09070", .accent: "#B5651D", .accentText: "#FFFFFF",
        .secondaryAccent: "#8A6D3B", .favorite: "#C99700", .danger: "#B3261E",
        .editorSurround: "#CFC4A8", .tabBar: "#6B4F2A", .toolBar: "#8A6B3F",
        .toolBarText: "#FFF8E7", .toolSelection: "#FFF8E7D9", .toolSelectionText: "#5A4220",
        .quickBar: "#FBF5E6", .quickBarText: "#3B2F20", .quickBarOutline: "#3B2F2033",
        .sheet: "#F4ECD8", .sheetText: "#3B2F20", .sheetSecondaryText: "#7A6A52",
      ]),
      dark: palette([
        .background: "#14100A", .surface: "#1D1810", .surfaceRaised: "#2E2618", .field: "#241E13",
        .separator: "#3A301F", .textPrimary: "#EFE4CC", .textSecondary: "#B3A280",
        .textTertiary: "#857656", .accent: "#D9893D", .accentText: "#1B1409",
        .secondaryAccent: "#C2A25F", .favorite: "#E3B53C", .danger: "#E5645B",
        .editorSurround: "#0F0C07", .tabBar: "#3A2B14", .toolBar: "#4F3B1D",
        .toolBarText: "#FFF3D6", .toolSelection: "#FFF3D6D9", .toolSelectionText: "#3A2B14",
        .quickBar: "#2B2418", .quickBarText: "#EFE4CC", .quickBarOutline: "#FFF3D633",
        .sheet: "#1D1810", .sheetText: "#EFE4CC", .sheetSecondaryText: "#B3A280",
      ]))
    theme.author = "NotesCraft"
    theme.typography.design = .serif
    theme.isBuiltIn = true
    return theme
  }()

  // Black and white with one accent, a monospaced typeface and square corners.
  public static let mono: Theme = {
    var theme = Theme(
      id: "app.notecraft.mono", name: "Mono",
      light: palette([
        .background: "#FFFFFF", .surface: "#F5F5F5", .surfaceRaised: "#E8E8E8", .field: "#EFEFEF",
        .separator: "#000000", .textPrimary: "#000000", .textSecondary: "#4D4D4D",
        .textTertiary: "#808080", .accent: "#000000", .accentText: "#FFFFFF",
        .secondaryAccent: "#4D4D4D", .favorite: "#000000", .danger: "#C00000",
        .editorSurround: "#CCCCCC", .tabBar: "#000000", .toolBar: "#1A1A1A",
        .toolBarText: "#FFFFFF", .toolSelection: "#FFFFFF", .toolSelectionText: "#000000",
        .quickBar: "#FFFFFF", .quickBarText: "#000000", .quickBarOutline: "#000000",
        .sheet: "#FFFFFF", .sheetText: "#000000", .sheetSecondaryText: "#4D4D4D",
      ]),
      dark: palette([
        .background: "#000000", .surface: "#0A0A0A", .surfaceRaised: "#1F1F1F", .field: "#141414",
        .separator: "#FFFFFF", .textPrimary: "#FFFFFF", .textSecondary: "#B3B3B3",
        .textTertiary: "#808080", .accent: "#FFFFFF", .accentText: "#000000",
        .secondaryAccent: "#B3B3B3", .favorite: "#FFFFFF", .danger: "#FF6B6B",
        .editorSurround: "#111111", .tabBar: "#000000", .toolBar: "#0A0A0A",
        .toolBarText: "#FFFFFF", .toolSelection: "#FFFFFF", .toolSelectionText: "#000000",
        .quickBar: "#000000", .quickBarText: "#FFFFFF", .quickBarOutline: "#FFFFFF",
        .sheet: "#000000", .sheetText: "#FFFFFF", .sheetSecondaryText: "#B3B3B3",
      ]))
    theme.author = "NotesCraft"
    theme.typography.design = .monospaced
    theme.shape.cornerScale = 0.25
    theme.isBuiltIn = true
    return theme
  }()

  public static let builtIn: [Theme] = [classic, sepia, mono]
  public static let standard = classic
}
