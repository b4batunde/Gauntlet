# Gauntlet — your Apple Watch is the mouse

Lift your arm toward the screen and point. The cursor follows your forearm; a finger tap clicks; a flick of the wrist right-clicks. No mouse, no trackpad, nothing in your hand.

| You do this | The Mac does this |
|---|---|
| Lift your forearm toward the screen | Pointer engages (lower it to the keyboard to release) |
| Swing your forearm left / right / up / down | Pointer moves — slow for precision, fast to cross the screen |
| Tap thumb and index finger together | Click (two taps = double-click) |
| Quick wrist twist outward and back | Right-click |
| Quick wrist twist inward and back | Grab / release (drag) |
| Turn the Digital Crown | Scroll |
| Drag a finger on the watch face | Fine pointer movement (tap = click, long-press = right-click) |
| Watch "Double Tap" pinch (display awake) | Click |
| Type on the keyboard | Pointer holds still while keys are going down |

Every gesture can be rebound in **Gestures**, and the feel tuned in **Settings**. The watch buzzes for clicks, drags and engage/release so you can work without looking at it.

## What is and is not verified

Tested on this Mac:

- **Motion engine, gestures, wire protocol, pairing** — 32 automated checks (`swift run selftest`), driven by a physically modelled virtual watch, including packet loss and stalled links.
- **Mac app** — run end to end against a simulated watch over the developer link: pairing, 50 packets/s streaming, taps, double-tap, flicks, drag, scroll, haptic replies.
- **3D Dojo** — 83 headless checks (`swift run dojopreview --selfcheck`); every mode rendered and inspected.
- **Watch app** — compiles with Xcode 27.2 for watchOS 27.2 with no errors, and runs in the Apple Watch Series 12 simulator, where it connects to the Mac app and streams.

Not yet verified:

- **A physical watch.** Bluetooth between a real watch and the Mac, the real motion sensors, HealthKit keep-alive, haptics and the Digital Crown have only run in code review and the simulator.
- **Moving the real cursor** needs the Accessibility permission, which only you can grant. Use *Settings › Advanced › Test pointer* afterwards.
- **Real-wrist tuning.** Thresholds come from a simulation. The Dojo's calibration fits them to your arm — run it first.

## 1. Run the Mac app (works today)

```bash
Scripts/build-app.sh
```

```bash
open ~/Applications/Gauntlet.app
```

On first launch:

1. **Bluetooth** — allow it when macOS asks.
2. **Accessibility** — click *Open Settings* on the yellow card and switch Gauntlet on under *Privacy & Security › Accessibility*. Without it everything works inside the Dojo sandbox, but the real pointer will not move.

The app is ad-hoc signed. macOS ties the Accessibility permission to the signature, so **after every rebuild** remove Gauntlet from the Accessibility list and add it again.

## 2. Try it right now, without a watch

**In the Dojo.** Open the *Dojo* page. With no watch connected it switches to a built-in virtual watch you steer with the mouse, so you can learn the gestures and play the drills immediately. Nothing in the Dojo touches your real cursor.

**With the simulated watch.** This drives the whole pipeline — pairing, streaming, gesture recognition — exactly as a real watch would:

1. In Gauntlet: *Settings › Advanced › Developer link* on.
2. In a terminal:

```bash
swift run fakewatch
```

That only points. `swift run fakewatch --demo` also taps, flicks, drags and scrolls — if Gauntlet has the Accessibility permission, **it will really click on your desktop**, so open the Dojo first (sandbox) or be ready for it.

## 3. Put it on your Apple Watch

You need **Xcode** (free, Mac App Store) and a free Apple ID.

1. Install Xcode, open it once, and let it install the watchOS platform.
2. Open `WatchApp/Gauntlet.xcodeproj`.
3. Select the *Gauntlet Watch App* target › *Signing & Capabilities* › choose your **Team**. If the bundle identifier is taken, change `dev.sunhacks.gauntlet.watch` to something unique.
4. On the watch: *Settings › Privacy & Security › Developer Mode* → on (the option appears after the watch has been connected to Xcode once; the watch restarts).
5. Pick your Apple Watch as the run destination and press **Run**.

See `WatchApp/README.md` for watch-specific notes and troubleshooting.

## 4. First connection

1. Start Gauntlet on the Mac, then on the watch.
2. The first time, both screens show the same **6-digit pairing code**. Check they match, then click *Pair* on the Mac. After that the watch reconnects on its own.
3. Open the **Dojo** and run **Calibration** (about two minutes). It learns which way round you wear the watch, how far you like to swing your arm, and how hard you tap. Until you do, "up" may be inverted — the wearing direction is the one thing that cannot be known in advance.
4. Practise in the Dojo's drills, then close it and use your Mac.

## How it works

