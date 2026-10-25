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
  // Several at once, written once: a pack of stickers.
  func add(contentsOf new: [ElementClip]) throws {
    guard loadError == nil else { throw PackageError.invalidPackage }
    try persist(clips + new)
  }
  func remove(ids: Set<UUID>) throws {
    guard loadError == nil else { throw PackageError.invalidPackage }
    try persist(clips.filter { !ids.contains($0.id) })
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
  let onSelect: (StickerChoice) -> Void
  let onError: (String) -> Void
  @State private var renamed: ElementClip?
  @State private var title = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Stickers").font(.theme(.headline))
      Text("Choose a sticker, then tap the page. You can move, resize, rotate and recolor it.")
        .font(.theme(.caption)).foregroundStyle(.secondary)
      if let error = library.loadError { Text(error).font(.theme(.caption)).foregroundStyle(.red) }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 10) {
            ForEach(ShapeKind.stickers, id: \.self) { kind in
              Button {
                onSelect(.vector(kind))
              } label: {
                ShapeIcon(kind: kind).frame(height: 60)
                  .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                  .contentShape(Rectangle())
              }.accessibilityLabel(kind.title)
            }
          }
          Text("Emoji").font(.theme(.subheadline).bold())
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 6) {
            ForEach(StickerCatalog.emoji, id: \.self) { symbol in
              Button {
                onSelect(.emoji(symbol))
              } label: {
                Text(symbol).font(.theme(30)).frame(width: 48, height: 48)
                  .contentShape(Rectangle())
              }.accessibilityLabel("Emoji \(symbol)")
            }
          }
          if !library.clips.isEmpty {
            Text("My elements").font(.theme(.subheadline).bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
              ForEach(library.clips) { clip in
                Button {
                  onSelect(.clip(clip.id))
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
                    Text(clip.title).font(.theme(.caption)).lineLimit(1)
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
            }
          } else {
            Text("Save a lasso selection (… menu) to build your own collection.").font(.theme(.caption))
              .foregroundStyle(.secondary)
          }
        }.padding(2)
      }.frame(maxHeight: 420)
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
