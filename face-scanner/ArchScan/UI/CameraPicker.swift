import SwiftUI
import UIKit
import AVFoundation

/// Camera capture for a record. Photos and video go through the same picker, which
/// keeps the system's own capture UI — exposure, focus, the 48 MP main camera, the
/// telephoto for retracted shots — rather than a worse one rebuilt here.
struct CameraPicker: UIViewControllerRepresentable {

    enum Mode { case photo, video }

    let mode: Mode
    let onCapture: (Data, String) -> Void          // data, file extension
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        switch mode {
        case .photo:
            controller.mediaTypes = ["public.image"]
        case .video:
            controller.mediaTypes = ["public.movie"]
            controller.videoQuality = .typeHigh
            controller.videoMaximumDuration = 30
        }
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                parent.onCapture(data, "jpg")
            } else if let url = info[.mediaURL] as? URL, let data = try? Data(contentsOf: url) {
                parent.onCapture(data, url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased())
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
