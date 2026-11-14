import Foundation
import GauntletProtocol
import GauntletLink
import GauntletWatchCore
import GauntletEngine

final class ServerProbe: LinkServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [LinkServerState] = []
    private var _messages: [WatchMessage] = []
    var onMessage: ((WatchMessage) -> Void)?

    var states: [LinkServerState] { lock.lock(); defer { lock.unlock() }; return _states }
    var messages: [WatchMessage] { lock.lock(); defer { lock.unlock() }; return _messages }
    var last: LinkServerState? { states.last }

    func linkServer(_ server: LinkServer, didChange state: LinkServerState) {
        lock.lock(); _states.append(state); lock.unlock()
    }
    func linkServer(_ server: LinkServer, didReceive message: WatchMessage) {
        lock.lock(); _messages.append(message); lock.unlock()
        onMessage?(message)
    }
}

final class ClientProbe: LinkClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [LinkClientState] = []
    private var _messages: [MacMessage] = []
    var states: [LinkClientState] { lock.lock(); defer { lock.unlock() }; return _states }
    var messages: [MacMessage] { lock.lock(); defer { lock.unlock() }; return _messages }
    var last: LinkClientState? { states.last }

    func linkClient(_ client: LinkClient, didChange state: LinkClientState) {
        lock.lock(); _states.append(state); lock.unlock()
    }
    func linkClient(_ client: LinkClient, didReceive message: MacMessage) {
        lock.lock(); _messages.append(message); lock.unlock()
    }
}

@discardableResult
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

