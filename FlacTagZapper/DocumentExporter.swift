import SwiftUI
#if canImport(UIKit)
import UIKit

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<URL, Error>) -> Void

        init(onCompletion: @escaping (Result<URL, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let pickedURL = urls.first else {
                onCompletion(.failure(CocoaError(.fileNoSuchFile)))
                return
            }
            onCompletion(.success(pickedURL))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {

        }
    }
}
#endif
