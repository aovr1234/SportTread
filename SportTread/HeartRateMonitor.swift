import CoreBluetooth
import HealthKit

/// Optional heart-rate add-on. The app works without it; heart-rate workouts need a source.
enum HeartRateSource: String, CaseIterable, Identifiable {
    case off, health, bluetooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .health: "Apple Watch (via Health)"
        case .bluetooth: "Bluetooth monitor"
        }
    }
}

/// Reads heart rate from the chosen source:
/// - health: new samples Apple Health receives, e.g. from Apple's Workout app on the watch (arrive with some delay)
/// - bluetooth: any standard BLE heart-rate monitor (Heart Rate service 0x180D), about once a second
@MainActor
final class HeartRateMonitor: NSObject, ObservableObject {
    @Published var source: HeartRateSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            restart()
        }
    }
    @Published var bpm: Double?
    /// When the reading was measured (Health: sample end; Bluetooth: arrival)
    @Published var measuredAt: Date?
    @Published var status = "Off"
    @Published var deviceName: String?

    private static let sourceKey = "heartRateSource"
    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")

    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    override init() {
        source = HeartRateSource(rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "") ?? .off
        super.init()
        restart()
    }

    func restart() {
        stopAll()
        bpm = nil
        measuredAt = nil
        switch source {
        case .off:
            status = "Off"
        case .health:
            startHealth()
        case .bluetooth:
            status = "Turning on Bluetooth…"
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    private func stopAll() {
        if let query { store.stop(query) }
        query = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        central = nil
        peripheral = nil
        deviceName = nil
    }

    // MARK: Apple Health

    private func startHealth() {
        status = "Waiting for heart rate in Apple Health…"
        let recent = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-600), end: nil)
        let query = HKAnchoredObjectQuery(type: HKQuantityType(.heartRate), predicate: recent, anchor: nil,
                                          limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, error in
            self?.receive(samples, error)
        }
        query.updateHandler = { [weak self] _, samples, _, _, error in
            self?.receive(samples, error)
        }
        self.query = query
        store.execute(query)
    }

    nonisolated private func receive(_ samples: [HKSample]?, _ error: Error?) {
        let latest = (samples as? [HKQuantitySample])?.max { $0.endDate < $1.endDate }
        let bpm = latest?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let end = latest?.endDate
        let from = latest?.sourceRevision.source.name
        let message = error?.localizedDescription
        Task { @MainActor in
            guard self.source == .health else { return }
            if let message {
                self.status = "Health error: \(message)"
                return
            }
            guard let bpm, let end else { return }
            if let shown = self.measuredAt, end <= shown { return }
            self.bpm = bpm
            self.measuredAt = end
            self.status = "From \(from ?? "Apple Health")"
        }
    }

    // MARK: Bluetooth

    private func handleState(_ manager: CBCentralManager) {
        guard manager === central else { return }
        switch manager.state {
        case .poweredOn:
            status = "Searching for a heart-rate monitor…"
            manager.scanForPeripherals(withServices: [Self.hrService])
        case .unauthorized:
            status = "Bluetooth isn't allowed. Turn it on in Settings › SportTread."
        case .poweredOff:
            status = "Bluetooth is off"
        default:
            status = "Bluetooth isn't available"
        }
    }

    private func rescan() {
        guard let central, central.state == .poweredOn, source == .bluetooth else { return }
        peripheral = nil
        status = "Lost the monitor. Searching again…"
        central.scanForPeripherals(withServices: [Self.hrService])
    }

    /// Heart Rate Measurement: flags byte, then bpm as UInt8, or UInt16 if bit 0 of the flags is set.
    private func handleMeasurement(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let value = bytes[0] & 0x01 == 0 || bytes.count < 3
            ? Int(bytes[1])
            : Int(bytes[1]) | Int(bytes[2]) << 8
        guard value > 0 else { return }
        bpm = Double(value)
        measuredAt = Date()
        status = "Connected to \(deviceName ?? "monitor")"
    }
}

// CoreBluetooth calls these on the main queue (queue: nil), so hopping onto the main actor is safe.
extension HeartRateMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleState(central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            deviceName = peripheral.name ?? "heart-rate monitor"
            status = "Connecting to \(deviceName!)…"
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            peripheral.discoverServices([Self.hrService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { rescan() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { rescan() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] where service.uuid == Self.hrService {
                peripheral.discoverCharacteristics([Self.hrMeasurement], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.hrMeasurement {
                peripheral.setNotifyValue(true, for: characteristic)
                status = "Connected to \(deviceName ?? "monitor"), waiting for a reading…"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let data = characteristic.value { handleMeasurement(data) }
        }
    }
}
