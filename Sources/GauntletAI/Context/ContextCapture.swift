import AppKit
import ApplicationServices

/// What June can see at the cursor, read through the Accessibility API.
public struct CaptureResult: Sendable, Equatable {
    public enum Source: String, Sendable { case selection, element, none }
    public var text: String?
    public var imageJPEG: Data?
    /// Screen frame of what was read, global top-left coordinates, for the capture highlight.
    public var frame: CGRect?
    public var appName: String
    /// The focused element is an editable text field (dictation and paste depend on this).
    public var focusedEditable: Bool
    public var source: Source
}

enum ContextCapture {
    static let maxChars = 4000
    private static var enabledPIDs = Set<pid_t>()

    /// Reads selected text if there is any, otherwise the text of the element under `point`.
    /// Call off the main thread: Accessibility calls can block briefly.
    static func capture(at point: CGPoint) -> CaptureResult {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? "Unknown app"
        if let pid = front?.processIdentifier { enableWebAccessibility(pid) }

        let system = AXUIElementCreateSystemWide()
        let focused = element(system, kAXFocusedUIElementAttribute)
        let editable = focused.map(isEditable) ?? false

        if let focused, let selected = string(focused, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CaptureResult(text: String(selected.prefix(maxChars)), imageJPEG: nil, frame: frame(of: focused),
                                 appName: appName, focusedEditable: editable, source: .selection)
        }

        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        if let hit, let found = nearestText(from: hit) {
            return CaptureResult(text: String(found.text.prefix(maxChars)), imageJPEG: nil, frame: frame(of: found.element),
                                 appName: appName, focusedEditable: editable, source: .element)
        }
        return CaptureResult(text: nil, imageJPEG: nil, frame: nil, appName: appName,
                             focusedEditable: editable, source: .none)
    }

    // MARK: Finding text

    private static func nearestText(from start: AXUIElement) -> (text: String, element: AXUIElement)? {
        var current: AXUIElement? = start
        for _ in 0..<6 {
            guard let el = current else { break }
            if let own = ownText(of: el), own.count >= 3 {
                // A tiny hit (one link inside a paragraph): widen to the surrounding block.
                if own.count < 40, let parent = element(el, kAXParentAttribute) {
                    var wide = ""
                    gather(parent, depth: 3, into: &wide)
                    if wide.count > own.count { return (wide, parent) }
                }
                return (own, el)
            }
            current = element(el, kAXParentAttribute)
        }
        return nil
    }

    private static func ownText(of el: AXUIElement) -> String? {
        let candidates = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        for attribute in candidates {
            if let s = string(el, attribute) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Collects the static text under a block (a paragraph, a list item, a message body).
    private static func gather(_ el: AXUIElement, depth: Int, into text: inout String) {
        guard depth >= 0, text.count < maxChars else { return }
        if string(el, kAXRoleAttribute) == kAXStaticTextRole, let value = string(el, kAXValueAttribute) {
            if !text.isEmpty { text += " " }
            text += value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list.prefix(80) {
            gather(child, depth: depth - 1, into: &text)
            if text.count >= maxChars { return }
        }
    }

    // MARK: Accessibility helpers

    private static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Chromium and Electron only build their accessibility tree when asked.
    private static func enableWebAccessibility(_ pid: pid_t) {
        guard !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
