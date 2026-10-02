import ApplicationServices
import Foundation
import HushCore

public enum InsertionDecision: Sendable, Equatable {
    /// Paste via pasteboard + ⌘V into the focused element.
    case paste
    /// No safe/known target — leave text on the clipboard and notify.
    case copyToClipboard
}

public enum InsertionPolicy {
    public static let textInputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Apps that don't expose usable AX text (terminals, Electron editors) —
    /// paste anyway when they are frontmost, whatever the element info says.
    public static let axOpaqueBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
        "com.exafunction.windsurf",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.tinyspeck.slackmacgap",      // Slack
        "com.hnc.Discord",
    ]

    /// Decide whether ⌘V into the focused element is safe/appropriate.
    /// - secure text fields or Secure Event Input → never paste
    /// - frontmost app is a known AX-opaque editor → paste regardless of element info
    /// - known text-input roles or settable AXValue/AXSelectedTextRange → paste
    /// - otherwise → clipboard
    public static func shouldPaste(
        element: FocusedElementInfo?,
        secureEventInput: Bool,
        frontmostBundleID: String?
    ) -> InsertionDecision {
        guard !secureEventInput else { return .copyToClipboard }
        if element?.isSecure == true { return .copyToClipboard }
        if let bundleID = frontmostBundleID, axOpaqueBundleIDs.contains(bundleID) {
            return .paste
        }
        guard let element else { return .copyToClipboard }
        if let role = element.role, textInputRoles.contains(role) { return .paste }
        if element.acceptsTextInput { return .paste }
        return .copyToClipboard
    }

    /// Preceding characters that already open a span — never separate after them.
    public static let openers: Set<Character> = [
        "(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#",
    ]
    /// If the dictated text starts with one of these it glues to the caret.
    public static let closers: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "’", "”",
    ]

    /// Smart leading space: prepend a single space iff a real character sits
    /// before the caret AND it isn't whitespace, an opener, or a join point —
    /// and the inserted text doesn't start with closing punctuation.
    /// `before == nil` (AX unreadable) or any miss → text unchanged. Never guess.
    public static func leadingSeparator(before: Character?, text: String) -> String {
        guard let before, let first = text.first else { return text }
        guard !before.isWhitespace else { return text }
        guard !openers.contains(before) else { return text }
        guard !closers.contains(first) else { return text }
        return " " + text
    }

    /// D3 context adjustment: leading separator + continuation casing.
    /// `before` is the ~3 characters preceding the caret (nil = unreadable
    /// AX context → the text passes through untouched, the same fail-safe
    /// the separator rule uses).
    public static func adjustForContext(text: String, before: String?,
                                        terms: [String],
                                        style: CleanupStyle) -> String {
        let body = shouldLowercaseFirst(text: text, before: before,
                                        terms: terms, style: style)
            ? text.prefix(1).lowercased() + text.dropFirst()
            : text
        return leadingSeparator(before: before?.last, text: body)
    }

    /// Lowercase a continuation's first character only when every rule
    /// holds — mid-sentence insertion on the same line, non-minimal style,
    /// and the first word isn't protected (I/I'…, an acronym, a camel-case
    /// name, or an exact dictionary term).
    static func shouldLowercaseFirst(text: String, before: String?,
                                     terms: [String], style: CleanupStyle) -> Bool {
        guard style != .minimal, let before else { return false }
        var tail = before[...]
        while let last = tail.last, last.isWhitespace {
            if last.isNewline { return false }   // newline between char and caret
            tail = tail.dropLast()
        }
        guard let lastNonWS = tail.last else { return false }
        if ".!?…".contains(lastNonWS) { return false }

        guard let firstWord = text.split(whereSeparator: { $0.isWhitespace }).first
        else { return false }
        // Edge punctuation doesn't disqualify a word: "Supabase," still
        // names the term and "API," is still an acronym.
        let word = String(firstWord)
            .trimmingCharacters(in: .alphanumerics.inverted)
        guard !word.isEmpty else { return false }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        if word.count >= 2, word == word.uppercased() { return false }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return false }
        if terms.contains(word) { return false }
        return true
    }
}