func runLink() { suite("Link") {
    test("first pairing needs approval, shows the same code on both ends, then connects") {
        let queue = DispatchQueue(label: "test.link.1")
        let (macSide, watchSide) = LoopbackTransport.pair(queue: queue)
        let trust = TrustStore(fileURL: nil)
        let server = LinkServer(identity: LinkIdentity(), trust: trust, macName: "Test Mac", queue: queue)
        let serverProbe = ServerProbe()
        server.delegate = serverProbe
        // Loopback transports are auto-approved (developer link); make this one look like a radio.
        let radio = RadioLike(macSide)
        server.add(radio)
        server.start()

        let clientProbe = ClientProbe()
        let watchIdentity = LinkIdentity()
        let client = queue.sync { LinkClient(identity: watchIdentity, deviceName: "Test Watch", transport: watchSide, queue: queue) }
        client.delegate = clientProbe
        queue.sync { client.start() }

        var serverCode = "", clientCode = ""
        expect(waitUntil {
            if case .awaitingApproval(_, let code)? = serverProbe.last { serverCode = code }
            if case .awaitingApproval(let code, _)? = clientProbe.last { clientCode = code }
            return !serverCode.isEmpty && !clientCode.isEmpty
        }, "both sides reach awaitingApproval")
        expect(serverCode == clientCode && serverCode.count == 7, "codes match: \(serverCode) vs \(clientCode)")

        // Nothing gets through before approval.
        queue.sync { watchSide.send(WatchMessage.action(WatchAction(seq: 1, code: .leftClick)).encoded(), reliable: true) }
        usleep(50_000)
        expect(serverProbe.messages.isEmpty, "input before approval is ignored")

        server.approvePairing()
        expect(waitUntil { clientProbe.last == .connected(macName: "Test Mac") })
        expect(waitUntil { serverProbe.last == .connected(watchName: "Test Watch", via: radio.name) })
        expect(trust.all.count == 1)

        queue.sync { client.send(.action(WatchAction(seq: 2, code: .handDoubleTap))) }
        server.send(.haptic(.click))
        expect(waitUntil { serverProbe.messages.contains(.action(WatchAction(seq: 2, code: .handDoubleTap))) })
        expect(waitUntil { clientProbe.messages.contains(.haptic(.click)) })

        // Second session with the same identities: straight in, no prompt.
        queue.sync { client.stop() }
        expect(waitUntil { if case .waiting? = serverProbe.last { return true } else { return false } })
        let (macSide2, watchSide2) = LoopbackTransport.pair(queue: queue)
        let radio2 = RadioLike(macSide2, name: "radio-2")
        server.add(radio2)
        let clientProbe2 = ClientProbe()
        let client2 = queue.sync { LinkClient(identity: watchIdentity, deviceName: "Test Watch", transport: watchSide2, queue: queue) }
        client2.delegate = clientProbe2
        queue.sync { client2.start() }
        expect(waitUntil { clientProbe2.last == .connected(macName: "Test Mac") })
        expect(!clientProbe2.states.contains { if case .awaitingApproval = $0 { return true } else { return false } })
        server.stop()
    }

    test("an impostor reusing a trusted watch's ID with a different key is not trusted") {
        let queue = DispatchQueue(label: "test.link.2")
        let trust = TrustStore(fileURL: nil)
        let real = LinkIdentity()
        trust.trust(deviceID: real.deviceID, publicKey: real.publicKey, name: "Real Watch")
        expect(trust.isTrusted(deviceID: real.deviceID, publicKey: real.publicKey))
        expect(!trust.isTrusted(deviceID: real.deviceID, publicKey: LinkIdentity().publicKey))

        // Raw peer that claims the trusted ID but cannot produce a valid proof.
        let (macSide, attacker) = LoopbackTransport.pair(queue: queue)
        let server = LinkServer(identity: LinkIdentity(), trust: trust, macName: "Test Mac", queue: queue)
        let probe = ServerProbe()
        server.delegate = probe
        let radio = RadioLike(macSide)
        server.add(radio)
        server.start()
        let sink = RawPeer()
        queue.sync { attacker.delegate = sink; attacker.start() }
        expect(waitUntil { probe.last == .handshaking })
        queue.sync {
            attacker.send(WatchMessage.hello(Hello(deviceID: real.deviceID, publicKey: real.publicKey, name: "Real Watch")).encoded(), reliable: true)
            attacker.send(WatchMessage.authProof(Data(repeating: 7, count: 32)).encoded(), reliable: true)
            attacker.send(WatchMessage.action(WatchAction(seq: 1, code: .leftClick)).encoded(), reliable: true)
        }
        expect(waitUntil { sink.received.contains { (try? MacMessage.decode($0)).map { if case .authResult(let r) = $0 { return r.status == .rejected } else { return false } } ?? false } },
               "attacker is rejected")
        expect(probe.messages.isEmpty, "no input accepted from the impostor")
        expect(!probe.states.contains { if case .connected = $0 { return true } else { return false } })
        server.stop()
    }

    test("a declined pairing tells the watch why, and it stops asking until told to retry") {
        let queue = DispatchQueue(label: "test.link.4")
        let (macSide, watchSide) = LoopbackTransport.pair(queue: queue)
        let server = LinkServer(identity: LinkIdentity(), trust: TrustStore(fileURL: nil), macName: "Test Mac", queue: queue)
        let serverProbe = ServerProbe()
        server.delegate = serverProbe
        server.add(RadioLike(macSide))
        server.start()
        let clientProbe = ClientProbe()
        let client = queue.sync { LinkClient(identity: LinkIdentity(), deviceName: "Test Watch", transport: watchSide, queue: queue) }
        client.delegate = clientProbe
        queue.sync { client.start() }
        expect(waitUntil { if case .awaitingApproval? = serverProbe.last { return true } else { return false } })
        server.rejectPairing()
        expect(waitUntil { if case .rejected? = clientProbe.last { return true } else { return false } }, "watch learns it was declined")
        usleep(1_200_000)
        expect({ if case .rejected? = clientProbe.last { return true } else { return false } }(), "explanation stays on screen")
        expect(!serverProbe.states.contains { if case .connected = $0 { return true } else { return false } })
        let prompts = serverProbe.states.filter { if case .awaitingApproval = $0 { return true } else { return false } }.count
        expect(prompts == 1, "the Mac is not prompted again on its own (\(prompts))")
        server.stop()
    }

    test("a watch whose Mac goes silent drops the link and handshakes again") {
        let queue = DispatchQueue(label: "test.link.3")
        let (macSide, watchSide) = LoopbackTransport.pair(queue: queue)
        let watchIdentity = LinkIdentity()
        let trust = TrustStore(fileURL: nil)
        trust.trust(deviceID: watchIdentity.deviceID, publicKey: watchIdentity.publicKey, name: "Test Watch")
        let server = LinkServer(identity: LinkIdentity(), trust: trust, macName: "Test Mac", queue: queue)
        let serverProbe = ServerProbe()
        server.delegate = serverProbe
        let radio = RadioLike(macSide)
        server.add(radio)
        server.start()
        let clientProbe = ClientProbe()
        let client = queue.sync { LinkClient(identity: watchIdentity, deviceName: "Test Watch", transport: watchSide, queue: queue) }
        client.delegate = clientProbe
        queue.sync { client.silenceLimit = 1.5; client.start() }
        expect(waitUntil { clientProbe.last == .connected(macName: "Test Mac") })

        // While the heartbeat flows the session stays up.
        usleep(2_500_000)
        expect(clientProbe.last == .connected(macName: "Test Mac"), "stays connected while pinged")
        expect(clientProbe.messages.contains(.ping) == false, "pings are not surfaced as messages")

        // The Mac side goes mute (half-open link): the watch must notice and start over.
        queue.sync { radio.muted = true }
        expect(waitUntil(5) { if case .searching? = clientProbe.last { return true } else { return false } },
               "client dropped the silent link")
        server.stop()
        queue.sync { client.stop() }
    }

    test("end to end over real sockets: watch controller -> developer link -> engine -> pointer") {
        let serverQueue = DispatchQueue(label: "test.link.server")
        let port: UInt16 = 47999
        let server = LinkServer(identity: LinkIdentity(), trust: TrustStore(fileURL: nil), macName: "Test Mac", queue: serverQueue)
        let engine = WristEngine()
        let sink = RecordingSink()
        engine.sink = sink
        let probe = ServerProbe()
        probe.onMessage = { engine.ingest($0) }
        server.delegate = probe
        server.add(TCPServerTransport(port: port, queue: serverQueue))
        server.start()

        let clientQueue = DispatchQueue(label: "test.link.client")
        let controller = WatchSessionController(
            deviceName: "Fake Watch", identity: LinkIdentity(),
            transport: TCPClientTransport(port: port, queue: clientQueue), queue: clientQueue)
        var haptics: [HapticPattern] = []
        controller.onHaptic = { haptics.append($0) }
        controller.start()
        // Published state lands on the main queue, which this test is blocking; watch the server side instead.
        expect(waitUntil(5) { if case .connected? = probe.last { return true } else { return false } }, "connected over TCP")

        // Stream a rightward sweep in real time.
        let watch = VirtualWatch(seed: 3)
        watch.snap(heading: 0, elevation: 0.35)
        let feed: (Double) -> Void = { seconds in
            for _ in 0..<Int(seconds / 0.01) {
                guard case .motion(let p) = { watch.samplesPerPacket = 1; return watch.nextPacket() }() else { continue }
                controller.submitMotion(gyro: p.samples[0].gyro, accel: p.samples[0].accel,
                                        gravity: p.gravity, quaternion: p.quaternion)
                usleep(10_000)
            }
        }
        feed(0.4)
        watch.targetHeading = -0.3
        feed(1.0)
        expect(waitUntil { sink.x > 150 }, "pointer moved right, x=\(sink.x)")
        expect(engine.snapshot().streaming)
        expect(engine.snapshot().packetRate > 30, "packet rate \(engine.snapshot().packetRate)")

        controller.sendCrown(delta: 0.2)
        controller.sendAction(.screenTap)
        expect(waitUntil { sink.clicks(.left) == 1 && sink.scrollY > 100 }, "crown + tap arrive")

        // Dropping the link stops the stream and never leaves a button held.
        engine.perform(.toggleDrag)
        expect(engine.snapshot().dragging)
        controller.stop()
        expect(waitUntil { if case .waiting? = probe.last { return true } else { return false } })
        engine.linkDidDisconnect()
        expect(!engine.snapshot().dragging && !engine.snapshot().streaming)
        server.stop()
        usleep(100_000)
    }
} }

