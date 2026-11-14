import AppKit
import ApplicationServices
import CoreGraphics
import GauntletEngine

/// Drives the real macOS cursor by posting Quartz events.
/// Requires the Accessibility permission; without it macOS silently discards the events.
///
/// All posting happens on one serial queue: events stay in order, the Bluetooth queue is never
/// blocked, and a click's "up" can trail its "down" by a few milliseconds (some apps drop a
/// press and release that carry the same timestamp).
public final class SystemPointerSink: PointerSink, @unchecked Sendable {
    private let postQueue = DispatchQueue(label: "gauntlet.pointer.post", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastDown: [MouseButton: TimeInterval] = [:]
    private static let minimumPressDuration: TimeInterval = 0.012
    private var position = CGPoint.zero
    private var hasPosition = false
    private var held: Set<MouseButton> = []
    private var scrollRemainder = CGPoint.zero
    private var displays: [CGRect] = []
    private var displaysRefreshed: TimeInterval = 0
    private var trusted = false
    private var trustChecked: TimeInterval = -10

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security › Accessibility.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: PointerSink

    public func movePointer(dx: Double, dy: Double) {
        postQueue.async { self.moveNow(dx: dx, dy: dy) }
    }

    public func button(_ button: MouseButton, isDown: Bool, clickCount: Int) {
        postQueue.async { self.buttonNow(button, isDown: isDown, clickCount: clickCount) }
    }

    public func scroll(dx: Double, dy: Double) {
        postQueue.async { self.scrollNow(dx: dx, dy: dy) }
    }

    // MARK: Posting (postQueue only)

    private func moveNow(dx: Double, dy: Double) {
        guard canPost() else { return }
        syncWithSystemCursor()
        var target = CGPoint(x: position.x + dx, y: position.y + dy)
        target = clampToDisplays(target)
        let moved = CGPoint(x: target.x - position.x, y: target.y - position.y)
        position = target

        let type: CGEventType
        let button: CGMouseButton
        if held.contains(.left) { type = .leftMouseDragged; button = .left }
        else if held.contains(.right) { type = .rightMouseDragged; button = .right }
        else if held.contains(.middle) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: target, mouseButton: button) else { return }
        // Games and some pro apps read deltas rather than positions.
        event.setDoubleValueField(.mouseEventDeltaX, value: moved.x)
        event.setDoubleValueField(.mouseEventDeltaY, value: moved.y)
        event.post(tap: .cghidEventTap)
    }

    private func buttonNow(_ button: MouseButton, isDown: Bool, clickCount: Int) {
        guard canPost() || (!isDown && held.contains(button)) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isDown {
            lastDown[button] = now
        } else if let pressed = lastDown[button], now - pressed < Self.minimumPressDuration {
            usleep(UInt32((Self.minimumPressDuration - (now - pressed)) * 1_000_000))
        }
        syncWithSystemCursor()
        let type: CGEventType
        let cgButton: CGMouseButton
        switch (button, isDown) {
        case (.left, true): type = .leftMouseDown; cgButton = .left
        case (.left, false): type = .leftMouseUp; cgButton = .left
        case (.right, true): type = .rightMouseDown; cgButton = .right
        case (.right, false): type = .rightMouseUp; cgButton = .right
        case (.middle, true): type = .otherMouseDown; cgButton = .center
        case (.middle, false): type = .otherMouseUp; cgButton = .center
        }
        if isDown { held.insert(button) } else { held.remove(button) }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.post(tap: .cghidEventTap)
    }

    private func scrollNow(dx: Double, dy: Double) {
        guard canPost() else { return }
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let wholeX = scrollRemainder.x.rounded(.towardZero)
        let wholeY = scrollRemainder.y.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        scrollRemainder.x -= wholeX
        scrollRemainder.y -= wholeY
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    public func shortcut(_ shortcut: SystemShortcut) {
        switch shortcut {
        case .missionControl:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            }
        case .keyCombo(let keyCode, let modifiers):
            sendKeyCombo(keyCode: keyCode, modifiers: modifiers)
        case .openApp(let bundleID):
            openApp(bundleID: bundleID)
        }
    }

    /// Presses and releases one key with modifiers (`CGEventFlags.rawValue`), e.g. ⌘V is
    /// `sendKeyCombo(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue)`.
    /// Ordered with pointer events; needs the Accessibility permission.
    public func sendKeyCombo(keyCode: UInt16, modifiers: UInt64) {
        postQueue.async {
            guard self.canPost() else { return }
            let flags = CGEventFlags(rawValue: modifiers)
            let key = CGKeyCode(keyCode)
            guard let down = CGEvent(keyboardEventSource: self.source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: self.source, virtualKey: key, keyDown: false) else { return }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            usleep(8_000)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Launches (or brings forward) an app by bundle identifier.
    public func openApp(bundleID: String) {
        DispatchQueue.main.async {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    /// Nudges the real cursor 24 points right and back, and reports whether macOS let it move.
    /// A quick way to confirm the Accessibility permission is really in effect.
    public func selfTest() -> Bool {
        guard let before = CGEvent(source: nil)?.location else { return false }
        postQueue.sync { self.moveNow(dx: 24, dy: 0) }
        usleep(60_000)
        let after = CGEvent(source: nil)?.location ?? before
        postQueue.sync { self.moveNow(dx: before.x - after.x, dy: before.y - after.y) }
        return abs(after.x - before.x) > 8 || abs(after.y - before.y) > 8
    }

    /// Let go of anything still held (called when the app quits or loses the watch).
    public func releaseAll() {
        postQueue.sync {
            for button in MouseButton.allCases where self.held.contains(button) {
                self.buttonNow(button, isDown: false, clickCount: 1)
            }
        }
    }

    // MARK: Helpers (postQueue only)

    /// Without the Accessibility permission macOS drops our events anyway; not posting at all
    /// avoids surprise permission dialogs and keeps the sandbox truly hands-off.
    private func canPost() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - trustChecked > 1 {
            trustChecked = now
            trusted = AXIsProcessTrusted()
        }
        return trusted
    }

    /// If the user nudged the trackpad or mouse, continue from where the cursor really is.
    private func syncWithSystemCursor() {
        guard let actual = CGEvent(source: nil)?.location else { return }
        if !hasPosition || abs(actual.x - position.x) > 1.5 || abs(actual.y - position.y) > 1.5 {
            position = actual
            hasPosition = true
        }
    }

    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        let now = ProcessInfo.processInfo.systemUptime
        if displays.isEmpty || now - displaysRefreshed > 2 {
            displaysRefreshed = now
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &ids, &count)
            displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        }
        guard !displays.isEmpty else { return p }
        var best = p
        var bestDistance = Double.infinity
        for rect in displays {
            let c = CGPoint(x: min(max(p.x, rect.minX), rect.maxX - 1), y: min(max(p.y, rect.minY), rect.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDistance { bestDistance = d; best = c }
            if d == 0 { break }
        }
        return best
    }
}
