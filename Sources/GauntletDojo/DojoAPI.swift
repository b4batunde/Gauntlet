import SwiftUI
import GauntletProtocol
import GauntletEngine

/// Everything the Dojo needs from the app that hosts it.
///
/// The host owns the engine and the real cursor; the Dojo borrows the engine's output
/// while a sandbox drill is running and hands it back afterwards.
public final class DojoHost {
    public let engine: WristEngine

    /// Ask the watch to play a haptic. No-op when no watch is connected.
    public var playHaptic: (HapticPattern) -> Void = { _ in }

    /// The Dojo changed engine settings (calibration). The host should persist `engine.currentSettings`.
    public var settingsDidChange: () -> Void = {}

    /// Pass a sink to route pointer output into the Dojo's virtual screen (sandbox);
    /// pass nil to give output back to the real macOS cursor.
    public var setSandboxSink: (PointerSink?) -> Void = { _ in }

    /// True while a real, paired watch is streaming. When false the Dojo may drive
    /// the engine with its built-in `VirtualWatch` instead.
    public var isRealWatchConnected: () -> Bool = { false }

    public init(engine: WristEngine) {
        self.engine = engine
    }
}

/// Shared visual language for the Dojo and the Mac app shell.
public enum DojoTheme {
    public static let background = Color(red: 0.027, green: 0.043, blue: 0.078)      // #070B14
    public static let panel = Color(red: 0.063, green: 0.090, blue: 0.149)           // #101726
    public static let panelStroke = Color.white.opacity(0.08)
    public static let accent = Color(red: 0.208, green: 0.878, blue: 1.0)            // #35E0FF cyan
    public static let secondary = Color(red: 0.545, green: 0.361, blue: 1.0)         // #8B5CFF violet
    public static let success = Color(red: 0.239, green: 1.0, blue: 0.635)           // #3DFFA2
    public static let warning = Color(red: 1.0, green: 0.690, blue: 0.125)           // #FFB020
    public static let danger = Color(red: 1.0, green: 0.302, blue: 0.427)            // #FF4D6D
    public static let textPrimary = Color.white.opacity(0.92)
    public static let textSecondary = Color.white.opacity(0.55)
}
