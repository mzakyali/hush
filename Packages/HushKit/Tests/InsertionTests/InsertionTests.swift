import AppKit
import Foundation
import Testing
@testable import Insertion
import HushCore

/// Lock-guarded box for values mutated inside @Sendable closures.
private final class Mutexed<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

// MARK: - decision table

@Test func pasteDecisions() {
    // Text-input roles paste.
    for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
        #expect(InsertionPolicy.shouldPaste(
            element: FocusedElementInfo(role: role),
            secureEventInput: false,
            frontmostBundleID: "com.example.app"
        ) == .paste)
    }

    // Settable AXValue counts as a text input even with a non-standard role.
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXGroup", acceptsTextInput: true),
        secureEventInput: false,
        frontmostBundleID: "com.example.app"
    ) == .paste)

    // Secure field → never paste.
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXTextField", subrole: "AXSecureTextField", isSecure: true),
        secureEventInput: false,
        frontmostBundleID: "com.example.app"
    ) == .copyToClipboard)

    // Secure Event Input on → never paste.
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXTextArea"),
        secureEventInput: true,
        frontmostBundleID: "com.example.app"
    ) == .copyToClipboard)

    // Non-text element → clipboard.
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXButton"),
        secureEventInput: false,
        frontmostBundleID: "com.example.app"
    ) == .copyToClipboard)

    // No AX info at all: opaque editor pastes anyway, unknown app gets clipboard.
    #expect(InsertionPolicy.shouldPaste(
        element: nil, secureEventInput: false,
        frontmostBundleID: "com.googlecode.iterm2"
    ) == .paste)
    #expect(InsertionPolicy.shouldPaste(
        element: nil, secureEventInput: false,
        frontmostBundleID: "com.apple.finder"
    ) == .copyToClipboard)
    #expect(InsertionPolicy.shouldPaste(
        element: nil, secureEventInput: false,
        frontmostBundleID: nil
    ) == .copyToClipboard)

    // Opaque Electron apps paste whatever the element info says — even a non-text
    // role — but never when secure.
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXButton"),
        secureEventInput: false,
        frontmostBundleID: "com.tinyspeck.slackmacgap"
    ) == .paste)
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXGroup"),
        secureEventInput: false,
        frontmostBundleID: "com.hnc.Discord"
    ) == .paste)
    #expect(InsertionPolicy.shouldPaste(
        element: FocusedElementInfo(role: "AXTextField", isSecure: true),
        secureEventInput: false,
        frontmostBundleID: "com.tinyspeck.slackmacgap"
    ) == .copyToClipboard)
    #expect(InsertionPolicy.shouldPaste(
        element: nil, secureEventInput: true,
        frontmostBundleID: "com.microsoft.VSCode"
    ) == .copyToClipboard)
}

// MARK: - smart leading space

@Test func leadingSeparatorTable() {
    // A letter before the caret → prepend a space.
    #expect(InsertionPolicy.leadingSeparator(before: "d", text: "hello") == " hello")
    // A period still gets a space — sentences separate.
    #expect(InsertionPolicy.leadingSeparator(before: ".", text: "hello") == " hello")
    // Whitespace / newline → unchanged.
    #expect(InsertionPolicy.leadingSeparator(before: " ", text: "hello") == "hello")
    #expect(InsertionPolicy.leadingSeparator(before: "\n", text: "hello") == "hello")
    #expect(InsertionPolicy.leadingSeparator(before: "\t", text: "hello") == "hello")
    // Openers glue the next token: "(hello".
    #expect(InsertionPolicy.leadingSeparator(before: "(", text: "hello") == "hello")
    #expect(InsertionPolicy.leadingSeparator(before: "\"", text: "hello") == "hello")
    #expect(InsertionPolicy.leadingSeparator(before: "@", text: "someone") == "someone")
    #expect(InsertionPolicy.leadingSeparator(before: "/", text: "usr") == "usr")
    // No AX read → unchanged, never guess.
    #expect(InsertionPolicy.leadingSeparator(before: nil, text: "hello") == "hello")
    // Text starting with closing punctuation glues to the caret.
    #expect(InsertionPolicy.leadingSeparator(before: "d", text: ", and more") == ", and more")
    #expect(InsertionPolicy.leadingSeparator(before: "d", text: "!") == "!")
    #expect(InsertionPolicy.leadingSeparator(before: "(", text: ", and more") == ", and more")
    // Indonesian dictation behaves the same.
    #expect(InsertionPolicy.leadingSeparator(before: "g", text: "besok deploy") == " besok deploy")
    #expect(InsertionPolicy.leadingSeparator(before: " ", text: "besok deploy") == "besok deploy")
    // Empty text stays empty.
    #expect(InsertionPolicy.leadingSeparator(before: "d", text: "") == "")
}

