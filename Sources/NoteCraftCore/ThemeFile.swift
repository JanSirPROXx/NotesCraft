import Foundation

public enum ThemeError: Error, Equatable, LocalizedError {
  case notAThemeFile
  case unsupportedFormat(Int)
  case invalidID(String)
  case missingName
  case invalidColor(token: String, value: String)
  case invalidIcon(String)
  case invalidPath(String)
  case unsupportedFile(String)
  case missingFile(String)
  case tooLarge(String)
  case tooManyFiles

  public var errorDescription: String? {
    switch self {
    case .notAThemeFile: "This is not a NotesCraft theme: there is no readable theme.json."
    case .unsupportedFormat(let n): "This theme uses format \(n), which this version cannot read."
    case .invalidID(let id): "“\(id)” is not a valid theme id (lowercase letters, digits, dots, dashes; 3 to 64 characters)."
    case .missingName: "The theme has no name."
    case .invalidColor(let token, let value): "The color “\(token)” is “\(value)”, which is not a color like #RRGGBB."
    case .invalidIcon(let name): "The icon “\(name)” must be “symbol:name” or a path to an image."
    case .invalidPath(let path): "“\(path)” points outside the theme."
    case .unsupportedFile(let path): "“\(path)” is a kind of file a theme cannot hold."
    case .missingFile(let path): "The theme names “\(path)”, which is not in it."
    case .tooLarge(let what): "\(what) is too large for a theme."
    case .tooManyFiles: "The theme has too many files."
    }
  }
}

// The text of a theme: `theme.json`.
public enum ThemeFile {
  public static let format = 1
  public static let fileName = "theme.json"
  public static let maxBytes = 256 * 1024

  private struct Document: Codable {
    var format: Int
    var id: String
    var name: String
    var author: String?
    var version: String?
    var colors: [String: [String: String]]?
    var typography: Typography?
    var icons: [String: String]?
    var shape: Shape?
  }
  private struct Typography: Codable {
    var design: String?
    var family: String?
    var files: [String]?
    var scale: Double?
  }
  private struct Shape: Codable {
    var cornerScale: Double?
  }

  public static func isValid(id: String) -> Bool {
    guard (3...64).contains(id.count), let first = id.first, first.isASCII,
      first.isLowercase || first.isNumber
    else { return false }
    return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || ".-_".contains($0)) }
  }

  public static func parse(_ data: Data) throws -> Theme {
    guard data.count <= maxBytes else { throw ThemeError.tooLarge("theme.json") }
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
      throw ThemeError.notAThemeFile
    }
    guard document.format == format else { throw ThemeError.unsupportedFormat(document.format) }
    guard isValid(id: document.id) else { throw ThemeError.invalidID(document.id) }
    let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 60 else { throw ThemeError.missingName }

    func palette(_ scheme: String) throws -> ThemePalette {
      var result: ThemePalette = [:]
      for (key, value) in document.colors?[scheme] ?? [:] {
        // A token this version does not know is from a later one: leave it out.
        guard let token = ThemeColorToken(rawValue: key) else { continue }
        guard let color = ThemeColor(hex: value) else {
          throw ThemeError.invalidColor(token: "\(scheme).\(key)", value: value)
        }
        result[token] = color
      }
      return result
    }
    let light = try palette("light")
    let dark = try palette("dark")
    var schemes: Set<ThemeScheme> = []
    if !light.isEmpty { schemes.insert(.light) }
    if !dark.isEmpty { schemes.insert(.dark) }
    // A theme of fonts and icons only has no opinion on light and dark.
    if schemes.isEmpty { schemes = [.light, .dark] }

    var theme = Theme(id: document.id, name: name, light: light, dark: dark, schemes: schemes)
    theme.author = String((document.author ?? "").prefix(80))
    theme.version = String((document.version ?? "1").prefix(24))
    if let typography = document.typography {
      theme.typography.design =
        ThemeTypography.Design(rawValue: typography.design ?? "standard") ?? .standard
      theme.typography.family = typography.family.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
      theme.typography.files = typography.files ?? []
      theme.typography.scale = min(1.3, max(0.8, typography.scale ?? 1))
    }
    for (symbol, replacement) in document.icons ?? [:] {
      guard !symbol.isEmpty, symbol.count <= 80, !replacement.isEmpty else {
        throw ThemeError.invalidIcon(symbol)
      }
      if replacement.hasPrefix("symbol:") {
        let name = String(replacement.dropFirst("symbol:".count))
        guard !name.isEmpty, name.count <= 80 else { throw ThemeError.invalidIcon(symbol) }
        theme.icons[symbol] = .symbol(name)
      } else {
        theme.icons[symbol] = .file(replacement)
      }
    }
    if let shape = document.shape {
      theme.shape.cornerScale = min(2.5, max(0, shape.cornerScale ?? 1))
    }
    return theme
  }

  // The file for a theme, as `parse` reads it.
  public static func encode(_ theme: Theme) throws -> Data {
    func colors(_ palette: ThemePalette) -> [String: String] {
      Dictionary(uniqueKeysWithValues: palette.map { ($0.key.rawValue, $0.value.hex) })
    }
    var all: [String: [String: String]] = [:]
    if theme.schemes.contains(.light) { all["light"] = colors(theme.light) }
    if theme.schemes.contains(.dark) { all["dark"] = colors(theme.dark) }
    var typography: Typography?
    if theme.typography != .standard {
      typography = Typography(
        design: theme.typography.design.rawValue, family: theme.typography.family,
        files: theme.typography.files.isEmpty ? nil : theme.typography.files,
        scale: theme.typography.scale)
    }
    var icons: [String: String]?
    if !theme.icons.isEmpty {
      icons = theme.icons.mapValues {
        switch $0 {
        case .symbol(let name): "symbol:" + name
        case .file(let path): path
        }
      }
    }
    let document = Document(
      format: format, id: theme.id, name: theme.name, author: theme.author,
      version: theme.version, colors: all, typography: typography, icons: icons,
      shape: theme.shape == .standard ? nil : Shape(cornerScale: theme.shape.cornerScale))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
  }
}