```
 Apple Watch                                            Mac
┌──────────────────────────┐    Bluetooth LE     ┌─────────────────────────────────┐
│ gyroscope + accelerometer│  (watch = central)  │ LinkServer  pairing, heartbeat  │
│ sensor fusion (100 Hz)   │ ──────────────────▶ │ WristEngine pointing frame,     │
│ Digital Crown · touch    │   50 packets/s      │   adaptive filter, tap + flick  │
│ heart rate · battery     │                     │   detectors, clutch             │
│ Taptic Engine            │ ◀────────────────── │ SystemPointerSink → real cursor │
└──────────────────────────┘  haptics, state     │ Dojo sink → virtual 3D screen   │
                                                 └─────────────────────────────────┘
```

- **Pointing.** The gyroscope gives angular velocity; gravity from the watch's sensor fusion gives "up". Together they define a frame fixed to your forearm, so twisting your wrist does not move the pointer and the mapping is right whichever wrist and crown orientation you use. Movement is relative (like a mouse), so there is no drift to correct.
- **Steadiness.** A speed-adaptive low-pass removes hand tremor when you slow down and gets out of the way when you sweep. Gain rises with speed: fine control at rest, whole-screen sweeps when fast.
- **Clicks.** A finger tap sends a sharp, short jolt up the wrist. The detector high-passes the accelerometer, compares the spike with the recent background, and requires it to die away quickly. The click is placed where you were aiming *before* the jolt.
- **Staying alive.** The watch runs a workout session (discarded, never saved to Health) so it keeps streaming when your wrist drops and the display dims. That also provides live heart rate.
- **Latency.** Sensor packets go straight from the Bluetooth queue into the engine and out to the cursor without touching the UI thread.

## Security

Anything that can move your mouse is worth protecting.

- A watch must be **approved once on the Mac** by comparing the pairing code. Each side holds a Curve25519 key; the code is derived from the shared secret, so someone in the middle would produce mismatched codes.
- Every later session starts with a challenge the watch can only answer with its paired key. Input is ignored until that succeeds, and a copied device ID with a different key is rejected.
- The link is authenticated but **not encrypted**: motion data could be observed by a nearby radio. No keystrokes or screen contents ever travel over it.
- The **developer link** accepts a simulated watch without approval, from this Mac only (127.0.0.1). It is off by default; leave it off for normal use.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Pointer does not move, Dojo works | Accessibility permission missing or stale. Remove and re-add Gauntlet in *Privacy & Security › Accessibility*, relaunch, then *Settings › Advanced › Test pointer*. |
| Up and down are swapped, or the pointer only engages with the arm lowered | Run Dojo calibration, or toggle *Settings › Watch › Watch is worn the other way round*. |
| Accidental clicks | Raise *Gestures › Tap strength needed*, or re-run tap calibration. If taps and movement cannot be separated on your wrist, bind clicking to the wrist flick or the watch face instead. |
| Taps are missed | Lower *Tap strength needed*. A firm thumb-to-index tap works better than a soft pinch. |
| Pointer wanders while typing | Keep *Raise to point* on and *Hold the pointer still while typing* on. |
| Watch never connects | Bluetooth on at both ends; Gauntlet open on both; watch within a few metres. On the watch's status page, *Forget this Mac* and reconnect. |
| Pointer feels laggy | Check *Packets/s* (should be ~50) and *Loss* on the Control page. Move closer; other Bluetooth traffic can crowd the link. |

## Project layout

```
Package.swift                 Swift package: everything except the watch-only UI
Sources/
  GauntletProtocol/           wire format (shared)
  GauntletLink/               pairing, heartbeat, Bluetooth + TCP transports (shared)
  GauntletWatchCore/          watch-side session logic (shared, tested on the Mac)
  GauntletEngine/             pointing maths, gesture detectors, virtual watch
  GauntletDojo/               3D training environment
  GauntletMac/                Mac app: cursor control, Bluetooth host, UI
  GauntletApp/                Mac app entry point
  fakewatch/                  simulated watch (command line)
  dojopreview/                the Dojo on its own
  selftest/                   test suite that runs without Xcode
WatchApp/                     Xcode project + watch-only sources
Scripts/build-app.sh          builds dist/Gauntlet.app
```

```bash
swift run selftest
```

## Showcase film

`showcase/Gauntlet-TeamGestures.mp4` is a 66-second product film (1080p, 60 fps, with soundtrack) generated entirely by code in `Sources/promo`: the 3D watch and Mac are modelled procedurally, the Mac's display shows real screenshots of the app and Dojo from `showcase/assets`, and the score is synthesised.

```bash
swift run -c release promo
```

Useful options: `--stills 8,21,33 --dir out` renders single frames, `--from 27 --to 47 --out part.mp4` renders part of the timeline, `--no-audio` leaves the soundtrack off, `--size 3840x2160` renders in 4K. Titles and timing live in `Sources/promo/Director.swift`.
