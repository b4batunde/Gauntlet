import Foundation
import CryptoKit
import GauntletProtocol

public enum LinkClientState: Equatable, Sendable {
    case idle
    /// Not connected yet; the text says why ("Bluetooth is off", "Looking for your Mac…").
    case searching(String)
    case handshaking
    /// First-time pairing: the same code is on the Mac, waiting for the user to confirm there.
    case awaitingApproval(code: String, macName: String)
    case connected(macName: String)
    case rejected(String)
}

/// Called on the link queue.
public protocol LinkClientDelegate: AnyObject {
    func linkClient(_ client: LinkClient, didChange state: LinkClientState)
    func linkClient(_ client: LinkClient, didReceive message: MacMessage)
}

/// The watch end of the link. Must be used on the link queue.
public final class LinkClient: LinkTransportDelegate {
    public weak var delegate: LinkClientDelegate?
    public private(set) var state: LinkClientState = .idle

    private let identity: LinkIdentity
    private let deviceName: String
    private let transport: LinkTransport
    private let queue: DispatchQueue
    private var key: SymmetricKey?
    private var nonce = Data()
    private var macName = "Mac"
    private var handshakeDeadline: DispatchWorkItem?
    private var lastStatus = "Looking for your Mac…"
    private var lastHeard: TimeInterval = 0
    private var livenessTimer: DispatchSourceTimer?

    /// The Mac sends a heartbeat every second while a session is live. Longer silence than this
    /// means the two ends disagree about the session, so drop the link and handshake again.
    public var silenceLimit: TimeInterval = 4.5

    public init(identity: LinkIdentity, deviceName: String, transport: LinkTransport, queue: DispatchQueue) {
        self.identity = identity
        self.deviceName = deviceName
        self.transport = transport
        self.queue = queue
        transport.delegate = self
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Largest message the transport can carry unreliably right now.
    public var maxPayload: Int { transport.maxPayload }
    public var rssi: Int { transport.rssi }

    public func start() {
        livenessTimer?.cancel()
        setState(.searching(lastStatus))
        transport.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        timer.resume()
        livenessTimer = timer
    }

    public func stop() {
        if isConnected { transport.send(WatchMessage.bye.encoded(), reliable: true) }
        handshakeDeadline?.cancel()
        livenessTimer?.cancel()
        livenessTimer = nil
        transport.stop()
        setState(.idle)
    }

    private func checkLiveness() {
        guard isConnected, ProcessInfo.processInfo.systemUptime - lastHeard > silenceLimit else { return }
        transport.disconnectPeer()          // the transport reconnects and we handshake afresh
    }

    /// Sends when connected; otherwise the message is dropped.
    public func send(_ message: WatchMessage) {
        guard isConnected else { return }
        transport.send(message.encoded(), reliable: message.isReliable)
    }

    // MARK: LinkTransportDelegate

    public func transportDidOpen(_ transport: LinkTransport) {
        key = nil
        setState(.handshaking)
        let hello = Hello(deviceID: identity.deviceID, publicKey: identity.publicKey, name: deviceName)
        transport.send(WatchMessage.hello(hello).encoded(), reliable: true)
        armDeadline(seconds: 8)
    }

    public func transport(_ transport: LinkTransport, didReceive data: Data) {
        guard let message = try? MacMessage.decode(data) else { return }
        lastHeard = ProcessInfo.processInfo.systemUptime
        switch message {
        case .helloAck(let ack):
            guard case .handshaking = state else { return }
            guard ack.version == Wire.protocolVersion,
                  let key = try? LinkCrypto.pairingKey(identity: identity, peerPublicKey: ack.publicKey,
                                                       watchID: identity.deviceID, macID: ack.deviceID) else {
                fail("This Mac runs an incompatible version of Gauntlet.")
                return
            }
            self.key = key
            nonce = ack.nonce
            macName = ack.name.isEmpty ? "Mac" : ack.name
            transport.send(WatchMessage.authProof(LinkCrypto.proof("watch", key: key, nonce: nonce)).encoded(),
                           reliable: true)

        case .authResult(let result):
            guard let key else { return }
            switch result.status {
            case .rejected:
                fail("Pairing was declined on the Mac.")
            case .pendingApproval, .accepted:
                // The Mac must prove it derived the same key, or we stop streaming to it.
                guard LinkCrypto.verify(result.proof, role: "mac", key: key, nonce: nonce) else {
                    fail("Could not verify this Mac.")
                    return
                }
                if result.status == .accepted {
                    handshakeDeadline?.cancel()
                    transport.markPeer(accepted: true)
                    setState(.connected(macName: macName))
                } else {
                    armDeadline(seconds: 125)
                    setState(.awaitingApproval(code: LinkCrypto.pairingCode(key: key), macName: macName))
                }
            }

        case .ping:
            break                                   // heartbeat only; `lastHeard` is already updated

        default:
            if isConnected { delegate?.linkClient(self, didReceive: message) }
        }
    }

    public func transportDidClose(_ transport: LinkTransport, reason: String?) {
        handshakeDeadline?.cancel()
        key = nil
        if case .rejected = state { return }        // keep the explanation on screen
        setState(.searching(lastStatus))
    }

    public func transport(_ transport: LinkTransport, didChangeStatus status: String) {
        lastStatus = status
        if case .searching = state { setState(.searching(status)) }
    }

    // MARK: Helpers

    /// The Mac said no (or could not be verified). Stop looking: retrying on our own would keep
    /// re-prompting the person who just declined. The explanation stays up until `start()` is
    /// called again.
    private func fail(_ text: String) {
        handshakeDeadline?.cancel()
        setState(.rejected(text))
        transport.markPeer(accepted: false)
        transport.stop()
    }

    private func armDeadline(seconds: Double) {
        handshakeDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected else { return }
            self.transport.disconnectPeer()          // the transport will look again
        }
        handshakeDeadline = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func setState(_ new: LinkClientState) {
        guard new != state else { return }
        state = new
        delegate?.linkClient(self, didChange: new)
    }
}
