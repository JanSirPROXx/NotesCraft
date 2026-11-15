# Localization

NotesCraft is written in English and ships in English, German (de), French (fr), Spanish (es) and Italian (it).
By default the app uses the language of the iPad (the first of the iPad's languages the app has texts for,
otherwise English); Settings ▸ Language chooses another one, and the choice applies at once.

## Where the texts live

- `Sources/NoteCraft/Localizable.xcstrings` is the one String Catalog (source language English). It holds the
  texts of the app **and** of `NoteCraftCore`, which has no catalog of its own.
- `Sources/NoteCraft/InfoPlist.xcstrings` holds the system-facing strings (the camera usage text).
- `scripts/l10n/translations.txt` is the translation table: one line per text, `English ‖ de ‖ fr ‖ es ‖ it`,
  `\n` for a line break. The catalog is written from it; edit the table, not the catalog, so the translations stay
  reviewable as plain text.
- `scripts/l10n.py` keeps the two in step (below).

## How a text gets to the screen

| Where the text is made | How to write it |
| --- | --- |
| A SwiftUI literal: `Text("Done")`, `Button("Save")`, `Label("Share", …)`, `Toggle("…")` | Write the English literal. It follows the locale in the environment (`ThemedRoot` sets it from `LanguageStore`). |
| A parameter that is passed on to such a view | Type it `LocalizedStringKey`, not `String`. |
| Code that builds a string: status lines, errors, titles from enums, `accessibilityLabel(String)`, `UIKit` | `tr("…")` (app) or `coreText("…")` (`NoteCraftCore`). Both read the bundle of the chosen language. A view that calls `tr` redraws when the language changes. |
| `.navigationTitle`, `.alert`, `.confirmationDialog` titles | `tr("…")`: UIKit draws them and ignores the environment's locale. |

Rules that came from bugs:

- **Never write `AppleLanguages` at runtime.** Doing so makes UIKit's focus system abort the app
  (`_UIFocusContainerGuideFallbackItemsContainer initWithParentEnvironment:childItems:`). The choice is kept in
  `UserDefaults` key `appLanguage` (`LanguageStore`); what the system itself draws (file picker, share sheet,
  permission prompts) keeps following the iPad, and Settings says so.
- Do not join literals with `+` inside `Text`: `Text("a" + "b")` is looked up verbatim and never translated. Use
  one literal; break a long one with `\` at the end of the line.
- `Text(condition ? "a" : "b")` is a `String`, not a key: use `if/else` between two `Text`s or `tr`.
- Put the variable part in an interpolation, never concatenate sentences: `"Delete \(title)?"` becomes one catalog
  entry with `%@`, so a language can move the word.
- Units, numbers, font names and the brand carry no translation: `sync` marks them `shouldTranslate: false`.
- Developer-facing validation text (a theme or pack author reading why their file is refused, e.g. "the hash is …")
  stays English on purpose; what a person using the app reads is translated.
- A container's `.accessibilityIdentifier` replaces those of its children. UI tests find controls by identifier or
  by the English label; tests that run in another language use the identifiers (`language-de`, …).
- Content that is *data* is not translated: pack titles and summaries in the marketplace catalog, the names a person
  gave to documents, the default title of a notebook once it is saved (it is made in the language of that moment).

## Adding or changing a text

1. Write the English text in the code the way the table above says.
2. Build the iPad scheme (this lets the compiler extract the texts):
   `xcodebuild -project NoteCraft.xcodeproj -scheme NoteCraft-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build`
3. Add one line to `scripts/l10n/translations.txt` with the English text exactly as it is in the code
   (placeholders written the way the catalog has them: `%@`, `%lld`).
4. `python3 scripts/l10n.py sync`, then `python3 scripts/l10n.py check`.

`check` fails when a text lacks a language, when a translation has other placeholders than the English text, and when
the table has a line the code no longer uses. Run it before committing; a changed English text is a new key.

## Adding a language

1. Add the code to `AppLanguage` and `LanguageStore.supported` (`Localization.swift`), and its name in itself to
   `nativeName`.
2. Add it to `LANGS` in `scripts/l10n.py`, a column to every line of the table, and to `CFBundleLocalizations` in
   `project.yml`; `InfoPlist.xcstrings` needs the camera text in it too.
3. Add a row to the language list in Settings (it is built from `AppLanguage.allCases`).
4. `python3 scripts/l10n.py sync`, `check`, and look at the screens in that language (long German or French words are
   the usual cause of truncation).

## What is tested

- `scripts/l10n.py check` (catalog complete, placeholders match).
- `LanguageUITests`: Settings ▸ Language switches the whole app to German without a restart (library, sheets, notebook
  tools) and back to the system language.
- `swift test` covers the core texts only where a test reads them (they are looked up in the main bundle there, so the
  tests see English).

## Not done on purpose

- Right-to-left languages (none of the five is one).
- Localized store metadata is in `docs/appstore/` and is entered in App Store Connect by hand.
- The notation of the calculator pen stays English (`.` decimal point): decided with the product owner, see
  docs/CALCULATOR.md.
