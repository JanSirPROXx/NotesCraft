# App Store listing

The store text for every language the app ships is here, one folder per App Store Connect locale
(`en-US`, `de-DE`, `fr-FR`, `es-ES`, `it`), one file per field. The folder layout is the one fastlane's
`deliver` reads, so it can be uploaded with that later; for now it is pasted into App Store Connect.

```sh
python3 scripts/appstore_check.py   # limits, missing fields, repeated keywords, placeholders
```

| File | Field | Limit |
| --- | --- | --- |
| `name.txt` | Name | 30 |
| `subtitle.txt` | Subtitle | 30 |
| `promotional_text.txt` | Promotional text (can be changed without a new build) | 170 |
| `description.txt` | Description | 4000 |
| `keywords.txt` | Keywords, comma-separated, no spaces | 100 |
| `release_notes.txt` | What's New | 4000 |
| `support_url.txt`, `privacy_url.txt` | Support and privacy policy URL | https |

Rules for the text: it says only what the app does today; the Calculator pen is described as what it is (it
shows `?` rather than guess), nothing is promised about accuracy; no other app's name appears; the terms match the
ones in the app (`Boutique` in French, `Marktplatz` in German, `Rechenstift`, `Stylo calculatrice`,
`Lápiz calculadora`, `Penna calcolatrice`). Keywords do not repeat words from the name or subtitle, which Apple
indexes already. When a feature changes, change all five.

The privacy policy URL points at `docs/PRIVACY.md` on GitHub, which only works while the repository is public;
otherwise publish that file on any public page and change `privacy_url.txt`.

## Answers for the forms in App Store Connect

- **Category:** Productivity (primary), Education (secondary, optional).
- **Age rating:** 4+. Answer "None" to every content question. There is no web browser, no chat and no user-generated
  content (Marketplace packs are added to the repository by pull request and contain no code).
- **App Privacy:** "Data Not Collected". The developer receives nothing; the Marketplace downloads files from a public
  host (docs/PRIVACY.md says so).
- **Export compliance:** no non-exempt encryption (`ITSAppUsesNonExemptEncryption` is `NO` in the Info.plist).
- **Privacy manifest:** `Sources/NoteCraft/PrivacyInfo.xcprivacy` (no tracking, no collected data; UserDefaults and
  file-timestamp reasons).
- **Platform:** iPad only. The listing needs 13-inch iPad screenshots (2064 × 2752); `scripts/screenshots.sh` makes
  them in English. The other locales use the English screenshots until localized ones are made (the tour and its sample
  pages are English).
- **Copyright:** `© 2026 <your name or company>`.

## Review notes (paste into "App Review Information")

> NotesCraft is an iPad notebook for Apple Pencil. It needs no account and no sign-in. Notes are saved as files in a
> folder the reviewer chooses on first launch (any folder in the Files app, for example "On My iPad").
> Drawing with a finger is off by default (Apple Pencil draws); it can be switched on in Settings ▸ Apple Pencil (turn "Apple Pencil only" off). The camera
> is used only for scanning paper documents into a notebook. The Marketplace (sidebar) downloads free themes, stickers
> and templates from a public GitHub folder; the app also contains the starter packs, so it works offline. The language
> follows the iPad and can be changed in Settings ▸ Language. The "Calculator pen" (tool bar, +/− icon) reads a
> handwritten calculation ending in "=".

## What only the account holder can do

Create the app record, set price and availability, enter the text above, upload screenshots, answer the forms, fill
in the contact details in `docs/PRIVACY.md` (`[contact email]`, developer name and address), set
`DEVELOPMENT_TEAM` in `Config/Local.xcconfig`, archive and upload with `scripts/release-ios.sh`, and submit.
