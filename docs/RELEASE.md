# iOS App Store release

One-time setup (needs the Apple Developer account, cannot be scripted):

1. App Store Connect → Apps → **+** → New App. Platform iOS, bundle ID `notescraft`
   (register it under Certificates, Identifiers & Profiles first if it is missing), choose a SKU.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`
   (gitignored; never commit signing details).
3. Fill in the store listing: name, subtitle, description, keywords, support URL, **privacy policy URL**
   (required; the text is in `docs/PRIVACY.md`, fill in the contact placeholders and publish it on a
   public URL, for example the file's page on GitHub or GitHub Pages), category (Productivity), age rating.
4. App Privacy: "Data Not Collected" matches the app (no backend, no analytics, no accounts).
   `Sources/NoteCraft/PrivacyInfo.xcprivacy` declares the required-reason APIs in use
   (UserDefaults `CA92.1`, file timestamps `C617.1`/`3B52.1`); update it when adding such APIs.
5. Screenshots: iPad 13" (2064×2752) is required. The app is iPad only (`TARGETED_DEVICE_FAMILY` is `2`),
   so no iPhone screenshots are needed. `scripts/screenshots.sh` renders them on the "iPad Pro 13-inch (M5)"
   simulator into `docs/screenshots/appstore/` (the debug build fills each new document with a sample page,
   see `ScreenshotScenes.swift`; Release builds contain none of it). Re-run it after UI changes.
6. Export compliance is answered in `Info.plist` (`ITSAppUsesNonExemptEncryption = NO`).

Each release:

```sh
# bump MARKETING_VERSION in project.yml for a new version, then
xcodegen generate
scripts/release-ios.sh        # tests, archives, uploads; build number defaults to a timestamp
```

Then pick the processed build in App Store Connect, test it through TestFlight, and submit for review.
Review notes worth including: the app opens `.notecraft` packages from the Files app, the camera is used only
for scanning paper documents, and drawing with a finger is off by default (Apple Pencil draws).
