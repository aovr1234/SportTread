import UIKit

/// Milestone 0: app data lives in a folder the user picks or creates (ideally in iCloud Drive),
/// outside the app's own container, so it survives deleting the app.
@MainActor
final class DataFolder: ObservableObject {
    @Published var folderName: String?
    @Published var message = "No folder chosen yet"

    private let bookmarkKey = "dataFolderBookmark"
    private let fileName = "settings.json"

    init() {
        restoreBookmark()
    }

    /// Called with the folder from the Files picker.
    func use(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            message = "Couldn't open that folder"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            folderName = url.lastPathComponent
            if let saved = try? read(from: url) {
                message = "Restored data saved \(saved.savedAt.formatted()) on \(saved.device)"
            } else {
                try write(to: url)
                message = "Folder set up. Test data saved."
            }
        } catch {
            message = "Failed: \(error.localizedDescription)"
        }
    }

    func saveNow() {
        guard let url = resolveBookmark() else {
            message = "Choose a folder first"
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            message = "Lost access to the folder. Choose it again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try write(to: url)
            message = "Saved \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    private func restoreBookmark() {
        guard let url = resolveBookmark() else { return }
        folderName = url.lastPathComponent
        message = "Using folder \(url.lastPathComponent)"
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    // Coordinated access so iCloud Drive downloads the file if it's only a placeholder.
    private func read(from folder: URL) throws -> TestData {
        let file = folder.appendingPathComponent(fileName)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        var result: Result<TestData, Error> = .failure(CocoaError(.fileReadNoSuchFile))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            result = Result { try JSONDecoder.iso.decode(TestData.self, from: Data(contentsOf: url)) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    private func write(to folder: URL) throws {
        let file = folder.appendingPathComponent(fileName)
        let data = try JSONEncoder.iso.encode(TestData(savedAt: Date(), device: UIDevice.current.name))
        var writeError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }
}

struct TestData: Codable {
    var savedAt: Date
    var device: String
    var app = "Andrew's SportTread"
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
