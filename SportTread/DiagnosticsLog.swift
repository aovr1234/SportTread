import Foundation
import MetricKit

/// Writes one line per event (connects, commands, refusals, workout steps, launches, and iOS's own reports of
/// why it closed the app) to `diagnostics.log` in the app's Documents folder (visible in Files › SportTread),
/// keeping the last ~2,000 lines. Setup shows the latest lines and can share the file. Nothing is sent anywhere.
final class DiagnosticsLog: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsLog()

    @Published private(set) var recent: [String] = []
    let fileURL: URL

    private static let maxLines = 2000
    private let queue = DispatchQueue(label: "SportTread.diagnostics")
    private let stamp: DateFormatter
    private var lineCount = 0

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("diagnostics.log")
        stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm:ss"
        super.init()
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if lines.count > Self.maxLines {
                lines = Array(lines.suffix(Self.maxLines))
                try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            }
            lineCount = lines.count
            recent = Array(lines.suffix(40))
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// Call once at launch: records how the app started and asks iOS for its termination reports.
    func start(launch: String) {
        add("=== App launched (\(launch)) ===")
        MXMetricManager.shared.add(self)
    }

    func add(_ text: String) {
        let now = Date()
        queue.async { [self] in
            let line = stamp.string(from: now) + "  " + text
            write(line)
            DispatchQueue.main.async {
                self.recent.append(line)
                if self.recent.count > 40 { self.recent.removeFirst(self.recent.count - 40) }
            }
        }
    }

    func clear() {
        queue.async { [self] in
            try? Data().write(to: fileURL)
            lineCount = 0
            DispatchQueue.main.async { self.recent = [] }
        }
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
        lineCount += 1
        if lineCount > Self.maxLines + 500,
           let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(Self.maxLines))
            try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            lineCount = lines.count
        }
    }

    // MARK: iOS reports (MetricKit): delivered about once a day, for the previous day

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let background = exits.backgroundExitData
            add("iOS report, exits in the background: normal \(background.cumulativeNormalAppExitCount), "
                + "memory limit \(background.cumulativeMemoryResourceLimitExitCount), "
                + "memory pressure \(background.cumulativeMemoryPressureExitCount), "
                + "watchdog \(background.cumulativeAppWatchdogExitCount), "
                + "abnormal \(background.cumulativeAbnormalExitCount)")
            let foreground = exits.foregroundExitData
            add("iOS report, exits in the foreground: normal \(foreground.cumulativeNormalAppExitCount), "
                + "memory limit \(foreground.cumulativeMemoryResourceLimitExitCount), "
                + "watchdog \(foreground.cumulativeAppWatchdogExitCount), "
                + "abnormal \(foreground.cumulativeAbnormalExitCount)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                add("iOS crash report: \(crash.terminationReason ?? "no reason given"), signal \(crash.signal?.intValue ?? 0)")
            }
        }
    }
}

/// Adds a line to the diagnostics log.
func dlog(_ text: String) {
    DiagnosticsLog.shared.add(text)
}
