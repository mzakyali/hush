import Foundation
import HushCore

/// One deterministic replacement rule (§5): `from → to`, from a
/// `dictionary_entries` row. `entryID` links back for `hitCount`.
public struct ReplacementRule: Sendable, Equatable {
    public var entryID: String?
    public var from: String
    public var to: String

    public init(entryID: String? = nil, from: String, to: String) {
        self.entryID = entryID
        self.from = from
        self.to = to
    }
}

/// Applies the replacement list — whole-word, case-insensitive, longest
/// `from` first (plan T8). The App's model refreshes the snapshot after any
/// dictionary change; the pipeline's `replacements` hook calls `apply`
/// before and after cleanup, synchronously.
public final class ReplacementEngine: @unchecked Sendable {
    private let lock = NSLock()
    /// Longest `from` first so "super base" wins over "base".
    private var rules: [ReplacementRule] = []
    /// ASR prompt + cleanup `{terms}` vocabulary: terms and replacement `to`s.
    private var terms: [String] = []
    /// entryID → number of replacements made since the last `takeHits`.
    private var hits: [String: Int] = [:]

    public init() {}

    public func update(rules: [ReplacementRule], terms: [String]) {
        let sorted = rules.sorted { $0.from.count > $1.from.count }
        lock.withLock {
            self.rules = sorted
            self.terms = terms
        }
    }

    /// Every term fed to Whisper prompt tokens and the cleanup `{terms}` line.
    public var dictionaryTerms: [String] { lock.withLock { terms } }

    /// Replace every whole-word, case-insensitive occurrence of each rule's
    /// `from` with `to`. Returns the rewritten text; hit counts accumulate
    /// for `takeHits`.
    public func apply(_ text: String) -> String {
        var result = text
        for rule in lock.withLock({ rules }) {
            var hits = 0
            result = Self.rewrite(result, from: rule.from, to: rule.to, hits: &hits)
            if hits > 0, let id = rule.entryID {
                lock.withLock { self.hits[id, default: 0] += hits }
            }
        }
        return result
    }

    /// Drain accumulated per-entry hit counts.
    public func takeHits() -> [String: Int] {
        lock.withLock { let h = hits; hits = [:]; return h }
    }

    // MARK: - matching

    /// Characters that can sit inside a word — a match touching one of these
    /// is a substring, not a whole word ("gw" inside "gwen", "don" inside
    /// "don't"). Everything else (whitespace, punctuation) is a boundary.
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "'" || c == "’"
    }

    static func rewrite(_ text: String, from: String, to: String,
                        hits: inout Int) -> String {
        guard !from.isEmpty, !text.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        var applied = 0
        while let range = result.range(of: from, options: .caseInsensitive,
                                       range: searchStart..<result.endIndex) {
            let leftOK = range.lowerBound == result.startIndex
                || !isWordChar(result[result.index(before: range.lowerBound)])
            let rightOK = range.upperBound == result.endIndex
                || !isWordChar(result[range.upperBound])
            if leftOK, rightOK {
                result.replaceSubrange(range, with: to)
                applied += 1
                searchStart = result.index(range.lowerBound,
                                           offsetBy: to.count)
            } else {
                searchStart = range.upperBound
            }
        }
        hits += applied
        return result
    }
}
