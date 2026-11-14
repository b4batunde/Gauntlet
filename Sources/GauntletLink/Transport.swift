import Foundation

/// Receives transport events. Always called on the link queue.
public protocol LinkTransportDelegate: AnyObject {
    /// A peer is connected and bytes can flow.
    func transportDidOpen(_ transport: LinkTransport)
    func transport(_ transport: LinkTransport, didReceive data: Data)
    /// The peer went away. The transport keeps looking for a peer until `stop()`.
    func transportDidClose(_ transport: LinkTransport, reason: String?)
    /// Human-readable radio status ("Bluetooth is off", "Looking for your Mac…").
    func transport(_ transport: LinkTransport, didChangeStatus status: String)
}

/// A message pipe to exactly one peer. Datagram semantics: one `send` = one `didReceive`.
///
/// All methods must be called on the link queue the transport was created with.
public protocol LinkTransport: AnyObject {
    var delegate: LinkTransportDelegate? { get set }
    var name: String { get }
    /// Largest message that fits in one unreliable send. Valid once open.
    var maxPayload: Int { get }
    var isOpen: Bool { get }
    /// True for transports that can only be reached from this machine (the developer link).
    var isLocalLoopback: Bool { get }
    /// Signal strength of the peer in dBm, or 0 when unknown.
    var rssi: Int { get }

    /// Start looking for a peer; reconnects automatically until `stop()`.
    func start()
    func stop()
    /// `reliable` messages are acknowledged and never dropped; unreliable ones may be
    /// dropped under back-pressure (newest wins) so the stream never lags behind reality.
    func send(_ data: Data, reliable: Bool)
    /// Drop the current peer but keep running.
    func disconnectPeer()
    /// The handshake finished: remember this peer for fast reconnects, or avoid it.
    func markPeer(accepted: Bool)
}

public extension LinkTransport {
    var isLocalLoopback: Bool { false }
    var rssi: Int { 0 }
    func markPeer(accepted: Bool) {}
}

/// Two in-memory transports wired back to back. For tests.
public final class LoopbackTransport: LinkTransport {
    public weak var delegate: LinkTransportDelegate?
    public let name: String
    public var maxPayload = 180
    public private(set) var isOpen = false
    public var isLocalLoopback: Bool { true }
    /// Set to drop every unreliable message (simulates a congested radio).
    public var dropUnreliable = false

    private weak var peer: LoopbackTransport?
    private let queue: DispatchQueue
    private var started = false

    private init(name: String, queue: DispatchQueue) {
        self.name = name
        self.queue = queue
    }

    public static func pair(queue: DispatchQueue) -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport(name: "loopback-a", queue: queue)
        let b = LoopbackTransport(name: "loopback-b", queue: queue)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func start() {
        started = true
        guard let peer, peer.started, !isOpen else { return }
        isOpen = true
        peer.isOpen = true
        queue.async { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.delegate?.transportDidOpen(self)
            peer.delegate?.transportDidOpen(peer)
        }
    }

    public func stop() {
        started = false
        close(reason: "stopped")
    }

    public func send(_ data: Data, reliable: Bool) {
        guard isOpen, let peer else { return }
        if !reliable && dropUnreliable { return }
        // Anything sent before a close is still delivered, in order, as on a real link.
        queue.async { [weak peer] in
            guard let peer else { return }
            peer.delegate?.transport(peer, didReceive: data)
        }
    }

    public func disconnectPeer() { close(reason: "disconnected") }

    private func close(reason: String) {
        guard isOpen else { return }
        isOpen = false
        let peer = self.peer
        peer?.isOpen = false
        queue.async { [weak self, weak peer] in
            if let self { self.delegate?.transportDidClose(self, reason: reason) }
            if let peer { peer.delegate?.transportDidClose(peer, reason: reason) }
        }
    }
}
