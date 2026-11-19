import CoreBluetooth
import Foundation

/// Finds and keeps a connection to a standard Bluetooth heart-rate sensor (a chest strap, an armband such as
/// the Coospo HW9, or a watch app that broadcasts). The chosen sensor is remembered and reconnected by
/// itself, also in the background. Readings are available as `bpm` and through `currentReading()`.
@MainActor
final class HeartRateMonitor: NSObject, ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    enum State: Equatable {
        case idle
        case scanning
        case connecting
        case connected
        case reconnecting
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var bpm: Int?
    @Published private(set) var lastReadingAt: Date?
    @Published private(set) var battery: Int?
    @Published private(set) var rssi: Int?
    @Published private(set) var found: [Found] = []
    @Published private(set) var sensorName: String?
    /// Readings are arriving right now (one in the last 5 seconds)
    @Published private(set) var signal = false

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let idKey = "heartSensorID"
    private static let nameKey = "heartSensorName"
    private static let restoreID = "SportTreadHeart"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var wantsScan = false
    private var watcher: Task<Void, Never>?
    private var ticks = 0

    override init() {
        super.init()
        sensorName = UserDefaults.standard.string(forKey: Self.nameKey)
        if UserDefaults.standard.string(forKey: Self.idKey) != nil { makeCentral() }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    /// The latest reading, if one arrived in the last 5 seconds.
    func currentReading() -> (bpm: Int, at: Date)? {
        guard let bpm, let at = lastReadingAt, Date().timeIntervalSince(at) < 5 else { return nil }
        return (bpm, at)
    }

    private func tick() {
        let fresh = lastReadingAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if fresh != signal {
            signal = fresh
            if !fresh, bpm != nil { dlog("Heart rate: no readings for 5 s") }
            if fresh { dlog("Heart rate: readings are arriving (\(bpm ?? 0) bpm)") }
        }
        ticks += 1
        if ticks % 10 == 0, state == .connected { peripheral?.readRSSI() }
    }

    // MARK: Choosing a sensor

    private func makeCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    func startScan() {
        found = []
        discovered = [:]
        wantsScan = true
        makeCentral()
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [Self.hrService])
            state = .scanning
        }
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = peripheral == nil ? .idle : state }
    }

    func choose(_ id: UUID) {
        guard let chosen = discovered[id] else { return }
        let name = found.first { $0.id == id }?.name ?? chosen.name ?? "Heart-rate sensor"
        stopScan()
        UserDefaults.standard.set(id.uuidString, forKey: Self.idKey)
        UserDefaults.standard.set(name, forKey: Self.nameKey)
        sensorName = name
        dlog("Heart rate: chose \(name)")
        connect(chosen)
    }

    func forget() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.idKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        sensorName = nil
        bpm = nil
        lastReadingAt = nil
        battery = nil
        rssi = nil
        signal = false
        state = .idle
        dlog("Heart rate: sensor forgotten")
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        state = .connecting
        central?.connect(target)
    }

    private func connectRemembered() {
        guard let text = UserDefaults.standard.string(forKey: Self.idKey), let id = UUID(uuidString: text) else { return }
        if let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            wantsScan = true  // it will be picked up when it advertises
            central?.scanForPeripherals(withServices: [Self.hrService])
            state = .reconnecting
        }
    }
}

// CoreBluetooth calls these on the main queue (queue: nil), so assuming main-actor isolation is safe.
extension HeartRateMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if wantsScan, UserDefaults.standard.string(forKey: Self.idKey) == nil {
                    central.scanForPeripherals(withServices: [Self.hrService])
                    state = .scanning
                } else if peripheral == nil {
                    connectRemembered()
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
            guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
            peripheral = restored
            restored.delegate = self
            dlog("Heart rate: iOS restored the connection to \(restored.name ?? "the sensor")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            discovered[peripheral.identifier] = peripheral
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Heart-rate sensor"
            if let remembered = UserDefaults.standard.string(forKey: Self.idKey), remembered == peripheral.identifier.uuidString {
                central.stopScan()
                wantsScan = false
                connect(peripheral)
                return
            }
            guard state == .scanning else { return }
            if let index = found.firstIndex(where: { $0.id == peripheral.identifier }) {
                found[index].rssi = RSSI.intValue
            } else {
                found.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            state = .connected
            dlog("Heart rate: connected to \(peripheral.name ?? "the sensor")")
            peripheral.discoverServices([Self.hrService, Self.batteryService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            dlog("Heart rate: couldn't connect: \(error?.localizedDescription ?? "no reason given")")
            state = .reconnecting
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let current = self.peripheral { central.connect(current) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral else { return }  // forgotten on purpose
            dlog("Heart rate: disconnected (\(error?.localizedDescription ?? "no reason given")); reconnecting")
            state = .reconnecting
            central.connect(peripheral)  // iOS keeps trying until the sensor is back
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                if service.uuid == Self.hrService {
                    peripheral.discoverCharacteristics([Self.hrMeasurement], for: service)
                } else if service.uuid == Self.batteryService {
                    peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.hrMeasurement {
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == Self.batteryLevel {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value else { return }
            if characteristic.uuid == Self.hrMeasurement, let reading = HeartRateParser.parse(data) {
                bpm = reading.contact == false ? nil : reading.bpm
                lastReadingAt = Date()
            } else if characteristic.uuid == Self.batteryLevel, let level = data.first {
                battery = Int(level)
                dlog("Heart rate: sensor battery \(level)%")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated { rssi = RSSI.intValue }
    }
}
