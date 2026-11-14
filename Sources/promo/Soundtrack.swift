import Foundation

/// The score, synthesised from scratch: a warm pad, a soft pulse, plucked arpeggios, and
/// sound design locked to the picture (pairing chime, clicks, whooshes, impacts on the cuts).
/// 120 BPM, so every cut in the film lands on a beat.
enum Soundtrack {
    static let rate = 48_000.0

    private struct Mix {
        var left: [Float], right: [Float], wetLeft: [Float], wetRight: [Float]
        let count: Int

        init(seconds: Double) {
            count = Int(seconds * Soundtrack.rate)
            left = [Float](repeating: 0, count: count)
            right = left; wetLeft = left; wetRight = left
        }

        /// Adds a mono voice lasting `length` seconds from `start`. `voice(time)` returns the sample;
        /// `pan` is -1 (left) ... 1 (right); `wet` sends a share to the echo.
        mutating func add(start: Double, length: Double, pan: Double = 0, wet: Double = 0, _ voice: (Double) -> Double) {
            let first = max(0, Int(start * Soundtrack.rate))
            let last = min(count, Int((start + length) * Soundtrack.rate))
            guard last > first else { return }
            let gainL = Float(cos((pan + 1) * .pi / 4)), gainR = Float(sin((pan + 1) * .pi / 4))
            for i in first..<last {
                let v = Float(voice(Double(i) / Soundtrack.rate - start))
                left[i] += v * gainL
                right[i] += v * gainR
                if wet > 0 {
                    wetLeft[i] += v * gainL * Float(wet)
                    wetRight[i] += v * gainR * Float(wet)
                }
            }
        }
    }

    private static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    /// D minor 9 - B flat major 7 - F major 9 - C 6/9, four seconds each.
    private static let chords: [(bass: Int, notes: [Int])] = [
        (38, [50, 53, 57, 60, 64]), (34, [46, 50, 53, 57, 62]), (41, [53, 57, 60, 64, 67]), (36, [48, 52, 55, 57, 62]),
    ]

