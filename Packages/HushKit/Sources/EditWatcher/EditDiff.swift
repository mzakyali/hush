import Foundation
import HushCore

/// One observed user correction: `from` → `to`.
public struct Replacement: Sendable, Equatable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Word-level diff between what was pasted and what the element holds when
/// the watch ends (§6, plan T9). Keeps only small substitutions — 1–3 tokens
/// replaced by 1–3 tokens — and ignores whole-sentence insertions/deletions.
public enum EditDiff {
    /// Maximum fraction of inserted tokens that may change before the whole
    /// edit is abandoned as "too big to learn from".
    static let maxChangeRatio = 0.30

    /// `inserted`: the text we pasted (with separator trimmed away).
    /// `edited`: the same span's current text (see `InsertedSpan.locate`).
    public static func candidates(inserted: String, edited: String) -> [Replacement] {
        let insertedTokens = inserted.split(whereSeparator: { $0.isWhitespace })
        guard !insertedTokens.isEmpty else { return [] }
        let ops = WordDiff.compute(old: inserted, new: edited)

        var removed = 0
        var candidates: [Replacement] = []
        var i = 0
        // Group consecutive removed/added runs into substitutions.
        while i < ops.count {
            switch ops[i] {
            case .same:
                i += 1
            case .changed(let old, let new):
                removed += 1
                // Punctuation-only `.changed` is noise; a case-only change on
                // a single token is exactly what we want to learn.
                if !Self.punctuationOnly(old, new) {
                    candidates.append(Replacement(from: old, to: new))
                }
                i += 1
            case .removed, .added:
                // Collect a removed run and the added run right after it.
                var from: [String] = [], to: [String] = []
                while i < ops.count, case .removed(let t) = ops[i] {
                    from.append(t); removed += 1; i += 1
                }
                while i < ops.count, case .added(let t) = ops[i] {
                    to.append(t); i += 1
                }
                if !from.isEmpty, !to.isEmpty,
                   from.count <= 3, to.count <= 3 {
                    candidates.append(Replacement(from: from.joined(separator: " "),
                                                  to: to.joined(separator: " ")))
                }
            }
        }
        // "Tokens changed" = inserted tokens that were removed or replaced;
        // a 1→1 substitution changes one token (not two), and tokens added
        // around the span — typing after the paste, or window slop from
        // InsertedSpan.locate — don't count against the ratio.
        guard removed <= Int((Double(insertedTokens.count) * maxChangeRatio).rounded(.up))
        else { return [] }
        return candidates
    }

    /// Both tokens identical once edge punctuation is stripped → the user only
    /// touched punctuation (e.g. "word" → "word,"), which cleanup already
    /// handles — not a learnable substitution.
    static func punctuationOnly(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .alphanumerics.inverted)
            == b.trimmingCharacters(in: .alphanumerics.inverted)
    }
}

/// Finds the pasted span inside the element's final text (T9): try the exact
/// inserted string first, then fall back to a token-anchored window near the
/// original insertion offset. Returns nil when the span can't be located —
/// the watch then aborts silently.
public enum InsertedSpan {
    /// - `inserted`: the text as pasted (separator included).
    /// - `endOffset`: UTF-16 offset of the caret right after the paste.
    /// - `value`: the element's current full text.
    public static func locate(inserted: String, endOffset: Int, in value: String) -> String? {
        // Fast path: text untouched.
        if value == inserted { return inserted }
        let ns = value as NSString
        let start = endOffset - inserted.utf16.count
        guard start >= 0, endOffset <= ns.length else { return nil }
        let verbatim = ns.substring(with: NSRange(location: start, length: inserted.utf16.count))
        if verbatim == inserted { return inserted }

        // Fuzzy path: take a token window around the original span and let
        // the diff decide. ±4 token slop covers tokens splitting/merging.
        let insertedTokens = Self.tokens(inserted)
        let editedTokens = Self.tokens(value)
        guard !insertedTokens.isEmpty else { return nil }

        // Token index nearest the original start offset.
        var anchor = 0
        for (i, t) in editedTokens.enumerated() where t.range.location <= start {
            anchor = i
        }
        let from = max(0, anchor - 1)
        let to = min(editedTokens.count, anchor + insertedTokens.count + 4)
        guard from < to else { return nil }
        let window = editedTokens[from..<to]
        let windowText = window.map(\.text).joined(separator: " ")

        // Bail when the window shares almost nothing with the insertion —
        // the user deleted or rewrote it wholesale.
        let insertedSet = Set(insertedTokens.map { $0.text.lowercased() })
        let shared = window.filter { insertedSet.contains($0.text.lowercased()) }.count
        guard Double(shared) >= Double(insertedTokens.count) * 0.5 else { return nil }
        return windowText
    }

    struct Token {
        var text: String
        var range: NSRange   // UTF-16 offsets in the source string
    }

    /// Whitespace tokens (same split as WordDiff) with UTF-16 ranges.
    static func tokens(_ s: String) -> [Token] {
        s.split(whereSeparator: { $0.isWhitespace }).map {
            Token(text: String($0),
                  range: NSRange(location: $0.startIndex.utf16Offset(in: s),
                                 length: $0.utf16.count))
        }
    }
}
