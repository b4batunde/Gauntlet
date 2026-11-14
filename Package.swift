// swift-tools-version: 5.10
import PackageDescription

// Gauntlet — turn an Apple Watch into an air mouse for the Mac.
//
//   GauntletProtocol   wire format shared by watch and Mac (pure Swift)
//   GauntletLink       pairing handshake + transports (Bluetooth LE, TCP dev link)
//   GauntletWatchCore  everything the watch app does that is not WatchKit UI
//   GauntletEngine     sensor fusion -> pointer, gesture recognition, virtual watch
//   GauntletDojo       3D training environment (SceneKit)
//   GauntletAI         June: voice assistant (speech, context capture, Gemini); Apple frameworks only
//   GauntletMac        Mac services (cursor injection, BLE peripheral) + SwiftUI shell
//   GauntletApp        the Mac app executable
//   fakewatch          command-line simulated watch for end-to-end tests
//   dojopreview        the Dojo on its own, driven by the virtual watch:  swift run dojopreview
//   promo              renders the showcase film (3D watch + Mac) to showcase/:  swift run promo
//   selftest           the test suite, runnable without Xcode:  swift run selftest
let package = Package(
    name: "Gauntlet",
    platforms: [.macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "GauntletProtocol", targets: ["GauntletProtocol"]),
        .library(name: "GauntletLink", targets: ["GauntletLink"]),
        .library(name: "GauntletWatchCore", targets: ["GauntletWatchCore"]),
        .library(name: "GauntletEngine", targets: ["GauntletEngine"]),
        .library(name: "GauntletDojo", targets: ["GauntletDojo"]),
        .library(name: "GauntletAI", targets: ["GauntletAI"]),
        .library(name: "GauntletMac", targets: ["GauntletMac"]),
        .executable(name: "Gauntlet", targets: ["GauntletApp"]),
        .executable(name: "fakewatch", targets: ["fakewatch"]),
    ],
    targets: [
        .target(name: "GauntletProtocol"),
        .target(name: "GauntletLink", dependencies: ["GauntletProtocol"]),
        .target(name: "GauntletWatchCore", dependencies: ["GauntletProtocol", "GauntletLink"]),
        .target(name: "GauntletEngine", dependencies: ["GauntletProtocol"]),
        .target(name: "GauntletDojo", dependencies: ["GauntletProtocol", "GauntletEngine"]),
        .target(name: "GauntletAI", dependencies: ["GauntletProtocol", "GauntletLink", "GauntletEngine"]),
        .target(
            name: "GauntletMac",
            dependencies: ["GauntletProtocol", "GauntletLink", "GauntletEngine", "GauntletDojo", "GauntletAI"]
        ),
        .executableTarget(name: "GauntletApp", dependencies: ["GauntletMac"]),
        .executableTarget(
            name: "fakewatch",
            dependencies: ["GauntletProtocol", "GauntletLink", "GauntletWatchCore", "GauntletEngine"]
        ),
        .executableTarget(name: "dojopreview", dependencies: ["GauntletProtocol", "GauntletEngine", "GauntletDojo"]),
        .executableTarget(name: "promo"),
        .executableTarget(name: "junebench", dependencies: ["GauntletAI"]),
        .executableTarget(
            name: "selftest",
            dependencies: ["GauntletProtocol", "GauntletLink", "GauntletWatchCore", "GauntletEngine"]
        ),
    ]
)
