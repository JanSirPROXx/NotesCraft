import NoteCraftCore
import PDFKit
import SwiftUI

struct VaultCover: View {
  let entry: VaultEntry
  @State private var preview: PlatformImage?
  var body: some View {
    Group {
      switch entry.kind {
      case .folder:
        Image(systemName: "folder.fill").resizable().scaledToFit().symbolRenderingMode(.palette)
          .foregroundStyle(
            Color(red: 0.42, green: 0.72, blue: 1), Color(red: 0.16, green: 0.52, blue: 0.91)
          ).padding(.horizontal, 10)
      case .notebook:
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.22, green: 0.76, blue: 0.89))
          Rectangle().fill(Color.black.opacity(0.13)).frame(width: 12).padding(.leading, 18)
          VStack {
            Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(3).foregroundStyle(
              Color(red: 0.04, green: 0.28, blue: 0.35))
            Spacer()
          }.padding(.top, 28).padding(.leading, 44).padding(.trailing, 14)
        }.aspectRatio(0.72, contentMode: .fit).padding(.horizontal, 24)
      case .whiteboard, .pdf, .image:
        ZStack {
          RoundedRectangle(cornerRadius: entry.kind == .whiteboard ? 12 : 4).fill(Color.white)
          if let preview {
            platformImage(preview).resizable().scaledToFit().padding(5)
          } else {
            Image(
              systemName: entry.kind == .whiteboard
                ? "rectangle.and.pencil.and.ellipsis"
                : entry.kind == .image ? "photo" : "doc.richtext"
            ).font(.system(size: 36, weight: .light)).foregroundStyle(Color(white: 0.45))
          }
        }.aspectRatio(entry.kind == .whiteboard ? 1.3 : 0.73, contentMode: .fit).overlay(
          alignment: .bottom
        ) {
          if entry.kind == .whiteboard {
            Capsule().fill(Color(white: 0.74)).frame(width: 100, height: 12)
          }
        }.padding(.horizontal, 8)
      case .markdown:
        ZStack {
          RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.92))
          Image(systemName: "doc.text").font(.system(size: 60, weight: .ultraLight))
            .foregroundStyle(Color(white: 0.35))
        }.aspectRatio(0.73, contentMode: .fit).padding(.horizontal, 24)
      case .other:
        Image(systemName: "doc").font(.system(size: 72, weight: .thin)).foregroundStyle(
          Color(white: 0.65))
      }
    }.task(id: entry.modified) { await thumbnail() }
  }
  private func platformImage(_ image: PlatformImage) -> Image {
    #if os(macOS)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
  private func thumbnail() async {
    guard entry.kind == .pdf || entry.kind == .image || entry.kind == .whiteboard else { return }
    if entry.kind == .whiteboard, let package = try? await PackageStore().read(from: entry.url),
      let data = try? PageRenderer.thumbnail(package)
    {
      preview = PlatformImage(data: data)
    } else if let snapshot = try? await VaultFiles().read(entry.url) {
      if entry.kind == .image {
        preview = PlatformImage(data: snapshot.data)
      } else {
        preview = PDFDocument(data: snapshot.data)?.page(at: 0)?.thumbnail(
          of: CGSize(width: 220, height: 300), for: .mediaBox)
      }
    }
  }
}
