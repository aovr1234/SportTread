import CoreBluetooth
import Foundation

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

    static let minMph = 0.5
    static let maxMph = 10.0
    static let maxIncline = 10.0

    @Published private(set) var state: State = .idle
    @Published private(set) var speedMph: Double?
    @Published private(set) var incline: Double?
    @Published private(set) var movingSeconds: TimeInterval = 0
    @Published private(set) var miles: Double = 0
    @Published private(set) var lastEvent = ""

    var isReady: Bool { state == .ready }
    var isRunning: Bool { (speedMph ?? 0) > 0 }

    /// A manual (treadmill-mode) session is open: the belt has run since the last End workout.
    @Published private(set) var sessionActive = false
    /// Summary of the last ended treadmill-mode session, shown on the Treadmill tab
    @Published private(set) var lastSessionSummary: String?

    /// Set by the workout runner while a workout runs; treadmill-mode tracking pauses meanwhile.
    var workoutActive = false {
        didSet {
            guard workoutActive, sessionActive else { return }
            manualActivity.end()
            sessionActive = false
        }
    }

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
    private var pendingWrite: CheckedContinuation<Void, Never>?
    private var pendingWriteID = 0
    private var lastStatusAt: Date?
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
    }

    /// Drops the current session and keeps trying to reconnect to the same treadmill.
    /// iOS keeps a pending connect alive until the treadmill is back in range.
    private func reconnect(_ peripheral: CBPeripheral, reason: String?) {
        resetSession()
        state = .reconnecting
        if let reason { lastEvent = reason }
        central?.connect(peripheral)
    }

    private func resetSession() {
        session?.cancel()
        session = nil
        finishWrite(id: pendingWriteID)
        queue.removeAll()
        tx = nil
        speedMph = nil
        incline = nil
        lastStatusAt = nil
        readySince = nil
    }

    // MARK: Commands

    /// Starts the belt at 1.0 mph. `resetStats: false` keeps time and distance (resuming a workout).
    func start(resetStats: Bool = true) {
        guard isReady else { return }
        if resetStats { self.resetStats() }
        targetMph = (1.0, Date())
        enqueue("Start", TreadmillProtocol.startFrames)
        enqueue("Speed 1.0 mph", TreadmillProtocol.speedFrames(mph: 1.0), after: 1.5)
    }

    /// Treadmill mode: lowers the incline to 0%, stops the belt, saves the session and shows a summary.
    /// (Incline goes first: it's sent while the belt still runs, so it doesn't depend on the console
    /// accepting incline changes once stopped.)
    func endWorkout() {
        zeroInclineAndStop()
        if sessionActive { closeManualSession(summary: "Session ended") }
    }

    /// Lowers the incline to 0% and stops the belt (incline first, while the belt still runs).
    /// Used whenever a workout or session ends; STOP alone leaves the incline as it is.
    func zeroInclineAndStop() {
        guard isReady else { return }
        queue.removeAll()
        targetMph = nil
        targetIncline = (0, Date())
        enqueue("Incline 0%", TreadmillProtocol.inclineFrames(percent: 0))
        enqueue("Stop", TreadmillProtocol.stopFrames)
    }

    /// Stops the belt; drops anything still queued.
    func stop() {
        guard isReady else { return }
        queue.removeAll()
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
        enqueue(String(format: "Speed %.1f mph", value), TreadmillProtocol.speedFrames(mph: value))
    }

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
        enqueue(String(format: "Incline %.1f%%", value), TreadmillProtocol.inclineFrames(percent: value))
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

    func resetStats() {
        movingSeconds = 0
        miles = 0
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
        guard !workoutActive else { return }
        if isRunning {
            stoppedSince = nil
            if !sessionActive {
                sessionActive = true
                lastSessionSummary = nil
                resetStats()
            }
            sessionMaxMph = max(sessionMaxMph, speedMph ?? 0)
            sessionMaxIncline = max(sessionMaxIncline, incline ?? 0)
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
            onSessionEnd?(HistoryEntry(
                date: now, name: "Treadmill session", plannedSeconds: 0, seconds: s, miles: miles,
                maxMph: sessionMaxMph, maxIncline: sessionMaxIncline, completed: true))
        }
    }

    // MARK: Session loop

    private func runSession() {
        session?.cancel()
        state = .handshaking
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
            var index = 0
            while !Task.isCancelled {
                // Watchdog: a link that looks connected but sends nothing gets reset
                let heardFrom = lastStatusAt ?? readySince ?? Date()
                if Date().timeIntervalSince(heardFrom) > Self.silenceLimit, let peripheral {
                    reconnect(peripheral, reason: "No data from the treadmill for 10 s. Reconnecting…")
                    central?.cancelPeripheralConnection(peripheral)
                    return
                }
                if index % 3 == 0, let job = queue.first, Date() >= job.notBefore {
                    queue.removeFirst()
                    lastEvent = job.label
                    for frame in job.frames {
                        await write(frame)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    continue
                }
                await write(TreadmillProtocol.pollFrames[index % TreadmillProtocol.pollFrames.count])
                index += 1
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
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
        if let code = TreadmillProtocol.refusal(from: data) {
            lastEvent = "Treadmill refused a command (status \(String(format: "%02x", code)))"
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

        lastStatusAt = now
        speedMph = mph
        incline = status.incline
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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { finishWrite(id: pendingWriteID) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if characteristic.uuid == rxID, let data = characteristic.value { handle(data) }
        }
    }
}
