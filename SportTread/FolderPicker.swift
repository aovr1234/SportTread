import UIKit
import UniformTypeIdentifiers

/// Presents the standard Files folder picker straight from UIKit.
/// SwiftUI's fileImporter and a picker wrapped in a SwiftUI sheet both left the Open button
/// unresponsive on device; presenting directly avoids SwiftUI creating duplicate pickers
/// that invalidate each other (see LNPANDY/NX2Apple#315).
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var onPick: ((URL) -> Void)?
    private var onCancel: (() -> Void)?

    /// Returns false if there was no screen to present from.
    @discardableResult
    func present(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) -> Bool {
        guard let top = Self.topViewController() else { return false }
        self.onPick = onPick
        self.onCancel = onCancel
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            onPick?(url)
        } else {
            onCancel?()
        }
        clear()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel?()
        clear()
    }

    private func clear() {
        onPick = nil
        onCancel = nil
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
