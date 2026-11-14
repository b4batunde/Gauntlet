import Foundation
import CoreGraphics
import GauntletEngine
import GauntletProtocol

/// Headless checks of the Dojo's logic: the virtual watch drives a real engine through the
/// sandbox sink and the drills, on a simulated clock, with no window and nothing saved.
///
/// `dojopreview --selfcheck` runs these and exits non-zero if any fail.
public enum DojoSelfCheck {
    public struct Outcome {
        public let passed: Bool
        /// One line per check, then a summary.
        public let report: String
    }

    public static func run() -> Outcome {
        var log = Log()
        checkPointer(&log)
        checkTargetRush(&log)
        checkAxisDetection(startFlipped: true, &log)
        checkAxisDetection(startFlipped: false, &log)
        checkFullCalibration(&log)
        checkUnusableTaps(&log)
        checkDrills(&log)
        checkRendering(&log)
        checkLifecycle(&log)
        log.lines.append("\(log.count) checks, \(log.failures) failure\(log.failures == 1 ? "" : "s")")
        return Outcome(passed: log.failures == 0, report: log.lines.joined(separator: "\n"))
    }

    // MARK: Harness

    private struct Log {
        var lines: [String] = []
        var count = 0
        var failures = 0

        mutating func section(_ name: String) { lines.append("\n\(name)") }

        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if condition {
                lines.append("  ok   \(name)")
            } else {
                failures += 1
                let note = detail()
                lines.append("  FAIL \(name)\(note.isEmpty ? "" : " — \(note)")")
            }
        }
    }

    /// What the host callbacks saw.
    private final class Probe {
        var now = 100.0
        var haptics: [HapticPattern] = []
        var sinkInstalled: [Bool] = []
        var settingsSaved = 0
    }

    /// Engine + virtual watch + session, stepped one 20 ms packet at a time.
    private final class Bench {
        let engine = WristEngine()
        let watch = VirtualWatch(seed: 42)
        let probe = Probe()
        let session: DojoSession
        var controls = VirtualControls()
        private var pilot = Autopilot()

        init(mode: DojoMode) {
            let host = DojoHost(engine: engine)
            let probe = self.probe
            host.setSandboxSink = { [engine] sink in
                probe.sinkInstalled.append(sink != nil)
                engine.sink = sink
            }
            host.playHaptic = { probe.haptics.append($0) }
            host.settingsDidChange = { probe.settingsSaved += 1 }
            session = DojoSession(host: host, records: RecordStore(defaults: nil), mode: mode, seed: 7, clock: { probe.now })
            watch.snap(heading: 0, elevation: VirtualControls.neutralElevation)
            session.activate(now: probe.now)
        }

        /// Runs for `seconds` of simulated time, or until `done` says so. Returns false on timeout.
        @discardableResult
        func run(_ seconds: Double, autopilot: Bool = false, until done: (() -> Bool)? = nil) -> Bool {
            let dt = VirtualWatchDriver.packetInterval
            for _ in 0..<Int((seconds / dt).rounded()) {
                probe.now += dt
                if autopilot {
                    let context = session.context(now: probe.now)
                    pilot.step(dt: dt, hint: session.activity.autopilotHint(context),
                               context: Autopilot.Context(cursor: context.cursor, engaged: context.snapshot.engaged,
                                                          dragging: context.snapshot.dragging,
                                                          crownPixelsPerUnit: context.settings.crownScrollGain),
                               controls: &controls)
                }
                let discrete = controls.apply(to: watch)
                engine.ingest(watch.nextPacket(), now: probe.now)
                for message in discrete { engine.ingest(message, now: probe.now) }
                session.pump(now: probe.now)
                if let done, done() { return true }
            }
            return done == nil
        }

        func tap() {
            controls.tap = true
            run(0.4)
        }
    }

    // MARK: Checks

    private static func checkPointer(_ log: inout Log) {
        log.section("Sandbox pointer")
        let bench = Bench(mode: .freePlay)
        let sink = bench.session.sink
        bench.run(0.6)
        log.check("the session installs its sandbox sink", bench.probe.sinkInstalled == [true])
        log.check("the virtual watch engages the pointer", bench.engine.snapshot().engaged)

        let start = sink.cursor
        bench.controls.heading = -0.25
        bench.run(1.0)
        let swept = sink.cursor
        log.check("sweeping right moves the cursor right", swept.x > start.x + 150, "moved \(swept.x - start.x)")
        log.check("a level sweep stays level", abs(swept.y - start.y) < 0.2 * abs(swept.x - start.x), "dy \(swept.y - start.y)")

        bench.controls.elevation += 0.2
        bench.run(0.8)
        log.check("raising the arm moves the cursor up", sink.cursor.y < swept.y - 80, "dy \(sink.cursor.y - swept.y)")

        bench.controls.heading = -1.6
        bench.run(2.5)
        let pinned = sink.cursor
        // (Hand tremor may lift it a fraction of a point off the edge once the arm has stopped.)
        log.check("the cursor clamps at the right edge", pinned.x > DojoSession.screenSize.width - 3 && pinned.x <= DojoSession.screenSize.width - 1,
                  "x \(pinned.x)")
        log.check("the cursor stays on screen", (0..<DojoSession.screenSize.height).contains(pinned.y), "y \(pinned.y)")
        log.check("the engine asked for more travel than the screen has", sink.travel.x > Double(DojoSession.screenSize.width))
        let bumps = bench.probe.haptics.filter { $0 == .edge }.count
        log.check("pinning against an edge plays the edge haptic", bumps >= 1)
        log.check("the edge haptic is rate-limited", bumps <= 5, "\(bumps) in 2.5 s")
        log.check("the pinned edge is reported for the bezel glow", sink.pinnedEdges.contains(.right) || bumps >= 1)

        bench.controls.posture = .dropped
        bench.run(0.8)
        let resting = sink.cursor
        bench.controls.heading = 0
        bench.run(1.0)
        log.check("lowering the arm releases the pointer", !bench.engine.snapshot().engaged && sink.cursor == resting)
    }

    private static func checkTargetRush(_ log: inout Log) {
        log.section("Target Rush")
        let bench = Bench(mode: .targets)
        guard let drill = bench.session.activity as? TargetRushDrill else {
            log.check("Target Rush is the active drill", false)
            return
        }
        let sink = bench.session.sink
        bench.run(0.6)

        sink.warp(to: CGPoint(x: 120, y: 900))
        bench.tap()
        log.check("a tap away from START does not start the run", drill.phase == .ready)
        sink.warp(to: TargetRushDrill.startCenter)
        bench.tap()
        log.check("a tap on START starts the run", drill.phase == .running && drill.target != nil)

        if let target = drill.target {
            sink.warp(to: target.center)
            bench.tap()
            log.check("a tap over a target registers a hit", drill.hits == 1 && drill.misses == 0, "hits \(drill.hits), misses \(drill.misses)")
        }
        if let target = drill.target {
            sink.warp(to: CGPoint(x: target.center.x < 800 ? 1500 : 100, y: target.center.y < 500 ? 900 : 200))
            bench.tap()
            log.check("a tap off the target registers a miss", drill.hits == 1 && drill.misses == 1, "hits \(drill.hits), misses \(drill.misses)")
            log.check("a miss plays the failure haptic", bench.probe.haptics.contains(.failure))
        }

        // The rest of the run is played for real: steer the arm to each target, settle, tap.
        let finished = bench.run(90, autopilot: true) { drill.phase == .finished }
        log.check("steering the arm onto each target completes the run", finished, "hits \(drill.hits)")
        log.check("every target was hit", drill.hits == TargetRushDrill.targetCount)
        let throughput = drill.summary?.throughput ?? 0
        log.check("throughput is plausible", throughput > 0.3 && throughput < 12, String(format: "%.2f bits/s", throughput))
        log.check("the run is stored as a personal best", bench.session.records.best(for: .targets)?.score == drill.summary?.throughput)
    }

    private static func checkAxisDetection(startFlipped: Bool, _ log: inout Log) {
        log.section(startFlipped ? "Calibration: forearm axis guessed backwards" : "Calibration: forearm axis guessed correctly")
        let bench = Bench(mode: .calibration)
        guard let activity = bench.session.activity as? CalibrationActivity else {
            log.check("calibration is active", false)
            return
        }
        let wizard = activity.wizard
        bench.engine.updateSettings { $0.forearmAxisFlipped = startFlipped }

        bench.run(2.6)
        log.check("holding still completes step 1", wizard.step == .raise, "step \(wizard.step)")
        let measured = wizard.report.restElevationDeg ?? 0
        let expected = degrees(VirtualControls.neutralElevation) * (startFlipped ? -1 : 1)
        log.check("the resting elevation is recorded as measured", abs(measured - expected) < 3, String(format: "%.1f°", measured))
        if startFlipped {
            log.check("a backwards axis keeps the pointer released", !bench.engine.snapshot().engaged)
        }

        bench.controls.posture = .raised
        bench.run(1.6)
        log.check(startFlipped ? "raising the arm makes the wizard flip the axis back" : "raising the arm leaves a correct axis alone",
                  bench.engine.currentSettings.forearmAxisFlipped == false)
        log.check("the report says what happened", wizard.report.axisCorrected == startFlipped)
        log.check("the resting elevation now reads above horizontal", (wizard.report.restElevationDeg ?? -90) > 15)

        bench.controls.posture = .pointing
        bench.run(1.6)
        log.check("lowering the arm moves on to the sweep", wizard.step == .sweepHorizontal, "step \(wizard.step)")
        log.check("the pointer is engaged afterwards", bench.engine.snapshot().engaged)
    }

    private static func checkFullCalibration(_ log: inout Log) {
        log.section("Calibration: whole wizard")
        let bench = Bench(mode: .calibration)
        guard let activity = bench.session.activity as? CalibrationActivity else {
            log.check("calibration is active", false)
            return
        }
        let wizard = activity.wizard
        let before = bench.engine.currentSettings
        let finished = bench.run(120, autopilot: true) { wizard.step == .done }
        log.check("performing every step completes the wizard", finished, "stopped at \(wizard.step)")
        let settings = bench.engine.currentSettings
        let report = wizard.report
        log.check("no step was skipped", wizard.skipped.isEmpty)
        log.check("calibrated is set", settings.calibrated)
        log.check("the host is told to persist exactly once", bench.probe.settingsSaved == 1, "\(bench.probe.settingsSaved)")
        log.check("the axis is left alone", !settings.forearmAxisFlipped && report.axisCorrected == false)

        // The sweep should now span about one screen width.
        let range = radians(report.headingRangeDeg ?? 0)
        log.check("the sweep was measured", range > 0.5 && range < 0.8, String(format: "%.2f rad", range))
        log.check("sensitivity changed and is in range", settings.sensitivity != before.sensitivity && (0.3...4).contains(settings.sensitivity),
                  String(format: "%.2f", settings.sensitivity))
        log.check("the vertical sweep was measured", (report.verticalRangeDeg ?? 0) > 15)

        log.check("eight taps were collected", wizard.tapPeaks.count == CalibrationWizard.Tuning.tapsWanted)
        log.check("taps separate cleanly from movement", report.tapUsable == true && (report.tapSeparation ?? 0) > 1.5,
                  String(format: "%.1f×", report.tapSeparation ?? 0))
        log.check("the tap threshold sits below the taps", settings.gestures.tapEnabled
                  && settings.gestures.tapThreshold < (wizard.tapPeaks.min() ?? 0) && settings.gestures.tapThreshold >= 0.06,
                  String(format: "%.3f g", settings.gestures.tapThreshold))
        let flick = settings.gestures.flickRate
        log.check("flicks both ways were collected", wizard.flicksOut.count >= 3 && wizard.flicksIn.count >= 3,
                  "out \(wizard.flicksOut.count), in \(wizard.flicksIn.count)")
        log.check("the flick rate is 60% of the median, within 3...9", report.flickRate == flick && (3...9).contains(flick),
                  String(format: "%.2f rad/s", flick))

        // The calibrated settings must still work.
        bench.session.setMode(.simon, now: bench.probe.now)
        if let simon = bench.session.activity as? GestureSimonDrill {
            let played = bench.run(90, autopilot: true) { if case .finished = simon.phase { return true } else { return false } }
            log.check("gestures are still recognised with the calibrated settings", played && simon.accuracy == 1,
                      String(format: "%.0f%%", simon.accuracy * 100))
        }
    }

    private static func checkUnusableTaps(_ log: inout Log) {
        log.section("Calibration: taps that cannot be told from movement")
        let bench = Bench(mode: .calibration)
        guard let activity = bench.session.activity as? CalibrationActivity else {
            log.check("calibration is active", false)
            return
        }
        let wizard = activity.wizard
        bench.run(0.5)
        for _ in 0..<4 { bench.session.perform(.skip, now: bench.probe.now) }
        log.check("skipping reaches the tap step", wizard.step == .taps, "step \(wizard.step)")
        log.check("skipped steps are remembered", wizard.skipped.count == 4)

        // Feeble taps, then movement that is just as loud.
        for _ in 0..<CalibrationWizard.Tuning.tapsWanted {
            bench.run(0.3)
            wizard.handle(.tapCandidate(TapCandidate(time: bench.probe.now, peak: 0.07, background: 0.02, gyro: 0.2, accepted: false)),
                          now: bench.probe.now)
        }
        log.check("eight taps move on to the movement step", wizard.step == .quiet, "step \(wizard.step)")
        for peak in [0.08, 0.09, 0.07, 0.10] {
            wizard.handle(.tapCandidate(TapCandidate(time: bench.probe.now, peak: peak, background: 0.03, gyro: 1.5, accepted: false)),
                          now: bench.probe.now)
        }
        bench.run(12, autopilot: true) { wizard.step == .flicks }
        log.check("the wizard reports the taps as not usable", wizard.report.tapUsable == false,
                  String(format: "separation %.2f", wizard.report.tapSeparation ?? -1))
        log.check("finger-tap clicking is switched off", !bench.engine.currentSettings.gestures.tapEnabled)
        let status = activity.status(bench.session.context(now: bench.probe.now))
        log.check("the HUD says so and suggests an alternative", status.note?.contains("wrist flick") == true)

        // Walking away mid-step must not leave the listening threshold behind.
        let listening = bench.engine.currentSettings.gestures.flickRate
        bench.session.setMode(.freePlay, now: bench.probe.now)
        log.check("leaving during the flick step restores the flick threshold",
                  listening == CalibrationWizard.Tuning.listeningFlickRate && bench.engine.currentSettings.gestures.flickRate == 5.0,
                  "listening \(listening), after \(bench.engine.currentSettings.gestures.flickRate)")
        log.check("partial changes are still handed to the host", bench.probe.settingsSaved == 1)
    }

    private static func checkDrills(_ log: inout Log) {
        log.section("Drills played by the autopilot")

        let drag = Bench(mode: .drag)
        if let drill = drag.session.activity as? DragDropDrill {
            let finished = drag.run(120, autopilot: true) { drill.phase == .finished }
            log.check("Drag & Drop: every token is carried to its zone", finished && drill.placedCount == drill.tokens.count,
                      "placed \(drill.placedCount)")
            log.check("Drag & Drop: no wrong drops, time recorded", drill.errors == 0
                      && drag.session.records.best(for: .drag)?.score == drill.elapsed, "errors \(drill.errors)")
            log.check("Drag & Drop: nothing is left held", !drag.engine.snapshot().dragging)
        }

        let scroll = Bench(mode: .scroll)
        if let drill = scroll.session.activity as? ScrollSeekerDrill {
            let finished = scroll.run(90, autopilot: true) { drill.phase == .finished }
            log.check("Scroll Seeker: the crown brings every target into the band", finished && drill.round == ScrollSeekerDrill.rounds,
                      "round \(drill.round)")
            log.check("Scroll Seeker: mean seek time recorded", drill.meanTime > 0.2 && scroll.session.records.history(for: .scroll).count == 1,
                      String(format: "%.2f s", drill.meanTime))
        }

        let simon = Bench(mode: .simon)
        if let drill = simon.session.activity as? GestureSimonDrill {
            let finished = simon.run(120, autopilot: true) { if case .finished = drill.phase { return true } else { return false } }
            log.check("Gesture Simon: all prompts answered", finished && drill.outcomes.count == GestureSimonDrill.promptCount)
            log.check("Gesture Simon: every gesture recognised correctly", drill.accuracy == 1 && drill.falseStarts == 0,
                      String(format: "%.0f%%, %d early", drill.accuracy * 100, drill.falseStarts))
            log.check("Gesture Simon: reaction time measured", drill.meanReaction > 0.2 && drill.meanReaction < 2,
                      String(format: "%.0f ms", drill.meanReaction * 1000))
        }

        let free = Bench(mode: .freePlay)
        free.run(40, autopilot: true)
        let status = free.session.activity.status(free.session.context(now: free.probe.now))
        let counts = Dictionary(uniqueKeysWithValues: status.metrics.map { ($0.label, $0.value) })
        log.check("Free Play: click, right-click and double-click each reach their button",
                  counts["Clicks"] != "0" && counts["Right-clicks"] != "0" && counts["Double-clicks"] != "0", "\(counts)")
        log.check("Free Play: the puck is dragged into the dock", counts["Docked"] != "0", "\(counts)")
        log.check("Free Play: the list scrolls", counts["Scrolled"] != "0 px", "\(counts)")
    }

    private static func checkRendering(_ log: inout Log) {
        log.section("Screen rendering")
        let renderer = ScreenRenderer(size: DojoSession.screenSize)
        for mode in DojoMode.allCases {
            let bench = Bench(mode: mode)
            bench.run(1.0, autopilot: true)
            let image = renderer.render(bench.session.activity, bench.session.context(now: bench.probe.now))
            log.check("\(mode.title) draws a \(Int(DojoSession.screenSize.width))×\(Int(DojoSession.screenSize.height)) frame",
                      image?.width == Int(DojoSession.screenSize.width) && image?.height == Int(DojoSession.screenSize.height))
        }
    }

    private static func checkLifecycle(_ log: inout Log) {
        log.section("Sandbox hand-over")
        let bench = Bench(mode: .drag)
        let grabbed = bench.run(20, autopilot: true) { bench.engine.snapshot().dragging }
        log.check("a token can be grabbed", grabbed)
        bench.session.setMode(.live, now: bench.probe.now)
        log.check("switching mode mid-drag releases the button", !bench.engine.snapshot().dragging)
        log.check("Live mode hands output back to the host", bench.probe.sinkInstalled == [true, false])
        bench.session.setMode(.targets, now: bench.probe.now)
        log.check("returning to a drill takes it again", bench.probe.sinkInstalled == [true, false, true])

        // A stalled stream must not upset anything.
        bench.probe.now += 2
        bench.engine.tick(now: bench.probe.now)
        bench.session.pump(now: bench.probe.now)
        log.check("a stalled stream is survived", !bench.engine.snapshot().streaming)
        bench.run(0.6)
        log.check("and the pointer re-engages when data returns", bench.engine.snapshot().engaged)

        bench.session.deactivate(now: bench.probe.now)
        log.check("closing the Dojo always hands output back", bench.probe.sinkInstalled == [true, false, true, false])
    }
}
