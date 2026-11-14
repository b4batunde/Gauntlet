import Foundation
import AVFoundation
import Speech
import ApplicationServices
import CoreGraphics

public enum PermissionState: String, Sendable {
    case granted, denied, notDetermined
}

public struct PermissionStatus: Sendable, Equatable {
    public var microphone: PermissionState
    public var speech: PermissionState
    public var accessibility: PermissionState
    public var screenRecording: PermissionState
    /// The language model for on-device dictation is installed.
    public var onDeviceSpeechInstalled: Bool
    /// True when running from the .app bundle (microphone and speech prompts need its Info.plist).
    public var runningFromBundle: Bool
}

public enum Permissions {
    public static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: microphoneState(),
            speech: speechState(),
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            onDeviceSpeechInstalled: SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition ?? false,
            runningFromBundle: bundleHasUsageStrings)
    }

    /// Asking for the microphone from a bare binary (no Info.plist) kills the process, so check first.
    public static var bundleHasUsageStrings: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    public static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func speechState() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func requestSpeech() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}
