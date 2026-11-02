#if os(iOS)
  import UIKit
  import UniformTypeIdentifiers

  // The system's file picker, shown from UIKit instead of SwiftUI's `fileImporter`. A `fileImporter`
  // is dropped without a word when another one sits on a view above it (the library has two) or when
  // it is asked for while a menu is still closing; both are the ways a "Import PDF" in the ⋯ menu
  // came to do nothing. A picker presented on the topmost controller has neither problem.
  @MainActor enum FilePicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
      let completion: (Result<URL, Error>) -> Void
      init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
      func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { completion(.success(url)) }
        FilePicker.delegate = nil
      }
      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        FilePicker.delegate = nil
      }
    }
    // The picker only keeps a weak reference to its delegate.
    private static var delegate: Delegate?

    static func open(
      types: [UTType], completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      picker.allowsMultipleSelection = false
      let handler = Delegate { result in Task { @MainActor in completion(result) } }
      delegate = handler
      picker.delegate = handler
      topmost()?.present(picker, animated: true)
    }

    private static func topmost() -> UIViewController? {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
      while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
      return top
    }
  }
#endif