// MARK: - context adjustment (D3: separator + continuation casing)

@Test func adjustForContextCasingTable() {
    func adjust(_ text: String, _ before: String?, _ terms: [String] = [],
                _ style: CleanupStyle = .default) -> String {
        InsertionPolicy.adjustForContext(text: text, before: before,
                                         terms: terms, style: style)
    }
    // Mid-sentence continuation → lowercased (separator still applies).
    #expect(adjust("Both work", "word") == " both work")
    #expect(adjust("Both work", "ord,") == " both work")   // after comma
    // After a sentence terminator → casing kept.
    #expect(adjust("Both work", "ord.") == " Both work")
    #expect(adjust("Both work", "…") == " Both work")
    // Newline between the char and caret → kept (and no separator).
    #expect(adjust("Both work", "d\n") == "Both work")
    #expect(adjust("Both work", "d\n ") == "Both work")
    // Protected first words.
    #expect(adjust("I think", "word") == " I think")
    #expect(adjust("I've seen", "word") == " I've seen")
    #expect(adjust("API keys", "word") == " API keys")
    #expect(adjust("iPhone syncs", "word") == " iPhone syncs")
    #expect(adjust("McDonald went", "word") == " McDonald went")
    // Exact dictionary term (case-sensitive) is protected.
    #expect(adjust("Supabase host", "word", ["Supabase"]) == " Supabase host")
    #expect(adjust("supabase host", "word", ["Supabase"]) == " supabase host")
    // Minimal style never touches casing.
    #expect(adjust("Both work", "word", [], .minimal) == " Both work")
    // Unreadable context → unchanged (same fail-safe as the separator).
    #expect(adjust("Both work", nil) == "Both work")
    // Indonesian continuation.
    #expect(adjust("Dan itu bekerja", "word") == " dan itu bekerja")
    // Already lowercase → separator only.
    #expect(adjust("both work", "word") == " both work")
}

// MARK: - paste-raw decision (spec §3.9, T11)

@Test func pasteRawReplacesWhenRangeMatches() {
    // Inserted " cleaned text" (leading space + cleaned), caret right after it
    // at UTF-16 offset 20 → the range is [7, 20).
    let action = PasteRawPolicy.decide(
        raw: "raw text", cleaned: "cleaned text", inserted: " cleaned text",
        caret: 20
    ) { range in
        range == NSRange(location: 7, length: 13) ? " cleaned text" : "wrong"
    }
    // The raw text comes back — the inserter context-adjusts it (separator +
    // casing) against the real ~3 chars before the range.
    #expect(action == .replace(range: NSRange(location: 7, length: 13),
                               raw: "raw text"))
}

@Test func pasteRawNoSeparatorWhenCleanedHadNone() {
    let action = PasteRawPolicy.decide(
        raw: "um raw", cleaned: "cleaned", inserted: "cleaned",
        caret: 7
    ) { range in
        range == NSRange(location: 0, length: 7) ? "cleaned" : nil
    }
    #expect(action == .replace(range: NSRange(location: 0, length: 7),
                               raw: "um raw"))
}

@Test func pasteRawChangedTextRefuses() {
    // The field's text no longer matches what was inserted.
    let action = PasteRawPolicy.decide(
        raw: "raw", cleaned: "cleaned", inserted: "cleaned",
        caret: 7
    ) { _ in "edited!" }
    #expect(action == .notify("Can't replace — text was changed"))

    // …or the caret moved so the computed range misses entirely.
    let offByOne = PasteRawPolicy.decide(
        raw: "raw", cleaned: "cleaned", inserted: "cleaned",
        caret: 3          // range would be [-4, 3) — invalid
    ) { _ in "cleaned" }
    #expect(offByOne == .notify("Can't replace — text was changed"))

    // …or the range read comes back empty.
    let unreadable = PasteRawPolicy.decide(
        raw: "raw", cleaned: "cleaned", inserted: "cleaned",
        caret: 7
    ) { _ in nil }
    #expect(unreadable == .notify("Can't replace — text was changed"))
}

@Test func pasteRawOpaqueOrClipboardOnlyNotifies() {
    // No element / nothing pasted (clipboard result, AX-opaque app).
    #expect(PasteRawPolicy.decide(
        raw: "raw", cleaned: "cleaned", inserted: nil, caret: nil
    ) { _ in nil } == .notify("Can't replace in this app"))
    // Element existed but the caret can't be read → same answer.
    #expect(PasteRawPolicy.decide(
        raw: "raw", cleaned: "cleaned", inserted: "cleaned", caret: nil
    ) { _ in nil } == .notify("Can't replace in this app"))
}

