import Foundation

/// ⌃⌥Z paste-raw (spec §3.9, plan T11): the pure decision. `Inserter` does the
/// AX reads and supplies them here, so the whole policy is unit-testable.
public enum PasteRawPolicy {
    public enum Action: Equatable, Sendable {
        /// Select `range` on the element (UTF-16 offsets), then paste `text`
        /// through the normal pasteboard path — ⌘V replaces the selection.
        case replace(range: NSRange, text: String)
        case notify(String)
    }

    /// - `raw` / `cleaned`: the last dictation's transcript and inserted text.
    ///   nil → nothing has been dictated yet.
    /// - `inserted`: exactly what the last paste wrote (separator + cleaned) —
    ///   nil when the last result wasn't a paste or the element is unreadable.
    /// - `caret`: the element's current selection end (AX UTF-16 offset).
    /// - `textAt`: reads the element's text over a UTF-16 range; nil on miss.
    public static func decide(
        raw: String?, cleaned: String?, inserted: String?, caret: Int?,
        textAt: (NSRange) -> String?
    ) -> Action {
        guard let raw, let cleaned else {
            return .notify("Nothing to undo")
        }
        guard raw != cleaned else {
            return .notify("Nothing to undo — no cleanup was applied")
        }
        // Opaque targets (no AX element) and clipboard-only results can never
        // be verified — don't guess, just say so.
        guard let inserted, let caret else {
            return .notify("Can't replace in this app")
        }
        // The paste left the caret right after the inserted text; the inserted
        // range is [caret − insertedLength, caret) in UTF-16 units.
        let length = inserted.utf16.count
        let location = caret - length
        guard location >= 0,
              let found = textAt(NSRange(location: location, length: length)),
              found == inserted else {
            return .notify("Can't replace — text was changed")
        }
        // Keep the same leading separator the cleaned insert used (≤ 1 char —
        // InsertionPolicy only ever prepends a single space).
        let separatorLength = inserted.utf16.count - cleaned.utf16.count
        let separator = separatorLength > 0 ? String(inserted.prefix(1)) : ""
        return .replace(range: NSRange(location: location, length: length),
                        text: separator + raw)
    }
}
