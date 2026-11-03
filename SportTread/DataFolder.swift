import UIKit

/// App data lives in a folder outside the app's own container (ideally in iCloud Drive), so it
/// survives deleting the app. The user picks a location; the app keeps its data in a `SportTread`
/// folder there, or in the picked folder itself if that already holds SportTread data.
@MainActor
final class DataFolder: ObservableObject {
    static let appFolderName = "SportTread"

    @Published var folderName: String?
    @Published var message = "No folder chosen yet"

    private let bookmarkKey = "dataFolderBookmark"      // the folder the user picked
    private let subfolderKey = "dataFolderSubfolder"    // "" or "SportTread" inside it
    private let fileName = "settings.json"

    init() {
        if let (picked, sub) = resolveBookmark() {
            folderName = label(picked, sub)
            message = "Using \(label(picked, sub))"
        }
    }

    /// Called with the folder chosen in the Files picker.
    func use(_ picked: URL) {
        message = "Opening \(picked.lastPathComponent)…"
        guard picked.startAccessingSecurityScopedResource() else {
            message = "iOS didn't give access to “\(picked.lastPathComponent)”. Pick it again."
            return
        }
        defer { picked.stopAccessingSecurityScopedResource() }
        do {
            let reuse = picked.lastPathComponent == Self.appFolderName || hasData(in: picked)
            let sub = reuse ? "" : Self.appFolderName
            let folder = sub.isEmpty ? picked : picked.appendingPathComponent(sub, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let bookmark = try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(sub, forKey: subfolderKey)
            folderName = label(picked, sub)

            if let saved = try? read(from: folder) {
                message = "Restored data saved \(saved.savedAt.formatted()) on \(saved.device)"
            } else {
                try write(to: folder)
                message = "Set up \(label(picked, sub)). Test data saved."
            }
        } catch {
            message = "Couldn't set up the folder: \(error.localizedDescription)"
        }
    }

    func saveNow() {
        guard let (picked, sub) = resolveBookmark() else {
            message = "Choose a folder first"
            return
        }
        guard picked.startAccessingSecurityScopedResource() else {
            message = "Lost access to the folder. Choose it again."
            return
        }
        defer { picked.stopAccessingSecurityScopedResource() }
        do {
            try write(to: sub.isEmpty ? picked : picked.appendingPathComponent(sub, isDirectory: true))
            message = "Saved \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    private func label(_ picked: URL, _ sub: String) -> String {
        sub.isEmpty ? picked.lastPathComponent : "\(picked.lastPathComponent)/\(sub)"
    }

    /// True if the folder holds SportTread data, including an iCloud placeholder not downloaded yet.
    private func hasData(in folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(fileName).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(".\(fileName).icloud").path)
    }

    private func resolveBookmark() -> (URL, String)? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return (url, UserDefaults.standard.string(forKey: subfolderKey) ?? "")
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
