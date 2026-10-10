import Foundation

public enum PackageError: LocalizedError {
    case invalidPackage, unsupportedVersion(Int), invalidAsset(String), conflict
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "The notebook package is missing or contains invalid data."
        case .unsupportedVersion(let v): "This notebook uses format version \(v), which this app cannot open."
        case .invalidAsset(let name): "Invalid or missing notebook asset: \(name)."
        case .conflict: "The notebook changed on disk. Reopen it before saving to avoid overwriting another edit."
        }
    }
}
public struct NotebookPackage: Sendable {
    public var notebook: Notebook
    public var assets: [String: Data]
    public init(notebook: Notebook = Notebook(), assets: [String: Data] = [:]) { self.notebook = notebook; self.assets = assets }
    private struct Manifest: Codable { let version: Int; let notebook: Notebook }
    private static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") }
    public func fileWrapper() throws -> FileWrapper {
        guard !notebook.pages.isEmpty else { throw PackageError.invalidPackage }
        var files: [String: FileWrapper] = [:]
        for (name, data) in assets {
            guard Self.validName(name) else { throw PackageError.invalidAsset(name) }
            files[name] = FileWrapper(regularFileWithContents: data)
        }
        try validateAssets()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return FileWrapper(directoryWithFileWrappers: ["manifest.json": FileWrapper(regularFileWithContents: try encoder.encode(Manifest(version: 1, notebook: notebook))), "assets": FileWrapper(directoryWithFileWrappers: files)])
    }
    public init(fileWrapper: FileWrapper) throws {
        guard let files = fileWrapper.fileWrappers, let data = files["manifest.json"]?.regularFileContents else { throw PackageError.invalidPackage }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1 else { throw PackageError.unsupportedVersion(manifest.version) }
        notebook = manifest.notebook
        guard !notebook.pages.isEmpty else { throw PackageError.invalidPackage }
        assets = [:]
        for (name, file) in files["assets"]?.fileWrappers ?? [:] {
            guard Self.validName(name), let data = file.regularFileContents else { throw PackageError.invalidAsset(name) }
            assets[name] = data
        }
        try validateAssets()
    }
    private func validateAssets() throws {
        for page in notebook.pages {
            for name in page.images.map(\.filename) + [page.backgroundPDF].compactMap({ $0 }) {
                guard Self.validName(name), assets[name] != nil else { throw PackageError.invalidAsset(name) }
            }
            let dimensions = page.paper.dimensions
            guard dimensions.x.isFinite, dimensions.y.isFinite,
                  page.strokes.allSatisfy({ $0.width.isFinite && $0.width > 0 && $0.samples.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && $0.pressure.isFinite && $0.altitude.isFinite } }) else { throw PackageError.invalidPackage }
        }
    }
}

// System document APIs own coordination in the app. This actor supports explicit package I/O and conflict-safe tooling.
public actor PackageStore {
    public init() {}
    public func read(from url: URL) throws -> NotebookPackage {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<NotebookPackage, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try NotebookPackage(fileWrapper: FileWrapper(url: coordinatedURL, options: .immediate)) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PackageError.invalidPackage }
        return try result.get()
    }
    public func save(_ package: NotebookPackage, to url: URL, expectedRevision: UInt64? = nil) throws {
        let wrapper = try package.fileWrapper()
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                if let expectedRevision, FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existing = try NotebookPackage(fileWrapper: FileWrapper(url: coordinatedURL, options: .immediate))
                    guard existing.notebook.revision == expectedRevision else { throw PackageError.conflict }
                }
                try wrapper.write(to: coordinatedURL, options: .atomic, originalContentsURL: nil)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PackageError.invalidPackage }
        try result.get()
    }
}