    static func write(to path: String, from start: Double, to end: Double) {
        let duration = Director.duration
        var mix = Mix(seconds: duration)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func noise() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        let tau = 2 * Double.pi

        // How loud the bed is over the film: hushed open, lift for the watch, full for the gestures.
        func energy(_ t: Double) -> Double {
            keyed([(0, 0.45), (5, 0.6), (9, 0.85), (12, 0.9), (27, 1.0), (46.5, 0.8), (53, 0.9), (59, 1.0), (66, 1.0)], t)
        }

        // --- Pad ---
        let chordLength = 4.0
        for index in 0..<Int(ceil(duration / chordLength)) {
            let chord = chords[index % chords.count]
            let begin = Double(index) * chordLength
            for (n, note) in chord.notes.enumerated() {
                let f = hz(note)
                for side in [-1.0, 1.0] {
                    let detuned = f * (1 + side * 0.0016)
                    let phase = Double(n) * 1.3 + side
                    mix.add(start: begin - 0.4, length: chordLength + 2.0, pan: side * 0.75) { t in
                        let env = ease(prog(t, 0, 1.6)) * (1 - ease(prog(t, chordLength + 0.2, chordLength + 2.0)))
                        let tremolo = 1 + 0.14 * sin(tau * 0.21 * t + phase)
                        let tone = sin(tau * detuned * t) + 0.22 * sin(tau * 2 * detuned * t + phase) + 0.07 * sin(tau * 3 * detuned * t)
                        return 0.050 * env * tremolo * tone * energy(begin + t)
                    }
                }
            }
            // --- Bass, once the Mac is on stage ---
            if begin >= 12 {
                let f = hz(chord.bass)
                mix.add(start: begin, length: chordLength + 0.5) { t in
                    let env = ease(prog(t, 0, 0.25)) * (1 - ease(prog(t, chordLength - 0.1, chordLength + 0.5)))
                    let pump = 0.62 + 0.38 * prog((begin + t).truncatingRemainder(dividingBy: 1.0), 0, 0.35)   // ducks under each kick
                    return 0.095 * env * pump * (sin(tau * f * t) + 0.45 * sin(tau * 2 * f * t) + 0.12 * sin(tau * 3 * f * t)) * energy(begin + t)
                }
            }
        }

        // --- Kick: soft, half-time ---
        func kicks(from a: Double, to b: Double, every step: Double, gain: Double) {
            var t = a
            while t < b - 0.01 {
                mix.add(start: t, length: 0.5) { x in
                    let phase = tau * (45 * x + 75 * 0.035 * (1 - exp(-x / 0.035)))
                    return gain * (exp(-x / 0.15) * sin(phase) + 0.35 * exp(-x / 0.03) * sin(tau * 190 * x))
                }
                t += step
            }
        }
        kicks(from: 12, to: 27, every: 2, gain: 0.30)
        kicks(from: 27, to: 46.5, every: 1, gain: 0.42)
        kicks(from: 46.5, to: 53, every: 2, gain: 0.26)
        kicks(from: 53, to: 59, every: 1, gain: 0.38)
        kicks(from: 59, to: 64.2, every: 1, gain: 0.42)

        // --- Shaker on the off-beats ---
        func shakers(from a: Double, to b: Double) {
            var t = a + 0.5, flip = 1.0
            while t < b - 0.01 {
                var previous = 0.0
                mix.add(start: t, length: 0.09, pan: 0.35 * flip) { x in
                    let n = noise()
                    let high = n - previous            // crude high-pass keeps it airy
                    previous = n
                    return 0.035 * exp(-x / 0.022) * high
                }
                t += 1.0; flip = -flip
            }
        }
        shakers(from: 27, to: 46.5)
        shakers(from: 59, to: 64.2)

        // --- Plucked arpeggio ---
        let pattern = [0, 2, 4, 2, 1, 3, 4, 3]
        func arpeggio(from a: Double, to b: Double, gain: Double) {
            var t = a, step = 0
            while t < b - 0.01 {
                let chord = chords[Int(t / chordLength) % chords.count]
                let f = hz(chord.notes[pattern[step % pattern.count]] + 12)
                mix.add(start: t, length: 0.6, pan: step % 2 == 0 ? -0.5 : 0.5, wet: 0.55) { x in
                    gain * exp(-x / 0.16) * (sin(tau * f * x) + 0.3 * sin(tau * 2 * f * x)) * min(1, x / 0.004)
                }
                t += 0.25; step += 1
            }
        }
        arpeggio(from: 27, to: 46.5, gain: 0.075)
        arpeggio(from: 53, to: 59, gain: 0.05)
        arpeggio(from: 59, to: 64.0, gain: 0.075)

        // --- Risers into the cuts, impacts on them ---
        func riser(to moment: Double, length: Double = 1.5, gain: Double = 0.085) {
            var state = 0.0
            mix.add(start: moment - length, length: length) { x in
                let p = x / length
                state += (0.02 + 0.5 * p * p) * (noise() - state)        // low-pass that opens as it rises
                return gain * p * p * state * 3
            }
        }
        func impact(at moment: Double, gain: Double = 0.42) {
            var state = 0.0
            mix.add(start: moment, length: 2.2) { x in
                state += 0.08 * (noise() - state)
                return gain * exp(-x / 0.55) * sin(tau * 49 * x) + 0.5 * gain * exp(-x / 0.09) * state
            }
        }
        for cut in Director.cuts { riser(to: cut); impact(at: cut, gain: 0.26) }
        riser(to: 5.0, length: 2.0, gain: 0.05); impact(at: 5.0, gain: 0.26)
        riser(to: 9.0, length: 1.6); impact(at: 9.0, gain: 0.44)                    // "Gauntlet"
        riser(to: 59.9, length: 0.8, gain: 0.05); impact(at: 59.9, gain: 0.46)       // final title

        // --- Cold open: a low drone ---
        mix.add(start: 0, length: 6.5) { t in
            0.038 * ease(prog(t, 0, 3)) * (1 - ease(prog(t, 5, 6.5))) * (sin(tau * 36.71 * t) + 0.5 * sin(tau * 73.42 * t + 0.6))
        }

        // --- Pairing: rising blips, then a chime ---
        var blip = 20.6, blipIndex = 0
        while blip < 22.85 {
            let f = 660 * pow(2, (blip - 20.6) / 2.25)
            mix.add(start: blip, length: 0.3, pan: blipIndex % 2 == 0 ? 0.6 : -0.3, wet: 0.6) { x in
                0.05 * exp(-x / 0.06) * sin(tau * f * x) * min(1, x / 0.003)
            }
            blip += 0.25; blipIndex += 1
        }
        func bell(at moment: Double, _ f: Double, gain: Double, pan: Double) {
            mix.add(start: moment, length: 3.0, pan: pan, wet: 0.7) { x in
                gain * exp(-x / 0.75) * (sin(tau * f * x) + 0.35 * sin(tau * 2.01 * f * x) * exp(-x / 0.25)) * min(1, x / 0.003)
            }
        }
        bell(at: 23.0, 880.0, gain: 0.10, pan: -0.3)
        bell(at: 23.0, 1318.5, gain: 0.06, pan: 0.3)
        bell(at: 23.22, 1174.7, gain: 0.08, pan: 0.2)
        bell(at: 23.44, 1760.0, gain: 0.05, pan: -0.2)

        // --- Gesture sounds ---
        for tap in Director.taps {
            mix.add(start: tap, length: 0.25, wet: 0.3) { x in
                0.16 * exp(-x / 0.018) * sin(tau * 1900 * x) + 0.20 * exp(-x / 0.05) * sin(tau * 170 * x)
            }
        }
        for (moment, direction) in [(Director.flickOut, 1.0), (Director.grab, -1.0), (Director.drop, 1.0)] {
            var state = 0.0
            for side in [-1.0, 1.0] {
                mix.add(start: moment - 0.14, length: 0.36, pan: side * 0.8) { x in
                    let p = x / 0.36
                    state += (0.05 + 0.4 * sin(p * .pi)) * (noise() - state)
                    let sweep = 0.5 + 0.5 * side * direction * (2 * p - 1)      // travels across the stereo field
                    return 0.16 * sin(p * .pi) * state * sweep * 2
                }
            }
        }
        var tick = Director.scrollStart
        while tick < Director.scrollEnd {
            mix.add(start: tick, length: 0.05, pan: 0.4) { x in 0.05 * exp(-x / 0.006) * sin(tau * 2600 * x) }
            tick += 0.11
        }

        // --- Finale shimmer ---
        for (n, note) in [65, 69, 72, 76, 79].enumerated() {
            let f = hz(note + 12)
            mix.add(start: 59.9, length: 6.0, pan: Double(n - 2) * 0.35, wet: 0.5) { x in
                0.028 * ease(prog(x, 0, 0.8)) * (1 - ease(prog(x, 3.5, 6.0))) * sin(tau * f * x + Double(n)) * (1 + 0.2 * sin(tau * 0.4 * x))
            }
        }

        // --- Echo, master fades, soft limit ---
        let delay = Int(0.375 * rate)
        for i in delay..<mix.count {
            mix.wetLeft[i] += 0.42 * mix.wetRight[i - delay]       // ping-pong
            mix.wetRight[i] += 0.42 * mix.wetLeft[i - delay]
        }
        var peak: Float = 0
        for i in 0..<mix.count {
            let t = Double(i) / rate
            let fade = Float(ease(prog(t, 0, 0.25)) * (1 - ease(prog(t, 64.2, 65.9))))
            mix.left[i] = tanh((mix.left[i] + 0.6 * mix.wetLeft[i]) * 1.15) * fade
            mix.right[i] = tanh((mix.right[i] + 0.6 * mix.wetRight[i]) * 1.15) * fade
            peak = max(peak, abs(mix.left[i]), abs(mix.right[i]))
        }
        let normalise: Float = peak > 0 ? min(1.6, 0.89 / peak) : 1

        // --- 16-bit stereo WAV ---
        let first = max(0, Int(start * rate)), last = min(mix.count, Int(end * rate))
        let frames = max(0, last - first)
        var data = Data(capacity: 44 + frames * 4)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate) * 4); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
        for i in first..<last {
            append(Int16(max(-1, min(1, mix.left[i] * normalise)) * 32767))
            append(Int16(max(-1, min(1, mix.right[i] * normalise)) * 32767))
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
