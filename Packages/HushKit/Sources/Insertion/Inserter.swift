import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation
import HushCore

/// Inserts text at the frontmost app's focused text field (pasteboard + ⌘V), restores the
/// user's clipboard afterwards, or leaves text on the clipboard when no target exists.
///
/// Dependencies are injectable for tests: the real app wires `frontmostBundleID` to
/// `NSWorkspace.shared.frontmostApplication`, `focusedElement` to the system-wide AX
/// focused element, and `notify` to `UNUserNotificationCenter`.
public actor Inserter: Inserting {
    public enum Error: Swift.Error {
        case secureContext
    }

    private var pasteboard: NSPasteboard { pasteboardRef.pasteboard }
    private let pasteboardRef: PasteboardRef
    private let restoreDelay: Duration = .milliseconds(300)
    private let frontmostApp: @Sendable () -> (bundleID: String?, pid: pid_t?)
    private let focusedElementProvider: @Sendable () -> AXUIElement?
    private let secureEventInputProvider: @Sendable () -> Bool
    private let notify: @Sendable (String) -> Void

    /// Pids that already got AXManualAccessibility — set once per app, never reverted.
    private var manualAXEnabled: Set<pid_t> = []

    /// The last `.pasted` result — needed by paste-raw undo (T11) and EditWatcher (T9).
    public private(set) var lastInsertion: InsertionResult?
    /// Exactly what the last paste wrote (leading separator + adjusted text) —
    /// ⌃⌥Z verifies this byte-for-byte before replacing. nil on clipboard results.
    private var lastPastedText: String?

    /// Fired once per successful `.pasted` insertion: the text actually
    /// written, the element it went into, the caret's UTF-16 offset after
    /// the paste (nil when AX can't answer → caller skips), and the pid.
    /// EditWatcher hangs its observation off this.
    private let onPasted: (@Sendable (String, AXUIElement, Int?, pid_t?) -> Void)?

    public init(
        pasteboard: PasteboardRef = .general,
        frontmostApp: (@Sendable () -> (bundleID: String?, pid: pid_t?))? = nil,
        focusedElementProvider: (@Sendable () -> AXUIElement?)? = nil,
        secureEventInputProvider: (@Sendable () -> Bool)? = nil,
        notify: (@Sendable (String) -> Void)? = nil,
        onPasted: (@Sendable (String, AXUIElement, Int?, pid_t?) -> Void)? = nil
    ) {
        self.onPasted = onPasted
        self.pasteboardRef = pasteboard
        self.frontmostApp = frontmostApp ?? {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.processIdentifier)
        }
        self.focusedElementProvider = focusedElementProvider ?? {
            Inserter.systemFocusedElement()
        }
        self.secureEventInputProvider = secureEventInputProvider ?? {
            IsSecureEventInputEnabled()
        }
        self.notify = notify ?? { message in
            NSLog("Hush notification: %@", message)
        }
    }

    /// Capture the frontmost app and its focused element — called when recording stops,
    /// so the target is fixed before transcription runs.
    public func captureTarget() -> InsertionTarget {
        let app = frontmostApp()
        if let pid = app.pid {
            enableManualAccessibility(pid: pid)
        }
        let element = focusedElementProvider()
        return InsertionTarget(
            bundleID: app.bundleID,
            pid: app.pid,
            elementInfo: element.map(Self.describe(_:)),
            element: element.map(InsertedElement.init)
        )
    }

    public func insert(_ text: String, target: InsertionTarget,
                       context: InsertionContext) async throws -> InsertionResult {
        // The spec target is the app focused when recording stopped; if the user has
        // switched since, pasting would land in the wrong app — copy instead.
        let now = frontmostApp()
        if now.pid != target.pid {
            return copyToClipboard(text, notify: "Copied to clipboard — you switched apps")
        }

        let decision = InsertionPolicy.shouldPaste(
            element: target.elementInfo,
            secureEventInput: secureEventInputProvider(),
            frontmostBundleID: target.bundleID
        )

        switch decision {
        case .paste:
            // Context adjustment: separator + continuation casing from the
            // ~3 chars before the caret (D3). If AX can't answer (Electron,
            // terminals, secure fields), the text goes in unchanged.
            let before = target.element.flatMap {
                Self.contextBeforeCaret($0.element, length: 3)
            }
            let adjusted = InsertionPolicy.adjustForContext(
                text: text, before: before,
                terms: context.terms, style: context.style)
            await paste(adjusted)
            let result = InsertionResult.pasted(
                appBundleID: target.bundleID,
                element: target.element,
                insertedLength: (adjusted as NSString).length
            )
            lastInsertion = result
            lastPastedText = adjusted
            if let element = target.element {
                onPasted?(adjusted, element.element,
                          Self.selectionEnd(of: element.element), target.pid)
            }
            return result
        case .copyToClipboard:
            return copyToClipboard(text, notify: "Copied to clipboard")
        }
    }

    /// Chromium/Electron apps only expose their text tree after AXManualAccessibility
    /// (and AXEnhancedUserInterface) are set on the application element. Once per pid.
    private func enableManualAccessibility(pid: pid_t) {
        guard manualAXEnabled.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func copyToClipboard(_ text: String, notify message: String) -> InsertionResult {
        leaveOnClipboard(text, message: message)
        let result = InsertionResult.copiedToClipboard
        lastInsertion = result
        lastPastedText = nil
        return result
    }

    // MARK: - paste-raw (spec §3.9, T11)

    /// ⌃⌥Z: replace the last pasted insertion with the raw transcript — only
    /// when the target element still contains exactly what we pasted. All
    /// outcomes land on the notification path; never throws.
    public func replaceLastInsertion(raw: String?, cleaned: String?,
                                     context: InsertionContext) async {
        var element: AXUIElement?
        var caret: Int?
        var inserted: String?
        if case .pasted(_, let insertedElement?, _) = lastInsertion {
            element = insertedElement.element
            inserted = lastPastedText
            caret = Self.selectionEnd(of: insertedElement.element)
        }
        let action = PasteRawPolicy.decide(
            raw: raw, cleaned: cleaned, inserted: inserted, caret: caret
        ) { range in
            element.flatMap { Self.string(in: range, of: $0) }
        }
        switch action {
        case .replace(let range, let raw):
            if let element { Self.select(range, of: element) }
            // Same context adjustment the original paste got — separator +
            // continuation casing — applied to the raw text this time.
            let before = element.flatMap {
                Self.string(in: NSRange(location: max(0, range.location - 3),
                                        length: min(3, range.location)),
                            of: $0)
            }
            let text = InsertionPolicy.adjustForContext(
                text: raw, before: before,
                terms: context.terms, style: context.style)
            await paste(text)
            lastPastedText = text
            if case .pasted(let bundleID, let el, _) = lastInsertion {
                lastInsertion = .pasted(appBundleID: bundleID, element: el,
                                        insertedLength: (text as NSString).length)
            }
        case .notify(let message):
            notify(message)
        }
    }

    // MARK: - internals

    private func paste(_ text: String) async {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Self.postCommandV()

        // Restore the user's clipboard unless they copied something else meanwhile
        // (the snapshot checks changeCount).
        try? await Task.sleep(for: restoreDelay)
        snapshot.restore(to: pasteboard)
    }

    private func leaveOnClipboard(_ text: String, message: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        notify(message)
    }

    /// Post ⌘V to the system event stream — it lands in whatever app is key.
    static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    /// The focused UI element of the frontmost app, via the system-wide AX object.
    static func systemFocusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Up to `length` characters before the caret (or selection start) —
    /// feeds the separator + continuation-casing decisions (D3). Returns nil
    /// whenever AX can't answer (Electron/Slack, terminals, secure fields,
    /// caret at position 0); the caller then inserts the text unchanged.
    static func contextBeforeCaret(_ element: AXUIElement, length: Int = 3) -> String? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.location > 0
        else { return nil }

        let width = min(length, range.location)
        // Precise path: ask the element for the string in the range
        // before the caret.
        var previous = CFRange(location: range.location - width, length: width)
        if let rangeObject = AXValueCreate(.cfRange, &previous) {
            var stringValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                rangeObject, &stringValue
            ) == .success,
                let string = stringValue as? String {
                return string
            }
        }

        // Fallback: AXValue + the same range index. AX positions count UTF-16
        // code units — a lone surrogate half yields a replacement Character,
        // which is not in either punctuation set and just inserts a space.
        var wholeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &wholeValue
        ) == .success,
            let whole = wholeValue as? String
        else { return nil }
        let ns = whole as NSString
        guard range.location - width >= 0 else { return nil }
        return ns.substring(with: NSRange(location: range.location - width, length: width))
    }

    /// Selection end — the caret position as a UTF-16 offset — for paste-raw's
    /// "inserted range is [caret − insertedLength, caret)" math.
    static func selectionEnd(of element: AXUIElement) -> Int? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        else { return nil }
        return range.location + range.length
    }

    /// Text over a UTF-16 range — same two-step strategy as
    /// `characterBeforeCaret` (AXStringForRange, then AXValue substring).
    static func string(in range: NSRange, of element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        if let rangeObject = AXValueCreate(.cfRange, &cfRange) {
            var stringValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                rangeObject, &stringValue
            ) == .success,
                let string = stringValue as? String {
                return string
            }
        }
        var wholeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &wholeValue
        ) == .success,
            let whole = wholeValue as? String
        else { return nil }
        let ns = whole as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    /// Select a UTF-16 range — the next ⌘V paste replaces the selection.
    static func select(_ range: NSRange, of element: AXUIElement) {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeObject = AXValueCreate(.cfRange, &cfRange) else { return }
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, rangeObject)
    }

    static func describe(_ element: AXUIElement) -> FocusedElementInfo {
        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)

        var isSecure = false
        if let role, role.localizedCaseInsensitiveContains("secure") { isSecure = true }
        if let subrole, subrole.localizedCaseInsensitiveContains("secure") { isSecure = true }

        var acceptsText = false
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            acceptsText = true
        }
        settable = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            acceptsText = true
        }

        return FocusedElementInfo(
            role: role, subrole: subrole,
            isSecure: isSecure, acceptsTextInput: acceptsText
        )
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return string
    }
}
