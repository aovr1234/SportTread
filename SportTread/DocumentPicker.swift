import UIKit
import UniformTypeIdentifiers

/// Presents Files pickers straight from UIKit, in copy mode only.
/// Under Signulous signing, opening a folder in place never returns (Open does nothing),
/// so backups are exported as a copy and restores are imported as a copy.
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()

    private var onPick: ((URL) -> Void)?
    private var onCancel: (() -> Void)?

    /// Lets the user save a copy of `file` anywhere in Files. Returns false if nothing could be shown.
    @discardableResult
    func exportCopy(of file: URL, onDone: @escaping (URL) -> Void, onCancel: @escaping () -> Void) -> Bool {
        present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), onPick: onDone, onCancel: onCancel)
    }

    /// Lets the user pick a file; the app receives its own copy.
    @discardableResult
    func importCopy(of types: [UTType], onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) -> Bool {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        return present(picker, onPick: onPick, onCancel: onCancel)
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

    private func present(_ picker: UIDocumentPickerViewController, onPick: @escaping (URL) -> Void,
                         onCancel: @escaping () -> Void) -> Bool {
        guard let top = Self.topViewController() else { return false }
        self.onPick = onPick
        self.onCancel = onCancel
        picker.delegate = self
        top.present(picker, animated: true)
        return true
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
