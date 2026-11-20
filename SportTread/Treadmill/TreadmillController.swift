import CoreBluetooth
import Foundation
import UIKit

/// Connects to the treadmill, runs the handshake, polls status continuously and sends commands
/// between poll messages (a 3-frame poll must never be split, or the console rejects and disconnects).
///
/// Reliability: runs in the background (bluetooth-central), reconnects by itself after an unexpected
/// drop, resets a connection that goes silent for 10 s, and restores the connection if iOS relaunches
/// the app in the background. Only Disconnect (or a fatal error) ends the connection for good.
@MainActor
final class TreadmillController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case unavailable(String)
        case scanning
        case connecting
        case handshaking
        case ready
        case reconnecting
        case disconnected
    }

    static let minMph = TreadmillLimits.minMph
    static let maxMph = TreadmillLimits.maxMph
    static let maxIncline = TreadmillLimits.maxIncline

    @Published private(set) var state: State = .idle
    @Published private(set) var speedMph: Double?
    @Published private(set) var incline: Double?
    @Published private(set) var movingSeconds: TimeInterval = 0
    @Published private(set) var miles: Double = 0
    @Published private(set) var lastEvent = ""
    /// Set when a speed or incline command still didn't take after resending; shown on the workout screen
    @Published private(set) var commandProblem: String?

    var isReady: Bool { state == .ready }
    var isRunning: Bool { (speedMph ?? 0) > 0 }

    /// A manual (treadmill-mode) session is open: the belt has run since the last End workout.
    @Published private(set) var sessionActive = false
    /// Summary of the last ended treadmill-mode session, shown on the Treadmill tab
    @Published private(set) var lastSessionSummary: String?
    /// The history entry of the last ended treadmill-mode session (with its full summary); the Treadmill tab shows it
    @Published var lastSessionEntry: HistoryEntry?
    private var sessionLog = SampleLog()
    /// No treadmill-mode session (and Live Activity) opens before this time
    private var manualBlockedUntil = Date.distantPast

    /// Set by the workout runner while a workout runs; treadmill-mode tracking pauses meanwhile.
    var workoutActive = false {
        didSet {
            // The belt still reads moving for a second or two after a workout ends; that must not open a session
            if !workoutActive { manualBlockedUntil = Date().addingTimeInterval(15) }
            guard workoutActive, sessionActive else { return }
            manualActivity.end()
            sessionActive = false
        }
    }

    /// The latest heart-rate reading (set by the app); read when the session samples are taken.
    var heartRateProvider: (() -> (bpm: Int, at: Date)?)?

    /// Called when a treadmill-mode session ends, for history.
    var onSessionEnd: ((HistoryEntry) -> Void)?

    private struct Job {
        let label: String
        let frames: [Data]
        let notBefore: Date
    }

    private let service = CBUUID(string: TreadmillProtocol.serviceUUID)
    private let txID = CBUUID(string: TreadmillProtocol.txUUID)
    private let rxID = CBUUID(string: TreadmillProtocol.rxUUID)

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var session: Task<Void, Never>?
    private var queue: [Job] = []
    /// Speed and incline commands: pacing, checking and resending (see CommandPacer)
    private var pacer = CommandPacer()
    private var pendingWrite: CheckedContinuation<Void, Never>?
    private var pendingWriteID = 0
    private var lastStatusAt: Date?
    // Polling shared by the loop and by keepAlive(): the next poll frame, when anything was last sent, signal and counters
    private var pollIndex = 0
    private var lastSendAt = Date.distantPast
    private var resumeGrace = Date.distantPast
    private var lastRSSI: Int?
    private var lastRSSIRead = Date.distantPast
    private var pumpCount = 0
    private var lastPumpLog = Date.distantPast
    // Targets of recent commands, so repeated taps build on the target, not a stale reading
    private var targetMph: (value: Double, at: Date)?
    private var targetIncline: (value: Double, at: Date)?
    private var readySince: Date?
    private let manualActivity = TreadmillActivity()
    private var stoppedSince: Date?
    private var sessionMaxMph = 0.0
    private var sessionMaxIncline = 0.0
    private static let activityStopLimit: TimeInterval = 120  // treadmill-mode Live Activity ends 2 min after stopping

    private static let restoreID = "SportTreadTreadmill"
    /// Set while connected, so a background relaunch by iOS restores the connection.
    private static let wasConnectedKey = "treadmillWasConnected"
    private static let silenceLimit: TimeInterval = 10

    override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.wasConnectedKey) {
            makeCentral()  // lets iOS hand back a connection it kept while the app was closed
        }
    }

    // MARK: Connection

    func connect() {
        lastEvent = ""
        dlog("Connect requested")
        UserDefaults.standard.set(true, forKey: Self.wasConnectedKey)
        if let central, central.state == .poweredOn {
            if let peripheral { reconnect(peripheral, reason: nil) } else { scan() }
        } else if central == nil {
            makeCentral()  // scans once powered on
        }
    }

    private func makeCentral() {
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    func disconnect() {
        dlog("Disconnect requested")
        UserDefaults.standard.set(false, forKey: Self.wasConnectedKey)
        guard isRunning else {
            teardown(reason: "Disconnected")
            return
        }
        stop()
        Task {
            try? await Task.sleep(for: .seconds(2))  // let the stop command go out first
            teardown(reason: "Stopped and disconnected")
        }
    }

    private func scan() {
        guard let central else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [service])
    }

    /// Ends the connection for good (Disconnect or a fatal error); no automatic reconnect.
    private func teardown(reason: String) {
        UserDefaults.standard.set(false, forKey: Self.wasConnectedKey)
        if sessionActive { closeManualSession(summary: "Disconnected") }
        resetSession()
        let old = peripheral
        peripheral = nil  // marks the coming disconnect callback as intentional
        if let old { central?.cancelPeripheralConnection(old) }
        central?.stopScan()
        state = .disconnected
        lastEvent = reason
        dlog("Disconnected for good: \(reason)")
    }

    /// Drops the current session and keeps trying to reconnect to the same treadmill.
    /// iOS keeps a pending connect alive until the treadmill is back in range.
    private func reconnect(_ peripheral: CBPeripheral, reason: String?) {
        resetSession()
        state = .reconnecting
        if let reason { lastEvent = reason }
        dlog("Reconnecting: \(reason ?? "link dropped")")
        central?.connect(peripheral)
    }

    private func resetSession() {
        session?.cancel()
        session = nil
        finishWrite(id: pendingWriteID)
        clearCommands()
        tx = nil
        speedMph = nil
        incline = nil
        lastStatusAt = nil
        readySince = nil
    }

    // MARK: Commands

    /// Drops everything waiting to be sent, and stops checking earlier commands.
    private func clearCommands() {
        queue.removeAll()
        pacer.clear()
    }

    /// Starts the belt (the console starts at 1.0 mph). `resetStats: false` keeps time and distance
    /// (resuming a workout); `setSpeed: false` skips the extra "speed 1.0" command, which a resumed
    /// workout doesn't need because it sets its own speed next.
    func start(resetStats: Bool = true, setSpeed: Bool = true) {
        guard isReady else { return }
        if resetStats { self.resetStats() }
        clearCommands()
        commandProblem = nil
        pacer.markStart(Date())
        targetMph = (1.0, Date())
        enqueue("Start", TreadmillProtocol.startFrames)
        if setSpeed {
            enqueue("Speed 1.0 mph", TreadmillProtocol.speedFrames(mph: 1.0), after: 1.5)
        }
    }

    /// Treadmill mode: stops the belt, then lowers the incline to 0% two seconds later, saves the
    /// session and shows a summary.
    func endWorkout() {
        zeroInclineAndStop()
        if sessionActive { closeManualSession(summary: "Session ended") }
    }

    /// Stops the belt, waits 2 seconds, then sends incline 0%. Used whenever a workout or session
    /// ends; STOP alone leaves the incline as it is. (Tested on the treadmill: the incline motor lowers the
    /// deck after the belt has stopped, but not if Stop arrives right after the incline command.)
    func zeroInclineAndStop() {
        guard isReady else { return }
        clearCommands()
        commandProblem = nil
        manualBlockedUntil = Date().addingTimeInterval(15)
        targetMph = nil
        targetIncline = (0, Date().addingTimeInterval(2))
        enqueue("Stop", TreadmillProtocol.stopFrames)
        enqueue("Incline 0%", TreadmillProtocol.inclineFrames(percent: 0), after: 2)
    }

    /// Stops the belt; drops anything still queued.
    func stop() {
        guard isReady else { return }
        clearCommands()
        targetMph = nil
        enqueue("Stop", TreadmillProtocol.stopFrames)
    }

    func setSpeed(_ mph: Double) {
        let value = (mph * 10).rounded() / 10
        guard (Self.minMph...Self.maxMph).contains(value) else {
            lastEvent = "Speed must be \(Self.minMph)–\(Self.maxMph) mph"
            return
        }
        guard isRunning else {
            lastEvent = "Press Start first"
            return
        }
        targetMph = (value, Date())
        commandProblem = nil
        pacer.requestSpeed(value)  // sent at the next poll gap, at most once a second; a newer tap replaces it
    }

    /// The speed the belt is set to (the last command if it is recent, else the reading).
    var targetSpeedNow: Double { current(targetMph, reading: speedMph) }

    func changeSpeed(by delta: Double) {
        setSpeed(current(targetMph, reading: speedMph) + delta)
    }

    func setIncline(_ percent: Double) {
        let value = (percent * 2).rounded() / 2
        guard (0...Self.maxIncline).contains(value) else {
            lastEvent = "Incline must be 0–\(Int(Self.maxIncline))%"
            return
        }
        targetIncline = (value, Date())
        commandProblem = nil
        pacer.requestIncline(value)
    }

    func changeIncline(by delta: Double) {
        setIncline(current(targetIncline, reading: incline) + delta)
    }

    private func current(_ target: (value: Double, at: Date)?, reading: Double?) -> Double {
        if let target, Date().timeIntervalSince(target.at) < 4 { return target.value }
        return reading ?? 0
    }

    private func enqueue(_ label: String, _ frames: [Data], after delay: TimeInterval = 0) {
        queue.append(Job(label: label, frames: frames, notBefore: Date().addingTimeInterval(delay)))
    }

    /// After the app was relaunched in the middle of a workout: puts the workout's distance and time back.
    func restoreStats(miles: Double, movingSeconds: TimeInterval) {
        self.miles = miles
        self.movingSeconds = movingSeconds
    }

    func resetStats() {
        movingSeconds = 0
        miles = 0
        sessionLog.reset()
        sessionMaxMph = 0
        sessionMaxIncline = 0
    }

    // MARK: Treadmill-mode session

    private func manualState(now: Date, stopped: Bool, summary: String? = nil) -> TreadmillActivity.State {
        TreadmillActivity.State(
            mph: speedMph ?? 0, incline: incline ?? 0, miles: miles,
            runningSince: now.addingTimeInterval(-movingSeconds),
            movingSeconds: Int(movingSeconds), stopped: stopped, summary: summary)
    }

    private func updateManualSession(now: Date) {
        guard !workoutActive, now >= manualBlockedUntil else { return }
        if isRunning {
            stoppedSince = nil
            if !sessionActive {
                sessionActive = true
                lastSessionSummary = nil
                resetStats()
            }
            sessionMaxMph = max(sessionMaxMph, speedMph ?? 0)
            sessionMaxIncline = max(sessionMaxIncline, incline ?? 0)
            sessionLog.add(elapsed: movingSeconds, mph: speedMph ?? 0, incline: incline ?? 0, bpm: heartRateProvider?()?.bpm)
            if manualActivity.isActive {
                manualActivity.update(manualState(now: now, stopped: false))
            } else {
                manualActivity.start(manualState(now: now, stopped: false))
            }
        } else if sessionActive, manualActivity.isActive {
            let since = stoppedSince ?? now
            stoppedSince = since
            if now.timeIntervalSince(since) >= Self.activityStopLimit {
                manualActivity.end(final: manualState(now: now, stopped: true, summary: "Stopped"))
            } else {
                manualActivity.update(manualState(now: now, stopped: true))
            }
        }
    }

    private func closeManualSession(summary: String) {
        let now = Date()
        manualActivity.end(final: manualState(now: now, stopped: true, summary: summary))
        sessionActive = false
        stoppedSince = nil
        let s = Int(movingSeconds)
        lastSessionSummary = String(format: "%d:%02d · %.2f mi · top %.1f mph", s / 60, s % 60, miles, sessionMaxMph)
        if movingSeconds >= 30 {
            let summary = WorkoutSummary.make(samples: sessionLog.samples, miles: miles, movingSeconds: s,
                                              weightLb: WorkoutSummary.storedWeightLb,
                                              zones: BodyProfile.stored.zones)
            let entry = HistoryEntry(
                date: now, name: "Treadmill session", plannedSeconds: 0, seconds: s, miles: miles,
                maxMph: sessionMaxMph, maxIncline: sessionMaxIncline, completed: true, summary: summary)
            onSessionEnd?(entry)
            lastSessionEntry = entry
        }
    }

    // MARK: Session loop

    private func runSession() {
        session?.cancel()
        state = .handshaking
        pollIndex = 0
        session = Task {
            for frame in TreadmillProtocol.initFrames {
                if Task.isCancelled { return }
                await write(frame)
                try? await Task.sleep(for: .milliseconds(600))
            }
            if Task.isCancelled { return }
            state = .ready
            readySince = Date()
            lastEvent = "Connected"
            dlog("Connected, handshake done")
            var lastLoopAt = Date()
            while !Task.isCancelled {
                // A long gap between two turns of this loop means the app was suspended: don't blame the treadmill for that
                let turn = Date()
                if turn.timeIntervalSince(lastLoopAt) > 3 { resumeGrace = turn }
                lastLoopAt = turn
                // Watchdog: a link that looks connected but sends nothing gets reset
                let heardFrom = max(lastStatusAt ?? readySince ?? Date(), resumeGrace)
                if Date().timeIntervalSince(heardFrom) > Self.silenceLimit, let peripheral {
                    dlog("Watchdog: no status for 10 s")
                    reconnect(peripheral, reason: "No data from the treadmill for 10 s. Reconnecting…")
                    central?.cancelPeripheralConnection(peripheral)
                    return
                }
                // One command per poll message: a command goes out only between two poll messages, and
                // is followed by a full poll message, so quick taps can never starve the status polling.
                if pollIndex % 3 == 0, let job = takeNextJob(now: Date()) {
                    lastEvent = job.label
                    dlog("Sent: \(job.label)")
                    for frame in job.frames {
                        lastSendAt = Date()
                        await write(frame)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                let frame = TreadmillProtocol.pollFrames[pollIndex % TreadmillProtocol.pollFrames.count]
                pollIndex += 1
                lastSendAt = Date()
                await write(frame)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Called on every Bluetooth wake-up: the treadmill's own messages and the heart-rate sensor's readings. While the
    /// app is suspended the polling loop above doesn't run, and the console drops a link nobody polls, so the polling
    /// goes on from here (two poll messages per wake-up, in the same order as the loop, never splitting one).
    func keepAlive() {
        guard state == .ready, let peripheral, let tx else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSendAt) > 0.8 else { return }
        var frames = 0
        while frames < 6 || pollIndex % 3 != 0 {
            if pollIndex % 3 == 0, let job = takeNextJob(now: now) {
                lastEvent = job.label
                dlog("Sent (from a background wake-up): \(job.label)")
                for frame in job.frames { peripheral.writeValue(frame, for: tx, type: .withResponse) }
            }
            peripheral.writeValue(TreadmillProtocol.pollFrames[pollIndex % TreadmillProtocol.pollFrames.count], for: tx, type: .withResponse)
            pollIndex += 1
            frames += 1
        }
        lastSendAt = now
        pumpCount += 1
        if now.timeIntervalSince(lastPumpLog) > 60 {
            lastPumpLog = now
            dlog("Background polling: the link was kept alive \(pumpCount) times so far")
        }
    }

    /// The next command to send: a queued job that is due (Stop and Start first, even if an earlier job
    /// isn't due yet), then the latest speed, then the latest incline (see CommandPacer).
    private func takeNextJob(now: Date) -> Job? {
        if let i = queue.firstIndex(where: { now >= $0.notBefore }) {
            return queue.remove(at: i)
        }
        switch pacer.next(now: now, speedReading: speedMph, inclineReading: incline) {
        case .speed(let mph)?:
            return Job(label: String(format: "Speed %.1f mph", mph), frames: TreadmillProtocol.speedFrames(mph: mph), notBefore: now)
        case .incline(let percent)?:
            return Job(label: String(format: "Incline %.1f%%", percent), frames: TreadmillProtocol.inclineFrames(percent: percent), notBefore: now)
        case nil:
            return nil
        }
    }

    private func report(_ problem: String?) {
        guard let problem else { return }
        commandProblem = problem
        lastEvent = problem
        dlog("Gave up: \(problem)")
    }

    /// Write with response; continues on the console's acknowledgement or after 1 s.
    private func write(_ frame: Data) async {
        guard let peripheral, let tx else { return }
        pendingWriteID += 1
        let id = pendingWriteID
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingWrite = continuation
            peripheral.writeValue(frame, for: tx, type: .withResponse)
            Task {
                try? await Task.sleep(for: .seconds(1))
                finishWrite(id: id)
            }
        }
    }

    private func finishWrite(id: Int) {
        guard id == pendingWriteID, let continuation = pendingWrite else { return }
        pendingWrite = nil
        continuation.resume()
    }

    // MARK: Incoming data

    private func handle(_ data: Data) {
        guard state == .ready else { return }  // handshake replies aren't status frames
        keepAlive()
        if Date().timeIntervalSince(lastRSSIRead) > 10, let peripheral {
            lastRSSIRead = Date()
            peripheral.readRSSI()
        }
        if let code = TreadmillProtocol.refusal(from: data) {
            lastEvent = "Treadmill refused a command (status \(String(format: "%02x", code)))"
            dlog(lastEvent)
            // A refusal right after a speed or incline command: send that command again
            report(pacer.refused(now: Date()))
            return
        }
        guard let status = TreadmillProtocol.status(from: data) else { return }
        let now = Date()
        let mph = status.speedKmh / TreadmillProtocol.kmhPerMph

        if let last = lastStatusAt, let previous = speedMph, previous > 0 {
            let seconds = now.timeIntervalSince(last)
            movingSeconds += seconds
            miles += previous * seconds / 3600
        }
        // A change nobody commanded from the app in the last 4 s came from the console
        if let previous = speedMph, abs(mph - previous) >= 0.05, targetMph.map({ now.timeIntervalSince($0.at) > 4 }) ?? true {
            lastEvent = mph == 0 ? "Stopped on the console" : String(format: "Speed changed on the console: %.1f mph", mph)
        }
        if let previous = incline, abs(status.incline - previous) >= 0.05,
           targetIncline.map({ now.timeIntervalSince($0.at) > 4 }) ?? true {
            lastEvent = String(format: "Incline changed on the console: %.1f%%", status.incline)
        }

        if ((speedMph ?? 0) > 0) != (mph > 0) {
            dlog(mph > 0 ? String(format: "Belt running at %.1f mph", mph) : "Belt stopped")
        }
        lastStatusAt = now
        speedMph = mph
        incline = status.incline
        report(pacer.verify(now: now, speedReading: mph, inclineReading: status.incline))
        updateManualSession(now: now)
    }
}

// CoreBluetooth calls these on the main queue (queue: nil), so assuming main-actor isolation is safe.
extension TreadmillController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if let peripheral {
                    // Restored or waiting connection: continue it
                    if peripheral.state == .connected {
                        state = .connecting
                        peripheral.delegate = self
                        peripheral.discoverServices([service])
                    } else {
                        reconnect(peripheral, reason: nil)
                    }
                } else if UserDefaults.standard.bool(forKey: Self.wasConnectedKey) {
                    scan()
                }
            case .unauthorized:
                state = .unavailable("Allow Bluetooth for SportTread in Settings")
            case .poweredOff:
                state = .unavailable("Bluetooth is off")
            default:
                state = .unavailable("Bluetooth isn't available")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
            else { return }
            peripheral = restored
            restored.delegate = self
            lastEvent = "Reconnecting after iOS restarted the app…"
            dlog("iOS restored the Bluetooth connection: the app was relaunched")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            peripheral.discoverServices([service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral else { return }
            if state == .reconnecting {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if state == .reconnecting, let current = self.peripheral { central.connect(current) }
                }
            } else {
                teardown(reason: "Couldn't connect. Is another app connected to the treadmill?")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral else { return }  // we disconnected on purpose
            if state == .reconnecting {
                central.connect(peripheral)  // watchdog reset: try again right away
            } else {
                let quiet = lastStatusAt.map { String(format: "%.0f s since the last status", Date().timeIntervalSince($0)) } ?? "no status yet"
                let appState: String
                switch UIApplication.shared.applicationState {
                case .active: appState = "in front"
                case .inactive: appState = "inactive"
                case .background: appState = "in the background"
                @unknown default: appState = "unknown"
                }
                dlog("Bluetooth connection lost: \(error?.localizedDescription ?? "no error given") (\(quiet), app \(appState), "
                     + "signal \(lastRSSI.map { "\($0) dBm" } ?? "unknown"), memory \(DiagnosticsLog.memoryMB().map { String(format: "%.0f MB", $0) } ?? "unknown"), "
                     + "\(pumpCount) background polls)")
                reconnect(peripheral, reason: "Connection lost. Reconnecting… (console Stop always works)")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == service }) else {
                teardown(reason: "This device isn't the treadmill")
                return
            }
            peripheral.discoverCharacteristics([txID, rxID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            guard let tx = chars.first(where: { $0.uuid == txID }), let rx = chars.first(where: { $0.uuid == rxID }) else {
                teardown(reason: "The treadmill's control channel is missing")
                return
            }
            self.tx = tx
            peripheral.setNotifyValue(true, for: rx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if characteristic.uuid == rxID, characteristic.isNotifying, session == nil {
                runSession()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated { lastRSSI = RSSI.intValue }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { finishWrite(id: pendingWriteID) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if characteristic.uuid == rxID, let data = characteristic.value { handle(data) }
        }
    }
}
