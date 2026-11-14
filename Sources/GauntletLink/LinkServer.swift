import Foundation
import CryptoKit
import GauntletProtocol

public enum LinkServerState: Equatable, Sendable {
    /// No watch connected; the text describes what the radios are doing.
    case waiting(String)
    case handshaking
    /// A new watch wants to pair. Show the code and ask the user.
    case awaitingApproval(watchName: String, code: String)
    case connected(watchName: String, via: String)
}

/// Called on the link queue.
public protocol LinkServerDelegate: AnyObject {
    func linkServer(_ server: LinkServer, didChange state: LinkServerState)
    func linkServer(_ server: LinkServer, didReceive message: WatchMessage)
}

/// The Mac end of the link: authenticates a watch, then relays its messages.
///
/// Only watches the user has approved (verified by key, not by name) get through.
/// One watch at a time. Public methods are safe to call from any thread.
public final class LinkServer: LinkTransportDelegate {
    public weak var delegate: LinkServerDelegate?
    public let queue: DispatchQueue

    private let identity: LinkIdentity
    private let trust: TrustStore
    private let macName: String
    private var transports: [LinkTransport] = []
    private var statuses: [String: String] = [:]
    private var session: Session?
    private var watchdog: DispatchSourceTimer?
    private var running = false
    private var lastState: LinkServerState = .waiting("Starting…")

    private final class Session {
        enum Phase { case awaitingHello, awaitingProof, awaitingApproval, active }
        let transport: LinkTransport
        var phase = Phase.awaitingHello
        var hello: Hello?
        var key: SymmetricKey?
        var nonce = Data()
        var phaseStarted = ProcessInfo.processInfo.systemUptime
        var lastHeard = ProcessInfo.processInfo.systemUptime
        init(transport: LinkTransport) { self.transport = transport }
    }

    public init(identity: LinkIdentity, trust: TrustStore, macName: String, queue: DispatchQueue) {
        self.identity = identity
        self.trust = trust
        self.macName = macName
        self.queue = queue
    }

    // MARK: Control (any thread)

    public func add(_ transport: LinkTransport) {
        queue.async {
            transport.delegate = self
            self.transports.append(transport)
            if self.running { transport.start() }
        }
    }

    public func remove(named name: String) {
        queue.async {
            guard let index = self.transports.firstIndex(where: { $0.name == name }) else { return }
            let transport = self.transports.remove(at: index)
            if self.session?.transport === transport { self.endSession(reason: "transport removed", dropPeer: false) }
            transport.stop()
            transport.delegate = nil
            self.statuses[name] = nil
            self.publishWaitingIfIdle()
        }
    }

    public func start() {
        queue.async { self.startLocked() }
    }

    private func startLocked() {
        guard !running else { return }
        running = true
        transports.forEach { $0.start() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkTimeouts() }
        timer.resume()
        watchdog = timer
    }

    public func stop() {
        queue.async {
            self.running = false
            self.watchdog?.cancel()
            self.watchdog = nil
            self.endSession(reason: "stopped", dropPeer: true)
            self.transports.forEach { $0.stop() }
        }
    }

    public func approvePairing() {
        queue.async {
            guard let s = self.session, s.phase == .awaitingApproval, let hello = s.hello else { return }
            self.trust.trust(deviceID: hello.deviceID, publicKey: hello.publicKey, name: hello.name)
            self.accept(s)
        }
    }

    public func rejectPairing() {
        queue.async {
            guard let s = self.session, s.phase == .awaitingApproval else { return }
            self.reject(s, reason: "pairing declined")
        }
    }

    /// Send to the authenticated watch. Silently dropped when none is connected.
    public func send(_ message: MacMessage) {
        queue.async {
            guard let s = self.session, s.phase == .active else { return }
            s.transport.send(message.encoded(), reliable: true)
        }
    }

    public func disconnect() {
        queue.async { self.endSession(reason: "disconnected by user", dropPeer: true) }
    }

    // MARK: LinkTransportDelegate (link queue)

    public func transportDidOpen(_ transport: LinkTransport) {
        if session != nil {
            // Already talking to a watch; a second one has to wait its turn.
            transport.disconnectPeer()
            return
        }
        session = Session(transport: transport)
        publish(.handshaking)
    }

