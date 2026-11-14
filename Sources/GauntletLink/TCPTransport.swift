import Foundation
import Network
import GauntletProtocol

/// Length-prefixed message framing over a TCP stream (u16 little-endian + payload).
final class FramedConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // Nothing is listening yet; give up on this attempt and let the owner retry.
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        guard !closed, data.count <= 0xFFFF else { return }
        var frame = Data([UInt8(data.count & 0xFF), UInt8(data.count >> 8)])
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func cancel() {
        finish(nil)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.finish(error?.localizedDescription)
            } else {
                self.receive()
            }
        }
    }

    private func drain() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(2))
            let length = Int(bytes[0]) | (Int(bytes[1]) << 8)
            guard buffer.count >= 2 + length else { break }
            let message = Data(buffer.dropFirst(2).prefix(length))
            buffer = Data(buffer.dropFirst(2 + length))
            onMessage?(message)
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason)
    }
}

/// Mac side of the developer link: listens on 127.0.0.1 only, one peer at a time.
/// Used by the watchOS Simulator build of the watch app and by `fakewatch`.
public final class TCPServerTransport: LinkTransport {
    public weak var delegate: LinkTransportDelegate?
    public let name = "Developer link"
    public let maxPayload = 512
    public private(set) var isOpen = false
    public var isLocalLoopback: Bool { true }

    private let port: UInt16
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var peer: FramedConnection?

    public init(port: UInt16 = Wire.devLinkPort, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    public func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to loopback explicitly: this link must never be reachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        guard let listener = try? NWListener(using: parameters) else {
            delegate?.transport(self, didChangeStatus: "Developer link could not start")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.listener?.cancel()
                self.listener = nil
                self.delegate?.transport(self, didChangeStatus: "Developer link port \(self.port) is busy")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        delegate?.transport(self, didChangeStatus: "Developer link ready on 127.0.0.1:\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        disconnectPeer()
    }

    public func send(_ data: Data, reliable: Bool) {
        guard isOpen else { return }
        peer?.send(data)
    }

    public func disconnectPeer() {
        peer?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard peer == nil else { connection.cancel(); return }
        let framed = FramedConnection(connection: connection, queue: queue)
        peer = framed
        framed.onReady = { [weak self] in
            guard let self else { return }
            self.isOpen = true
            self.delegate?.transportDidOpen(self)
        }
        framed.onMessage = { [weak self] data in
            guard let self else { return }
            self.delegate?.transport(self, didReceive: data)
        }
        framed.onClosed = { [weak self, weak framed] reason in
            guard let self, self.peer === framed else { return }
            self.peer = nil
            let wasOpen = self.isOpen
            self.isOpen = false
            if wasOpen { self.delegate?.transportDidClose(self, reason: reason) }
        }
        framed.start()
    }
}

/// Watch side of the developer link: connects to the Mac app on this machine and retries until it is up.
public final class TCPClientTransport: LinkTransport {
    public weak var delegate: LinkTransportDelegate?
    public let name = "Developer link"
    public let maxPayload = 512
    public private(set) var isOpen = false
    public var isLocalLoopback: Bool { true }

    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var connection: FramedConnection?
    private var running = false

    public init(host: String = "127.0.0.1", port: UInt16 = Wire.devLinkPort, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    public func start() {
        guard !running else { return }
        running = true
        delegate?.transport(self, didChangeStatus: "Looking for Gauntlet on this Mac…")
        connect()
    }

    public func stop() {
        running = false
        connection?.cancel()
    }

    public func send(_ data: Data, reliable: Bool) {
        guard isOpen else { return }
        connection?.send(data)
    }

    public func disconnectPeer() {
        connection?.cancel()
    }

    private func connect() {
        guard running, connection == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let framed = FramedConnection(
            connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp), queue: queue)
        connection = framed
        framed.onReady = { [weak self] in
            guard let self else { return }
            self.isOpen = true
            self.delegate?.transportDidOpen(self)
        }
        framed.onMessage = { [weak self] data in
            guard let self else { return }
            self.delegate?.transport(self, didReceive: data)
        }
        framed.onClosed = { [weak self, weak framed] reason in
            guard let self, self.connection === framed else { return }
            self.connection = nil
            let wasOpen = self.isOpen
            self.isOpen = false
            if wasOpen { self.delegate?.transportDidClose(self, reason: reason) }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
        }
        framed.start()
    }
}