/// Wraps a loopback transport but reports itself as a real radio, so the server demands approval.
final class RadioLike: LinkTransport, LinkTransportDelegate {
    weak var delegate: LinkTransportDelegate?
    let inner: LoopbackTransport
    let name: String
    var maxPayload: Int { inner.maxPayload }
    var isOpen: Bool { inner.isOpen }
    var isLocalLoopback: Bool { false }
    private(set) var acceptedMarks = 0
    /// When true, nothing we send reaches the peer (a half-open link).
    var muted = false

    init(_ inner: LoopbackTransport, name: String = "radio") {
        self.inner = inner
        self.name = name
        inner.delegate = self
    }
    func start() { inner.start() }
    func stop() { inner.stop() }
    func send(_ data: Data, reliable: Bool) { if !muted { inner.send(data, reliable: reliable) } }
    func disconnectPeer() { inner.disconnectPeer() }
    func markPeer(accepted: Bool) { if accepted { acceptedMarks += 1 } }
    func transportDidOpen(_ transport: LinkTransport) { delegate?.transportDidOpen(self) }
    func transport(_ transport: LinkTransport, didReceive data: Data) { delegate?.transport(self, didReceive: data) }
    func transportDidClose(_ transport: LinkTransport, reason: String?) { delegate?.transportDidClose(self, reason: reason) }
    func transport(_ transport: LinkTransport, didChangeStatus status: String) { delegate?.transport(self, didChangeStatus: status) }
}

final class RawPeer: LinkTransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [Data] = []
    var received: [Data] { lock.lock(); defer { lock.unlock() }; return _received }
    func transportDidOpen(_ transport: LinkTransport) {}
    func transport(_ transport: LinkTransport, didReceive data: Data) { lock.lock(); _received.append(data); lock.unlock() }
    func transportDidClose(_ transport: LinkTransport, reason: String?) {}
    func transport(_ transport: LinkTransport, didChangeStatus status: String) {}
}
