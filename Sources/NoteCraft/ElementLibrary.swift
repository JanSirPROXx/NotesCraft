import NoteCraftCore
import Observation
import SwiftUI

@MainActor @Observable final class ElementLibrary {
  static let shared = ElementLibrary()
  private(set) var clips: [ElementClip] = []
  private(set) var loadError: String?
  private let url: URL

  init(directory: URL? = nil, defaults: UserDefaults = .standard) {
    let directory =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("NoteCraft", isDirectory: true)
    url = directory.appendingPathComponent("Elements.json")
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        clips = try JSONDecoder().decode([ElementClip].self, from: Data(contentsOf: url))
      } else if let data = defaults.data(forKey: "savedElement"),
        let strokes = try? JSONDecoder().decode([Stroke].self, from: data), !strokes.isEmpty
      {
        var page = Page(paper: Paper(pattern: .blank))
        page.strokes = strokes
        let clip = try ElementClip.capture(
          title: "Saved element", page: page,
          ids: Set(strokes.map(\.id)), assets: [:])
        try add(clip)
      }
    } catch { loadError = error.localizedDescription }
  }
  func add(_ clip: ElementClip) throws {
    guard loadError == nil else { throw PackageError.invalidPackage }
    var updated = clips
    updated.append(clip)
    try persist(updated)
  }
  func rename(_ id: UUID, title: String) throws {
    guard loadError == nil else { throw PackageError.invalidPackage }
    var updated = clips
    if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].title = title }
    try persist(updated)
  }
  func remove(_ id: UUID) throws {
    guard loadError == nil else { throw PackageError.invalidPackage }
    try persist(clips.filter { $0.id != id })
  }
  private func persist(_ updated: [ElementClip]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try JSONEncoder().encode(updated).write(to: url, options: .atomic)
    clips = updated
  }
}

struct ElementPicker: View {
  @Bindable var library: ElementLibrary
  let onSelect: (ElementClip?) -> Void
  let onError: (String) -> Void
  @State private var renamed: ElementClip?
  @State private var title = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Elements").font(.headline)
      Text("Choose an element, then tap the page to insert it.").font(.caption).foregroundStyle(
        .secondary)
      if let error = library.loadError { Text(error).font(.caption).foregroundStyle(.red) }
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
          Button {
            onSelect(nil)
          } label: {
            VStack(spacing: 8) {
              Image(systemName: "star").font(.system(size: 40)).frame(height: 74)
              Text("Star").font(.caption)
            }.frame(maxWidth: .infinity)
          }
          ForEach(library.clips) { clip in
            Button {
              onSelect(clip)
            } label: {
              VStack(spacing: 8) {
                Canvas { context, size in
                  context.withCGContext { c in
                    let dimensions = clip.content.dimensions
                    let scale = min(
                      (size.width - 12) / dimensions.x, (size.height - 12) / dimensions.y)
                    c.translateBy(
                      x: (size.width - dimensions.x * scale) / 2,
                      y: (size.height - dimensions.y * scale) / 2)
                    c.scaleBy(x: scale, y: scale)
                    PageRenderer.render(clip.content, assets: clip.assets, in: c)
                  }
                }.frame(height: 74).background(.white, in: RoundedRectangle(cornerRadius: 6))
                Text(clip.title).font(.caption).lineLimit(1)
              }
            }.contextMenu {
              Button("Rename") {
                renamed = clip
                title = clip.title
              }
              Button("Delete", role: .destructive) {
                do { try library.remove(clip.id) } catch { onError(error.localizedDescription) }
              }
            }
          }
        }.padding(2)
      }.frame(maxHeight: 280)
      if library.clips.isEmpty {
        Text("Save a lasso selection to build your collection.").font(.caption)
      }
    }.buttonStyle(.plain)
      .alert(
        "Rename element",
        isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })
      ) {
        TextField("Name", text: $title)
        Button("Cancel", role: .cancel) { renamed = nil }
        Button("Save") {
          if let renamed {
            do { try library.rename(renamed.id, title: title) } catch {
              onError(error.localizedDescription)
            }
          }
          renamed = nil
        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
  }
}
