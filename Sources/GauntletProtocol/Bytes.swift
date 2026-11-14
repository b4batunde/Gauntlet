import Foundation

public enum WireError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
    case malformed(String)
}

/// Little-endian byte writer.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    var data: Data { Data(bytes) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }
    mutating func raw(_ d: Data) { bytes.append(contentsOf: d) }

    /// Length-prefixed UTF-8 string, truncated to `maxBytes`.
    mutating func string(_ s: String, maxBytes: Int = 40) {
        var utf8 = Array(s.utf8)
        if utf8.count > maxBytes {
            utf8 = Array(utf8.prefix(maxBytes))
            // Never cut a multi-byte scalar in half.
            while String(bytes: utf8, encoding: .utf8) == nil, !utf8.isEmpty { utf8.removeLast() }
        }
        u8(UInt8(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    /// Quantise a real value to a signed 16-bit integer with saturation.
    mutating func q16(_ value: Double, scale: Double) {
        let scaled = (value * scale).rounded()
        let clamped = scaled.isFinite ? max(-32767, min(32767, scaled)) : 0
        i16(Int16(clamped))
    }
}

/// Little-endian byte reader that throws instead of trapping on short input.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw WireError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw WireError.truncated }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << UInt32(8 * i) }
        return v
    }
    mutating func raw(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }
    mutating func string() throws -> String {
        let n = Int(try u8())
        let d = try raw(n)
        return String(decoding: d, as: UTF8.self)
    }
    mutating func q16(scale: Double) throws -> Double { Double(try i16()) / scale }
}
