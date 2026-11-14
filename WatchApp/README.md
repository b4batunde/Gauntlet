# Gauntlet for Apple Watch

The watch half of Gauntlet: it streams wrist motion, touches and Digital Crown turns to the
Gauntlet app on your Mac over Bluetooth LE, and plays the haptics the Mac sends back.

It is a single-target, watch-only SwiftUI app. Almost all of its logic lives in the Swift
package in the repository root (`GauntletProtocol`, `GauntletLink`, `GauntletWatchCore`,
`GauntletEngine`); this folder adds the UI and the sensor glue.

```
WatchApp/
  Gauntlet.xcodeproj     open this
  GauntletWatch/         sources (Core = logic, Views = SwiftUI, Watch = watchOS-only code)
  Config/                Info.plist and entitlements
  project.yml            XcodeGen spec, only for regenerating the project
  tools/                 checks that run without Xcode
```

## Prerequisites

- Xcode 16 or later with the watchOS platform installed (Xcode > Settings > Components).
- Apple Watch Series 9 / Ultra 2 or newer on watchOS 11 or later, paired with an iPhone.
- Developer Mode on the watch: Settings > Privacy & Security > Developer Mode, then restart.
  (The switch appears after the watch has been seen by Xcode once: connect the iPhone to the
  Mac, open Window > Devices and Simulators and wait for the watch to show up.)
- An Apple ID added in Xcode > Settings > Accounts. A free personal team is enough.

## Run on your watch

1. Open `WatchApp/Gauntlet.xcodeproj` and let Xcode resolve the local package.
2. Select the project, then the target **Gauntlet Watch App** > Signing & Capabilities, and
   choose your **Team**. If Xcode says the bundle identifier is taken, change it to something
   unique, e.g. `dev.sunhacks.gauntlet.watch.<yourname>`.
3. Pick the scheme **Gauntlet Watch App** and your watch as the destination, then Run.
   The first install can take a few minutes; keep the watch unlocked and near the iPhone.
4. On the watch, allow Bluetooth, then allow Health access (Workouts and Heart Rate).
5. Start the Gauntlet app on the Mac. The first time, the watch shows a six-digit code:
   confirm the same code on the Mac. After that it reconnects by itself.

Raise your forearm to point; the ring turns cyan while the pointer follows your arm.
The watch face is a small trackpad (drag, tap to click, hold to right-click), the Digital
Crown scrolls, and the bottom buttons open Actions and Status.

## Run in the simulator

The simulator has no motion sensors and no Bluetooth link to your Mac, so simulator builds
connect to the Mac app's developer link on `127.0.0.1` and stream a synthetic arm that
slowly draws a figure of eight.

1. Start the Gauntlet Mac app on the same Mac and turn on **Settings › Advanced › Developer
   link** (off by default; it then listens on TCP port 47231, loopback only).
2. Choose any Apple Watch simulator as the destination and Run.

No pairing code is needed on the developer link. HealthKit and keep-alive are skipped.

## Good to know

- **No app icon.** There is deliberately no asset catalog, so nothing needs the asset
  compiler; the app shows a blank placeholder icon. To add one, create an Assets catalog
  inside `GauntletWatch/` with an `AppIcon` (one 1024 px image) and set
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in the target's build settings.
- **Keeping the stream alive.** While connected the app runs a workout session so it keeps
  streaming when you lower your wrist; that is also where the heart rate comes from. The
  workout is discarded, never saved to Health. Without Health access it falls back to an
  extended runtime session (up to one hour, no heart rate). End it with Status > End session.
- **One target.** The project has only the watch app target, which is all Xcode needs to
  build, install and debug on a watch. Distributing through TestFlight or the App Store
  would additionally need the usual iOS container target; add it then.
- **Crown speed.** `CrownTuning.unitsPerTurn` in `GauntletWatch/Core/CrownMath.swift` is an
  estimate. Turn the crown one full turn: if the Mac scrolls too far or not far enough,
  adjust that number; flip `upwardSign` if it scrolls the wrong way.
- **Why not `@State`?** The sources use `@LocalState`, an alias for `SwiftUI.State`, so they
  type-check with the command-line tools too. It behaves identically.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "No such module 'GauntletWatchCore'" or missing package products | File > Packages > Reset Package Caches. The project expects the package at `..` (the repository root). |
| No scheme in the toolbar | Product > Scheme > Manage Schemes > Autocreate Schemes Now. |
| Signing fails because of HealthKit | Check the team is set. As a last resort clear `CODE_SIGN_ENTITLEMENTS` for the target: the app then uses the extended runtime fallback and shows no heart rate. |
| Watch is not offered as a destination | Unlock watch and iPhone, same Wi-Fi as the Mac, Developer Mode on, then reconnect in Devices and Simulators. |
| Stuck on "Looking for your Mac…" | Is the Mac app running with Bluetooth on? If you used another Mac before, connect once and use Status > Forget this Mac, or reinstall the watch app. |
| "Allow Bluetooth for Gauntlet in Settings" | On the watch: Settings > Privacy & Security > Bluetooth. |
| Pointer freezes when the wrist drops | Status > Keep-alive should read "Workout session". If not, allow Workouts for Gauntlet in the watch's Settings > Health > Apps, then bring the app to the front again. |
| Double Tap does nothing | Series 9 / Ultra 2 or newer only; enable Settings > Gestures > Double Tap and turn Low Power Mode off. |
| The project will not open | `brew install xcodegen && cd WatchApp && xcodegen generate` rebuilds it from `project.yml`. |

## Checks that run without Xcode

```
WatchApp/tools/typecheck.sh            # type-checks the sources on macOS and runs the logic tests
python3 WatchApp/tools/check_pbxproj.py   # referential integrity of the project file
```

`typecheck.sh` cannot compile for watchOS; see the comments at the top of the script for
exactly what each pass proves.
