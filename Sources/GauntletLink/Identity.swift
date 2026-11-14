import Foundation
import CryptoKit
import GauntletProtocol

/// Long-term identity of one end of the link: a random ID and a Curve25519 key pair.
public struct LinkIdentity {
    public let deviceID: Data
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init() {
        deviceID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    init?(serialized: Data) {
        guard serialized.count == 48,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serialized.suffix(32)) else { return nil }
        deviceID = Data(serialized.prefix(16))
        privateKey = key
    }

    var serialized: Data { deviceID + privateKey.rawRepresentation }

    /// Loads the identity from `defaults`, creating and saving one on first use.
    public static func loadOrCreate(defaults: UserDefaults = .standard, key: String = "gauntlet.identity") -> LinkIdentity {
        if let data = defaults.data(forKey: key), let identity = LinkIdentity(serialized: data) { return identity }
        let identity = LinkIdentity()
        defaults.set(identity.serialized, forKey: key)
        return identity
    }
}

enum LinkCrypto {
    /// Both ends derive the same key from their own private key and the other's public key.
    /// A man in the middle ends up with different keys on each side, which the pairing code exposes.
    static func pairingKey(identity: LinkIdentity, peerPublicKey: Data, watchID: Data, macID: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data("gauntlet-link-v1".utf8),
                                              sharedInfo: watchID + macID,
                                              outputByteCount: 32)
    }

    static func proof(_ role: String, key: SymmetricKey, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + nonce, using: key))
    }

    static func verify(_ proof: Data, role: String, key: SymmetricKey, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(role.utf8) + nonce, using: key)
    }

    /// Six digits shown on both screens during first pairing.
    static func pairingCode(key: SymmetricKey) -> String {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("pairing-code".utf8), using: key))
        let value = mac.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06d", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    static func nonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }
}

/// A watch the Mac has agreed to take input from.
public struct TrustedWatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String              // hex device ID
    public var publicKey: Data
    public var name: String
    public var pairedAt: Date
}

/// The Mac's list of paired watches, persisted as JSON.
public final class TrustStore {
    private let url: URL?
    private var watches: [TrustedWatch] = []
    private let lock = NSLock()

    /// Pass nil for an in-memory store (tests).
    public init(fileURL: URL?) {
        url = fileURL
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([TrustedWatch].self, from: data) {
            watches = saved
        }
    }

    public var all: [TrustedWatch] {
        lock.lock(); defer { lock.unlock() }
        return watches
    }

    public func isTrusted(deviceID: Data, publicKey: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return watches.contains { $0.id == deviceID.hexString && $0.publicKey == publicKey }
    }

    public func trust(deviceID: Data, publicKey: Data, name: String) {
        lock.lock()
        watches.removeAll { $0.id == deviceID.hexString }
        watches.append(TrustedWatch(id: deviceID.hexString, publicKey: publicKey, name: name, pairedAt: Date()))
        lock.unlock()
        save()
    }

    public func forget(id: String) {
        lock.lock()
        watches.removeAll { $0.id == id }
        lock.unlock()
        save()
    }

    private func save() {
        guard let url else { return }
        lock.lock()
        let snapshot = watches
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
