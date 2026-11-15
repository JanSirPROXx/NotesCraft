import Foundation

// The texts the core has to give back in words (the names of paper, shapes and themes, what went
// wrong when a pack or a file is refused). The core has no catalog of its own: its texts are found
// in the code like those of the app and kept in the app's catalog, and the app tells the core which
// language bundle to read them from, so that a language chosen in Settings applies here too.
public enum CoreLocalization {
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBundle = Bundle.main
    private var storedLocale = Locale.current
    var bundle: Bundle {
      get { lock.lock(); defer { lock.unlock() }; return storedBundle }
      set { lock.lock(); defer { lock.unlock() }; storedBundle = newValue }
    }
    var locale: Locale {
      get { lock.lock(); defer { lock.unlock() }; return storedLocale }
      set { lock.lock(); defer { lock.unlock() }; storedLocale = newValue }
    }
  }
  private static let state = State()

  public static var bundle: Bundle {
    get { state.bundle }
    set { state.bundle = newValue }
  }
  public static var locale: Locale {
    get { state.locale }
    set { state.locale = newValue }
  }
}

// A text of the core, in the language that is chosen.
public func coreText(_ value: String.LocalizationValue) -> String {
  String(localized: value, bundle: CoreLocalization.bundle, locale: CoreLocalization.locale)
}
