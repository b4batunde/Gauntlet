import Foundation
import CoreBluetooth
import GauntletProtocol

/// Watch side of the Bluetooth LE link. The watch is the GATT central; the Mac is the peripheral.
///
/// - Sensor data goes out as write-without-response with a tiny newest-wins backlog,
///   so a congested radio drops stale samples instead of building up lag.
/// - Reliable messages use acknowledged writes.
/// - The Mac it paired with is remembered and reconnected to directly.
public final class BLECentralTransport: NSObject, LinkTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    public weak var delegate: LinkTransportDelegate?
    public let name = "Bluetooth"
    public private(set) var maxPayload = 20
    public private(set) var isOpen = false
    public private(set) var rssi = 0

    private let queue: DispatchQueue
    private let defaults: UserDefaults
    private let serviceUUID = CBUUID(string: Wire.serviceUUID)
    private let streamUUID = CBUUID(string: Wire.streamCharUUID)
    private let controlUUID = CBUUID(string: Wire.controlCharUUID)
    private static let rememberedKey = "gauntlet.rememberedMac"
    private static let maxBacklog = 6

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stream: CBCharacteristic?
    private var control: CBCharacteristic?
    private var wantsRunning = false
    private var backlog: [Data] = []
    private var lastUnreliableWrite: TimeInterval = 0
    private var avoid: [UUID: TimeInterval] = [:]
    private var connectStarted: TimeInterval = 0
    private var setupDeadline: DispatchWorkItem?
    private var rescan: DispatchWorkItem?
    private var rssiTimer: DispatchSourceTimer?

    public init(queue: DispatchQueue, defaults: UserDefaults = .standard) {
        self.queue = queue
        self.defaults = defaults
        super.init()
    }

    // MARK: LinkTransport

    public func start() {
        wantsRunning = true
        avoid.removeAll()                       // an explicit (re)start is the user asking to try again
        if let central {
            if central.state == .poweredOn { search() }
        } else {
            // Creating the manager is what triggers the Bluetooth permission prompt.
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    public func stop() {
        wantsRunning = false
        rescan?.cancel()
        rescan = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        teardown(reason: "stopped")
    }

    public func send(_ data: Data, reliable: Bool) {
        guard isOpen, let peripheral, let stream else { return }
        if reliable {
            peripheral.writeValue(data, for: stream, type: .withResponse)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if backlog.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: stream, type: .withoutResponse)
            lastUnreliableWrite = now
            return
        }
        backlog.append(data)
        if backlog.count > Self.maxBacklog { backlog.removeFirst(backlog.count - Self.maxBacklog) }
        // The "ready" callback occasionally never arrives; do not let the stream stall on it.
        if now - lastUnreliableWrite > 0.12, let newest = backlog.popLast() {
            backlog.removeAll()
            peripheral.writeValue(newest, for: stream, type: .withoutResponse)
            lastUnreliableWrite = now
        }
    }

    public func disconnectPeer() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    public func markPeer(accepted: Bool) {
        guard let id = peripheral?.identifier else { return }
        if accepted {
            defaults.set(id.uuidString, forKey: Self.rememberedKey)
        } else {
            avoid[id] = ProcessInfo.processInfo.systemUptime + 20
            if defaults.string(forKey: Self.rememberedKey) == id.uuidString {
                defaults.removeObject(forKey: Self.rememberedKey)
            }
        }
    }

    /// Forget the paired Mac so the next search accepts any Mac running Gauntlet.
    public func forgetRememberedPeer() {
        defaults.removeObject(forKey: Self.rememberedKey)
    }

    // MARK: Searching

    private var rememberedID: UUID? {
        defaults.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
    }

    private func isAvoided(_ id: UUID) -> Bool {
        guard let until = avoid[id] else { return false }
        if ProcessInfo.processInfo.systemUptime >= until { avoid[id] = nil; return false }
        return true
    }

    private func search() {
        guard wantsRunning, let central, central.state == .poweredOn, !isOpen else { return }
        delegate?.transport(self, didChangeStatus: "Looking for your Mac…")
        if peripheral == nil, let id = rememberedID, !isAvoided(id),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        }
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)

        // A scan reports each peripheral once. Restart it periodically so a Mac that was being
        // avoided, or that started advertising late, is seen again without user action.
        rescan?.cancel()
        let again = DispatchWorkItem { [weak self] in
            guard let self, self.wantsRunning, !self.isOpen else { return }
            self.central?.stopScan()
            self.search()
        }
        rescan = again
        queue.asyncAfter(deadline: .now() + 10, execute: again)
    }

    private func connect(_ target: CBPeripheral) {
        guard let central else { return }
        peripheral = target
        target.delegate = self
        connectStarted = ProcessInfo.processInfo.systemUptime
        central.connect(target, options: nil)
    }

    private func teardown(reason: String?) {
        setupDeadline?.cancel()
        setupDeadline = nil
        rssiTimer?.cancel()
        rssiTimer = nil
        peripheral?.delegate = nil
        peripheral = nil
        stream = nil
        control = nil
        backlog.removeAll()
        rssi = 0
        if isOpen {
            isOpen = false
            delegate?.transportDidClose(self, reason: reason)
        }
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.search() }
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsRunning { search() }
        case .poweredOff:
            teardown(reason: "Bluetooth turned off")
            delegate?.transport(self, didChangeStatus: "Bluetooth is off")
        case .unauthorized:
            teardown(reason: "Bluetooth not allowed")
            delegate?.transport(self, didChangeStatus: "Allow Bluetooth for Gauntlet in Settings")
        case .unsupported:
            delegate?.transport(self, didChangeStatus: "Bluetooth LE is not available")
        default:
            delegate?.transport(self, didChangeStatus: "Bluetooth is starting…")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantsRunning, !isOpen, !isAvoided(found.identifier) else { return }
        if let current = peripheral {
            // Still waiting on the remembered Mac while a different one is right here: switch after a grace period.
            guard current.identifier != found.identifier, current.state != .connected,
                  ProcessInfo.processInfo.systemUptime - connectStarted > 4 else { return }
            central.cancelPeripheralConnection(current)
            current.delegate = nil
            peripheral = nil
        }
        connect(found)
    }

    public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        guard connected.identifier == peripheral?.identifier else {
            central.cancelPeripheralConnection(connected)
            return
        }
        central.stopScan()
        delegate?.transport(self, didChangeStatus: "Connecting…")
        connected.discoverServices([serviceUUID])
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen, let p = self.peripheral else { return }
            self.central?.cancelPeripheralConnection(p)
        }
        setupDeadline = deadline
        queue.asyncAfter(deadline: .now() + 8, execute: deadline)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        guard failed.identifier == peripheral?.identifier else { return }
        teardown(reason: error?.localizedDescription)
        retrySoon()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral, error: Error?) {
        guard gone.identifier == peripheral?.identifier else { return }
        teardown(reason: error?.localizedDescription ?? "disconnected")
        retrySoon()
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([streamUUID, controlUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        stream = service.characteristics?.first { $0.uuid == streamUUID }
        control = service.characteristics?.first { $0.uuid == controlUUID }
        guard stream != nil, let control else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: control)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == controlUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard !isOpen else { return }
        setupDeadline?.cancel()
        maxPayload = peripheral.maximumWriteValueLength(for: .withoutResponse)
        backlog.removeAll()
        isOpen = true
        startRSSIUpdates()
        delegate?.transportDidOpen(self)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == controlUUID, let value = characteristic.value, !value.isEmpty else { return }
        delegate?.transport(self, didReceive: value)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isOpen, let stream else { return }
        while !backlog.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(backlog.removeFirst(), for: stream, type: .withoutResponse)
            lastUnreliableWrite = ProcessInfo.processInfo.systemUptime
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The Mac app restarted and rebuilt its service: start over cleanly.
        if invalidatedServices.contains(where: { $0.uuid == serviceUUID }) {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func startRSSIUpdates() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.isOpen else { return }
            self.peripheral?.readRSSI()
        }
        timer.resume()
        rssiTimer = timer
    }
}
