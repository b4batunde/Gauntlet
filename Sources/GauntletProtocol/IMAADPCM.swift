import Foundation

/// IMA ADPCM, 4 bits per sample: 16 kHz mono speech in 64 kbps, small enough to share the
/// Bluetooth link with the motion stream.
///
/// Every block carries the coder state it starts from (predictor + step index), so a lost
/// block costs only its own 20 ms and the next one decodes cleanly.
///
/// Block layout: `predictor: Int16 LE`, `stepIndex: UInt8`, then the samples packed two per byte,
/// low nibble first. An odd final sample leaves the high nibble of the last byte unused.
public enum IMAADPCM {
    public static let headerSize = 3

    /// Encoder state carried from one block to the next (better quality than restarting at zero).
    public struct State: Equatable, Sendable {
        public var predictor: Int32 = 0
        public var stepIndex: Int32 = 0
        public init() {}
    }

    /// Bytes needed for a block of `samples` samples.
    public static func blockSize(samples: Int) -> Int { headerSize + (samples + 1) / 2 }

    /// Largest even sample count whose block fits in `bytes`.
    public static func samplesThatFit(bytes: Int) -> Int { max(0, (bytes - headerSize) * 2) }

    public static func encodeBlock(_ samples: [Int16], state: inout State) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(blockSize(samples: samples.count))
        let p = UInt16(bitPattern: Int16(clamping: state.predictor))
        out.append(UInt8(truncatingIfNeeded: p))
        out.append(UInt8(truncatingIfNeeded: p >> 8))
        out.append(UInt8(truncatingIfNeeded: state.stepIndex))

        var pending: UInt8 = 0
        var havePending = false
        for sample in samples {
            let nibble = encodeSample(Int32(sample), state: &state)
            if havePending {
                out.append(pending | (nibble << 4))
                havePending = false
            } else {
                pending = nibble
                havePending = true
            }
        }
        if havePending { out.append(pending) }
        return Data(out)
    }

    /// Decodes one block. `count` limits the output (the last byte may hold a single sample);
    /// by default every nibble is decoded.
    public static func decodeBlock(_ block: Data, count: Int? = nil) throws -> [Int16] {
        let bytes = [UInt8](block)
        guard bytes.count >= headerSize else { throw WireError.truncated }
        var state = State()
        state.predictor = Int32(Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)))
        state.stepIndex = Int32(min(88, bytes[2]))
        let available = (bytes.count - headerSize) * 2
        let n = min(available, count ?? available)
        var out = [Int16]()
        out.reserveCapacity(n)
        var i = 0
        while out.count < n {
            let byte = bytes[headerSize + i / 2]
            let nibble = (i % 2 == 0) ? (byte & 0x0F) : (byte >> 4)
            out.append(decodeSample(nibble, state: &state))
            i += 1
        }
        return out
    }

    // MARK: Codec core

    private static let indexTable: [Int32] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    private static func encodeSample(_ sample: Int32, state: inout State) -> UInt8 {
        var step = stepTable[Int(state.stepIndex)]
        var diff = sample - state.predictor
        var nibble: UInt8 = 0
        if diff < 0 { nibble = 8; diff = -diff }
        // Mirror the decoder's reconstruction exactly so both sides track the same predictor.
        var delta = step >> 3
        if diff >= step { nibble |= 4; diff -= step; delta += step }
        step >>= 1
        if diff >= step { nibble |= 2; diff -= step; delta += step }
        step >>= 1
        if diff >= step { nibble |= 1; delta += step }
        state.predictor += (nibble & 8) != 0 ? -delta : delta
        state.predictor = max(-32768, min(32767, state.predictor))
        state.stepIndex = max(0, min(88, state.stepIndex + indexTable[Int(nibble)]))
        return nibble
    }

    private static func decodeSample(_ nibble: UInt8, state: inout State) -> Int16 {
        let step = stepTable[Int(state.stepIndex)]
        var delta = step >> 3
        if nibble & 4 != 0 { delta += step }
        if nibble & 2 != 0 { delta += step >> 1 }
        if nibble & 1 != 0 { delta += step >> 2 }
        state.predictor += (nibble & 8) != 0 ? -delta : delta
        state.predictor = max(-32768, min(32767, state.predictor))
        state.stepIndex = max(0, min(88, state.stepIndex + indexTable[Int(nibble & 0x0F)]))
        return Int16(state.predictor)
    }
}
