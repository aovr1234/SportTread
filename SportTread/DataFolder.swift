import UIKit

/// App data lives in a folder the app creates itself:
/// - iCloud Drive › SportTread when the signing allows the app's iCloud container (survives deleting the app)
/// - otherwise Files › On My iPhone › SportTread (removed with the app; use Back up to keep a copy)
/// Picking a folder with the Files picker doesn't work under Signulous signing: Open never returns.
@MainActor
final class DataFolder: ObservableObject {
    enum Location {
        case iCloud, onDevice
    }

    @Published var location: Location?
    @Published var folderDescription = "Setting up…"
    @Published var message = ""

    private let fileName = "settings.json"
    private(set) var folder: URL?

    init() {
        Task { await setUp() }
    }

    func setUp() async {
        // nil = the first iCloud container in the app's entitlements; must not run on the main thread
        let container = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: nil) }.value
        let folder: URL
        if let container {
            folder = container.appendingPathComponent("Documents", isDirectory: true)
            location = .iCloud
            folderDescription = "iCloud Drive › SportTread"
        } else {
            folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            location = .onDevice
            folderDescription = "On My iPhone › SportTread"
        }
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let saved = try? read(from: folder) {
                message = "Found data saved \(saved.savedAt.formatted()) on \(saved.device)"
            } else {
                try write(to: folder)
                message = "Created \(fileName)"
            }
        } catch {
            message = "Setup failed: \(error.localizedDescription)"
        }
    }

    func saveNow() {
        guard let folder else { return }
        do {
            try write(to: folder)
            message = "Saved \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Writes a copy of the current data to a temporary file for the Files export picker.
    func makeBackupFile() -> URL? {
        guard let folder else { return nil }
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("SportTread-backup.json")
        do {
            let data = try JSONEncoder.iso.encode(try read(from: folder))
            try data.write(to: backup, options: .atomic)
            return backup
        } catch {
            message = "Couldn't prepare the backup: \(error.localizedDescription)"
            return nil
        }
    }

    /// Restores from a backup file the import picker copied into the app.
    func restore(from file: URL) {
        guard let folder else { return }
        do {
            let saved = try JSONDecoder.iso.decode(TestData.self, from: Data(contentsOf: file))
            try coordinatedWrite(JSONEncoder.iso.encode(saved), to: folder.appendingPathComponent(fileName))
            message = "Restored backup saved \(saved.savedAt.formatted()) on \(saved.device)"
        } catch {
            message = "That file isn't a SportTread backup: \(error.localizedDescription)"
        }
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
        let data = try JSONEncoder.iso.encode(TestData(savedAt: Date(), device: UIDevice.current.name))
        try coordinatedWrite(data, to: folder.appendingPathComponent(fileName))
    }

    private func coordinatedWrite(_ data: Data, to file: URL) throws {
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