// A theme as a folder: `theme.json`, and the fonts and icons it names.
public enum ThemePackage {
  public static let maxTotalBytes = 20 * 1024 * 1024
  public static let maxFiles = 400
  public static let fontExtensions: Set<String> = ["ttf", "otf"]
  public static let imageExtensions: Set<String> = ["png", "pdf", "jpg", "jpeg"]
  private static let documentExtensions: Set<String> = ["md", "txt"]

  // Reads and checks a package: the theme file, every file it names, and that nothing else in the
  // folder is anything but fonts, images and notes. Fonts and images are only ever loaded by the
  // system's own decoders; nothing in a package is run.
  public static func load(from directory: URL) throws -> Theme {
    let fm = FileManager.default
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let jsonURL = root.appendingPathComponent(ThemeFile.fileName)
    guard let data = try? Data(contentsOf: jsonURL) else { throw ThemeError.notAThemeFile }
    let theme = try ThemeFile.parse(data)

    var files = 0
    var bytes = 0
    guard
      let walker = fm.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
    else { throw ThemeError.notAThemeFile }
    for case let url as URL in walker {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      let relative = relativePath(of: url, in: root)
      if values.isSymbolicLink == true { throw ThemeError.unsupportedFile(relative) }
      guard values.isRegularFile == true else { continue }
      files += 1
      bytes += values.fileSize ?? 0
      guard files <= maxFiles else { throw ThemeError.tooManyFiles }
      guard bytes <= maxTotalBytes else { throw ThemeError.tooLarge("The package") }
      let ext = url.pathExtension.lowercased()
      let allowed =
        relative == ThemeFile.fileName || fontExtensions.contains(ext)
        || imageExtensions.contains(ext) || documentExtensions.contains(ext)
      if !allowed { throw ThemeError.unsupportedFile(relative) }
    }

    var named = theme.typography.files
    for case .file(let path) in theme.icons.values { named.append(path) }
    for path in named {
      let url = try resolve(path, in: root)
      guard fm.fileExists(atPath: url.path) else { throw ThemeError.missingFile(path) }
      let ext = url.pathExtension.lowercased()
      let isFont = theme.typography.files.contains(path)
      guard isFont ? fontExtensions.contains(ext) : imageExtensions.contains(ext) else {
        throw ThemeError.unsupportedFile(path)
      }
    }
    return theme
  }

  // Where a path from a theme file is, or an error if it would leave the package.
  public static func resolve(_ path: String, in root: URL) throws -> URL {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
      throw ThemeError.invalidPath(path)
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
      throw ThemeError.invalidPath(path)
    }
    let url = parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path.hasPrefix(root.path + "/") else { throw ThemeError.invalidPath(path) }
    return resolved
  }

  private static func relativePath(of url: URL, in root: URL) -> String {
    let path = url.standardizedFileURL.path
    return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
  }
}
