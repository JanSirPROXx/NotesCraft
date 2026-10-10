#if os(iOS)
  import SwiftUI
  import VisionKit

  struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([Data]) -> Void
    var onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
      let controller = VNDocumentCameraViewController()
      controller.delegate = context.coordinator
      return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    // VisionKit delivers UI callbacks on the main thread but its legacy protocol is not actor-annotated.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
      let parent: DocumentScanner
      init(parent: DocumentScanner) { self.parent = parent }
      func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        parent.dismiss()
      }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: Error
      ) {
        parent.onError(error.localizedDescription)
        parent.dismiss()
      }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
      ) {
        let images = (0..<scan.pageCount).compactMap {
          scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.95)
        }
        parent.onScan(images)
        parent.dismiss()
      }
    }
  }
#endif
