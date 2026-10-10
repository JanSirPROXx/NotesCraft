import Foundation

public struct ElementClip: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var content: Page
  public var assets: [String: Data]

  public init(id: UUID = UUID(), title: String, content: Page, assets: [String: Data] = [:]) {
    self.id = id
    self.title = title
    self.content = content
    self.assets = assets
  }

  public static func capture(title: String, page: Page, ids: Set<UUID>, assets: [String: Data])
    throws -> Self
  {
    guard let bounds = InkGestures.selectionBounds(page: page, ids: ids) else {
      throw PackageError.invalidPackage
    }
    var content = Page(paper: Paper(pattern: .blank))
    content.strokes = page.strokes.filter { ids.contains($0.id) }
    content.texts = page.texts.filter { ids.contains($0.id) }
    content.images = page.images.filter { ids.contains($0.id) }
    var media: [String: Data] = [:]
    for image in content.images {
      guard let data = assets[image.filename] else {
        throw PackageError.invalidAsset(image.filename)
      }
      media[image.filename] = data
    }
    content = InkGestures.translate(content, ids: ids, by: Point(-bounds.x, -bounds.y))
    content.backgroundSize = Point(max(1, bounds.width), max(1, bounds.height))
    return Self(title: title, content: content, assets: media)
  }

  public func insert(into package: inout NotebookPackage, pageIndex: Int, at point: Point) throws {
    guard package.notebook.pages.indices.contains(pageIndex) else {
      throw PackageError.invalidPackage
    }
    // Remap media and object identities so a clip from another vault cannot replace existing content.
    var content = content
    var media: [String: Data] = [:]
    var filenames: [String: String] = [:]
    for image in content.images {
      guard let data = assets[image.filename] else {
        throw PackageError.invalidAsset(image.filename)
      }
      if filenames[image.filename] == nil {
        let name = UUID().uuidString + ".image"
        filenames[image.filename] = name
        media[name] = data
      }
    }
    for i in content.images.indices {
      content.images[i].id = UUID()
      content.images[i].filename = filenames[content.images[i].filename]!
    }
    for i in content.strokes.indices { content.strokes[i].id = UUID() }
    for i in content.texts.indices { content.texts[i].id = UUID() }
    let ids = Set(content.strokes.map(\.id) + content.texts.map(\.id) + content.images.map(\.id))
    let bounds =
      InkGestures.selectionBounds(page: content, ids: ids)
      ?? Rect(x: 0, y: 0, width: 0, height: 0)
    content = InkGestures.translate(
      content, ids: ids,
      by: Point(point.x - bounds.x - bounds.width / 2, point.y - bounds.y - bounds.height / 2))
    package.assets.merge(media) { existing, _ in existing }
    package.notebook.pages[pageIndex].strokes += content.strokes
    package.notebook.pages[pageIndex].texts += content.texts
    package.notebook.pages[pageIndex].images += content.images
  }
}

extension InkGestures {
  public static func duplicatePage(_ page: Page) -> Page {
    var result = page
    result.id = UUID()
    for i in result.strokes.indices { result.strokes[i].id = UUID() }
    for i in result.texts.indices { result.texts[i].id = UUID() }
    for i in result.images.indices { result.images[i].id = UUID() }
    return result
  }
}
