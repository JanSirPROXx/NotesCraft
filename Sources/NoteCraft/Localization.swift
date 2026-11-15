import NoteCraftCore
import Observation
import SwiftUI

// The language of the app. By default it is the one the iPad is set to, and Settings can choose
// another; the choice applies at once and everywhere:
//   - texts written in SwiftUI (`Text("…")`, `Button("…")`) follow the locale in the environment,
//   - texts the code builds (`tr("…")`) and those of the core are read from the bundle of the
//     chosen language, and views that use them redraw when the language changes (they read
//     `revision` through `tr`),
// The texts themselves are in Localizable.xcstrings; see docs/LOCALIZATION.md.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system, en, de, fr, es, it
  var id: String { rawValue }

  // Each language is named in itself, as in the language list of the system.
  var nativeName: String? {
    switch self {
    case .system: nil
    case .en: "English"
    case .de: "Deutsch"
    case .fr: "Français"
    case .es: "Español"
    case .it: "Italiano"
    }
  }
}

@Observable final class LanguageStore: @unchecked Sendable {
  static let shared = LanguageStore()
  static let defaultsKey = "appLanguage"
  static let supported = ["en", "de", "fr", "es", "it"]

  private(set) var selection: AppLanguage
  // Counts up when the language changes: views that read it redraw.
  private(set) var revision = 0
  private(set) var bundle = Bundle.main
  private(set) var locale = Locale.current
  // The language the texts are in now: the chosen one, or the best the system's languages offer.
  private(set) var code = "en"

  private init() {
    selection = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
    resolve()
  }

  @MainActor func select(_ language: AppLanguage) {
    guard language != selection else { return }
    selection = language
    UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
    // The system's own language list (AppleLanguages) is deliberately left alone: writing it while the
    // app runs makes UIKit's focus system abort the app (seen on iPadOS 26). The choice is read again at
    // the next start, and what the system itself draws keeps following the iPad.
    resolve()
    revision += 1
  }

  // Which language `.system` stands for: the first language of the system that the app has texts for.
  static func systemCode() -> String {
    for preferred in Locale.preferredLanguages {
      let base = Locale(identifier: preferred).language.languageCode?.identifier ?? preferred
      if supported.contains(base) { return base }
    }
    return "en"
  }

  private func resolve() {
    if selection == .system {
      code = Self.systemCode()
      bundle = .main
      locale = .current
    } else {
      code = selection.rawValue
      bundle =
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
      locale = Locale(identifier: code)
    }
    CoreLocalization.bundle = bundle
    CoreLocalization.locale = locale
  }
}

// A text the code builds, in the language that is chosen. Reading `revision` makes a view that
// calls this redraw when the language is changed.
func tr(_ value: String.LocalizationValue) -> String {
  let store = LanguageStore.shared
  _ = store.revision
  return String(localized: value, bundle: store.bundle, locale: store.locale)
}