    public func transport(_ transport: LinkTransport, didReceive data: Data) {
        guard let s = session, s.transport === transport else { return }
        guard let message = try? WatchMessage.decode(data) else { return }
        s.lastHeard = ProcessInfo.processInfo.systemUptime

        switch (s.phase, message) {
        case (.awaitingHello, .hello(let hello)):
            guard hello.version == Wire.protocolVersion,
                  let key = try? LinkCrypto.pairingKey(identity: identity, peerPublicKey: hello.publicKey,
                                                       watchID: hello.deviceID, macID: identity.deviceID) else {
                reject(s, reason: "incompatible watch app version")
                return
            }
            s.hello = hello
            s.key = key
            s.nonce = LinkCrypto.nonce()
            setPhase(s, .awaitingProof)
            let known = trust.isTrusted(deviceID: hello.deviceID, publicKey: hello.publicKey)
            let ack = HelloAck(deviceID: identity.deviceID, publicKey: identity.publicKey,
                               nonce: s.nonce, known: known, name: macName)
            transport.send(MacMessage.helloAck(ack).encoded(), reliable: true)

        case (.awaitingProof, .authProof(let proof)):
            guard let key = s.key, let hello = s.hello,
                  LinkCrypto.verify(proof, role: "watch", key: key, nonce: s.nonce) else {
                reject(s, reason: "watch failed verification")
                return
            }
            if trust.isTrusted(deviceID: hello.deviceID, publicKey: hello.publicKey) || transport.isLocalLoopback {
                accept(s)
            } else {
                setPhase(s, .awaitingApproval)
                let result = AuthResult(status: .pendingApproval,
                                        proof: LinkCrypto.proof("mac", key: key, nonce: s.nonce))
                transport.send(MacMessage.authResult(result).encoded(), reliable: true)
                publish(.awaitingApproval(watchName: hello.name, code: LinkCrypto.pairingCode(key: key)))
            }

        case (.active, .bye):
            delegate?.linkServer(self, didReceive: .bye)
            endSession(reason: "watch said goodbye", dropPeer: false)

        case (.active, .hello), (.active, .authProof):
            break

        case (.active, _):
            delegate?.linkServer(self, didReceive: message)

        default:
            break       // anything else before authentication is ignored
        }
    }

    public func transportDidClose(_ transport: LinkTransport, reason: String?) {
        guard let s = session, s.transport === transport else { return }
        endSession(reason: reason ?? "connection lost", dropPeer: false)
    }

    public func transport(_ transport: LinkTransport, didChangeStatus status: String) {
        statuses[transport.name] = status
        publishWaitingIfIdle()
    }

    // MARK: Session

    private func setPhase(_ s: Session, _ phase: Session.Phase) {
        s.phase = phase
        s.phaseStarted = ProcessInfo.processInfo.systemUptime
    }

    private func accept(_ s: Session) {
        guard let key = s.key, let hello = s.hello else { return }
        setPhase(s, .active)
        s.lastHeard = ProcessInfo.processInfo.systemUptime
        let result = AuthResult(status: .accepted, proof: LinkCrypto.proof("mac", key: key, nonce: s.nonce))
        s.transport.send(MacMessage.authResult(result).encoded(), reliable: true)
        s.transport.markPeer(accepted: true)
        publish(.connected(watchName: hello.name, via: s.transport.name))
    }

    private func reject(_ s: Session, reason: String) {
        let result = AuthResult(status: .rejected, proof: Data(count: 32))
        s.transport.send(MacMessage.authResult(result).encoded(), reliable: true)
        s.transport.markPeer(accepted: false)
        endSession(reason: reason, dropPeer: true)
    }

    private func endSession(reason: String, dropPeer: Bool) {
        guard let s = session else { return }
        let wasActive = s.phase == .active
        session = nil
        if dropPeer { s.transport.disconnectPeer() }
        if wasActive { delegate?.linkServer(self, didReceive: .bye) }
        publishWaitingIfIdle(force: true)
    }

    private func checkTimeouts() {
        guard let s = session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch s.phase {
        case .awaitingHello, .awaitingProof:
            if now - s.phaseStarted > 8 { endSession(reason: "handshake timed out", dropPeer: true) }
        case .awaitingApproval:
            if now - s.phaseStarted > 120 { reject(s, reason: "pairing request expired") }
        case .active:
            if now - s.lastHeard > 5 {
                endSession(reason: "watch went silent", dropPeer: true)
            } else {
                // Heartbeat: if these stop arriving, the watch knows to reconnect from scratch.
                s.transport.send(MacMessage.ping.encoded(), reliable: true)
            }
        }
    }

    private func publishWaitingIfIdle(force: Bool = false) {
        guard session == nil else { return }
        let text = statuses.sorted { $0.key < $1.key }.map(\.value).first { !$0.isEmpty } ?? "Waiting for your watch…"
        publish(.waiting(text), force: force)
    }

    private func publish(_ state: LinkServerState, force: Bool = false) {
        guard force || state != lastState else { return }
        lastState = state
        delegate?.linkServer(self, didChange: state)
    }
}
