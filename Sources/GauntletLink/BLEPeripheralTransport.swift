#if os(macOS)
import Foundation
import CoreBluetooth
import GauntletProtocol

/// Mac side of the Bluetooth LE link: advertises the Gauntlet service and serves one watch.
///
/// Anyone nearby can connect at the radio level, so this layer deliberately knows nothing
/// about trust — `LinkServer` authenticates the peer before any input is acted on.
public final class BLEPeripheralTransport: NSObject, LinkTransport, CBPeripheralManagerDelegate {
    public weak var delegate: LinkTransportDelegate?
    public let name = "Bluetooth"
    public private(set) var maxPayload = 20
    public private(set) var isOpen = false

    private let queue: DispatchQueue
    private let serviceUUID = CBUUID(string: Wire.serviceUUID)
    private var manager: CBPeripheralManager?
    private var streamCharacteristic: CBMutableCharacteristic?
    private var controlCharacteristic: CBMutableCharacteristic?
    private var activeCentral: CBCentral?
    private var outbox: [Data] = []
    private var wantsRunning = false

    public init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    // MARK: LinkTransport

    public func start() {
        wantsRunning = true
        if let manager {
            if manager.state == .poweredOn { publishService() }
        } else {
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    public func stop() {
        wantsRunning = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        closePeer(reason: "stopped")
    }

    public func send(_ data: Data, reliable: Bool) {
        guard isOpen, let manager, let control = controlCharacteristic, let central = activeCentral else { return }
        if outbox.isEmpty, manager.updateValue(data, for: control, onSubscribedCentrals: [central]) { return }
        outbox.append(data)
        if outbox.count > 64 { outbox.removeFirst(outbox.count - 64) }
    }

    public func disconnectPeer() {
        // A peripheral cannot hang up on a central. Stop listening to it; the watch notices the
        // missing heartbeat (or the rejection) and reconnects with a fresh subscription.
        closePeer(reason: "peer dropped")
    }

    // MARK: Setup

    private func publishService() {
        guard let manager, wantsRunning else { return }
        manager.removeAllServices()
        let stream = CBMutableCharacteristic(type: CBUUID(string: Wire.streamCharUUID),
                                             properties: [.write, .writeWithoutResponse],
                                             value: nil, permissions: [.writeable])
        let control = CBMutableCharacteristic(type: CBUUID(string: Wire.controlCharUUID),
                                              properties: [.notify, .read],
                                              value: nil, permissions: [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [stream, control]
        streamCharacteristic = stream
        controlCharacteristic = control
        manager.add(service)
    }

    private func advertise() {
        guard let manager, wantsRunning, manager.state == .poweredOn, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: Wire.advertisedName,
        ])
    }

    private func closePeer(reason: String?) {
        activeCentral = nil
        outbox.removeAll()
        if isOpen {
            isOpen = false
            delegate?.transportDidClose(self, reason: reason)
        }
    }

    // MARK: CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            delegate?.transport(self, didChangeStatus: "Waiting for your watch…")
            publishService()
        case .poweredOff:
            closePeer(reason: "Bluetooth turned off")
            delegate?.transport(self, didChangeStatus: "Bluetooth is off — turn it on to connect your watch")
        case .unauthorized:
            closePeer(reason: "Bluetooth not allowed")
            delegate?.transport(self, didChangeStatus: "Allow Bluetooth for Gauntlet in System Settings › Privacy & Security")
        case .unsupported:
            delegate?.transport(self, didChangeStatus: "This Mac does not support Bluetooth LE")
        default:
            delegate?.transport(self, didChangeStatus: "Bluetooth is starting…")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            delegate?.transport(self, didChangeStatus: "Bluetooth service failed: \(error.localizedDescription)")
            return
        }
        advertise()
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            delegate?.transport(self, didChangeStatus: "Could not advertise: \(error.localizedDescription)")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == controlCharacteristic?.uuid else { return }
        if let current = activeCentral {
            guard current.identifier == central.identifier else { return }      // someone else: not our watch
            closePeer(reason: "watch reconnected")                              // same watch, fresh session
        }
        activeCentral = central
        maxPayload = central.maximumUpdateValueLength
        peripheral.setDesiredConnectionLatency(.low, for: central)
        isOpen = true
        delegate?.transportDidOpen(self)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard central.identifier == activeCentral?.identifier else { return }
        closePeer(reason: "watch disconnected")
        advertise()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Reassemble long writes (several requests with rising offsets) into whole messages.
        var messages: [Data] = []
        var current: Data?
        for request in requests where request.characteristic.uuid == streamCharacteristic?.uuid {
            guard request.central.identifier == activeCentral?.identifier, let value = request.value else { continue }
            if request.offset == 0 {
                if let current { messages.append(current) }
                current = value
            } else if var assembled = current, request.offset <= assembled.count {
                assembled.replaceSubrange(request.offset..<assembled.count, with: value)
                current = assembled
            }
        }
        if let current { messages.append(current) }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        for message in messages where isOpen {
            delegate?.transport(self, didReceive: message)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let control = controlCharacteristic, let central = activeCentral else { return }
        while let next = outbox.first {
            guard peripheral.updateValue(next, for: control, onSubscribedCentrals: [central]) else { break }
            outbox.removeFirst()
        }
    }
}
#endif