@Test func pasteRawNoCleanupIsNoOp() {
    // raw == cleaned → nothing to undo.
    #expect(PasteRawPolicy.decide(
        raw: "same text", cleaned: "same text", inserted: "same text",
        caret: 9
    ) { _ in "same text" } == .notify("Nothing to undo — no cleanup was applied"))
}

@Test func pasteRawNoDictationNotifies() {
    #expect(PasteRawPolicy.decide(
        raw: nil, cleaned: nil, inserted: nil, caret: nil
    ) { _ in nil } == .notify("Nothing to undo"))
}

// MARK: - pasteboard snapshot/restore

@Test func pasteboardSnapshotRoundTrip() throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("hush-test-\(UUID().uuidString)"))
    pb.clearContents()

    let pngData = Data([0x89, 0x50, 0x4E, 0x47])
    let item = NSPasteboardItem()
    item.setString("hello", forType: .string)
    item.setData(pngData, forType: .png)
    item.setData(Data([1, 2, 3]), forType: .init("com.hush.custom"))
    pb.writeObjects([item])

    let snapshot = PasteboardSnapshot.capture(pb)

    // Simulate the paste write.
    pb.clearContents()
    pb.setString("inserted text", forType: .string)
    #expect(pb.string(forType: .string) == "inserted text")

    snapshot.restore(to: pb)
    #expect(pb.string(forType: .string) == "hello")
    #expect(pb.data(forType: .png) == pngData)
    #expect(pb.data(forType: .init("com.hush.custom")) == Data([1, 2, 3]))
}

@Test func restoreSkippedWhenClipboardChanged() throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("hush-test-\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("original", forType: .string)

    let snapshot = PasteboardSnapshot.capture(pb)
    pb.clearContents()
    pb.setString("inserted", forType: .string)

    // User copies something else before the restore fires.
    pb.clearContents()
    pb.setString("user copy", forType: .string)

    snapshot.restore(to: pb)
    #expect(pb.string(forType: .string) == "user copy")
}

// MARK: - inserter behavior with fakes

@Test func noTextInputCopiesToClipboardAndNotifies() async throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("hush-test-\(UUID().uuidString)"))
    pb.clearContents()
    let notified = Mutexed<[String]>([])
    let inserter = Inserter(
        pasteboard: PasteboardRef(pb),
        frontmostApp: { ("com.apple.finder", 100) },
        focusedElementProvider: { nil },
        secureEventInputProvider: { false },
        notify: { message in notified.withLock { $0.append(message) } }
    )

    let target = await inserter.captureTarget()
    let result = try await inserter.insert("dictated text", target: target,
                                           context: InsertionContext())
    guard case .copiedToClipboard = result else {
        Issue.record("expected .copiedToClipboard, got \(result)")
        return
    }
    #expect(pb.string(forType: .string) == "dictated text")
    #expect(notified.withLock { $0 } == ["Copied to clipboard"])
}

@Test func appSwitchBetweenCaptureAndInsertCopiesWithNotice() async throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("hush-test-\(UUID().uuidString)"))
    pb.clearContents()
    let notified = Mutexed<[String]>([])
    let frontmost = Mutexed<(String?, pid_t?)>(("com.example.app", 100))
    let inserter = Inserter(
        pasteboard: PasteboardRef(pb),
        frontmostApp: { frontmost.withLock { $0 } },
        focusedElementProvider: { nil },
        secureEventInputProvider: { false },
        notify: { message in notified.withLock { $0.append(message) } }
    )

    let target = await inserter.captureTarget()
    #expect(target.pid == 100)
    // User switches apps before the pipeline finishes processing.
    frontmost.withLock { $0 = ("com.example.other", 200) }

    let result = try await inserter.insert("dictated text", target: target,
                                           context: InsertionContext())
    guard case .copiedToClipboard = result else {
        Issue.record("expected .copiedToClipboard, got \(result)")
        return
    }
    #expect(pb.string(forType: .string) == "dictated text")
    #expect(notified.withLock { $0 } == ["Copied to clipboard — you switched apps"])
}

@Test func sameAppStillPastes() async throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("hush-test-\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("user clipboard", forType: .string)
    let inserter = Inserter(
        pasteboard: PasteboardRef(pb),
        frontmostApp: { ("com.googlecode.iterm2", 100) },
        focusedElementProvider: { nil },
        secureEventInputProvider: { false },
        notify: { _ in }
    )
    let target = await inserter.captureTarget()
    let result = try await inserter.insert("pasted text", target: target,
                                           context: InsertionContext())
    guard case .pasted = result else {
        Issue.record("expected .pasted, got \(result)")
        return
    }
    // Clipboard restored after the paste (⌘V goes nowhere without an event tap, which is fine).
    #expect(pb.string(forType: .string) == "user clipboard")
}
