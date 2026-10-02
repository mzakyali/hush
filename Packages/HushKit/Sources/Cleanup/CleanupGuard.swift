import Foundation
import HushCore
import OSLog

private let cleanupLog = Logger(subsystem: "com.local.hush", category: "cleanup")

/// Post-validation of cleanup output (spec §4 invariant: cleanup must never drop content).
///
/// Let `r = words(clean) / words(raw)`; if `r < 0.4 || r > 1.5`, output is empty, generation
/// throws, or exceeds 8 s → use rule-processed raw and mark `cleanupFallback`.
/// A leading/trailing `<transcript>` tag or wrapping quotes the model echoes are stripped first.
public enum CleanupGuard {
    public static let lowerRatio = 0.4
    public static let upperRatio = 1.5
    /// Coverage floor: fallback when at or below this fraction of raw content tokens
    /// survive in the output.
    public static let minCoverage = 0.75

    /// Fillers/hesitations removed from the raw side before coverage is measured.
    static let fillerTokens: Set<String> = ["um", "uh", "er", "eh", "em", "emm", "anu", "hmm", "mm"]

    /// Discourse markers / enumeration words the model may legitimately drop when it
    /// formats output (e.g. numbered lists). Never include self-correction markers
    /// ("no", "nggak", "bukan") — dropping those would mask a real content loss.
    static let droppableTokens: Set<String> = [
        "okay", "ok", "so", "well", "and",
        "first", "second", "third", "fourth", "fifth",
        "firstly", "secondly", "thirdly", "lastly", "finally",
        "pertama", "kedua", "ketiga", "terus", "jadi", "gini",
    ]

    /// Self-correction markers. The token *preceding* one is the phrase the speaker
    /// corrected away ("thursday, no, friday") — legitimately dropped by cleanup.
    /// The markers themselves are NOT excluded, so a dropped negation still counts.
    static let correctionMarkers: Set<String> = ["no", "nggak", "bukan"]

    /// Normalize and validate model output. Returns the cleaned text, or nil to fall back.
    public static func normalize(_ output: String, raw: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip an echoed <transcript>…</transcript> wrapper.
        if text.hasPrefix("<transcript>"), text.hasSuffix("</transcript>") {
            text = String(text.dropFirst("<transcript>".count).dropLast("</transcript>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip wrapping quotes (plain or smart).
        for quote in ["\"", "'", "“", "‘"] where text.count >= 2 {
            let closer = quote == "“" ? "”" : quote == "‘" ? "’" : quote
            if text.hasPrefix(quote), text.hasSuffix(closer) {
                text = String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !text.isEmpty else { return nil }
        let rawWords = wordCount(raw)
        guard rawWords > 0 else { return text }  // nothing to compare against
        let ratio = Double(wordCount(text)) / Double(rawWords)
        guard ratio >= lowerRatio, ratio <= upperRatio else { return nil }
        // Coverage must *exceed* minCoverage: a content-bearing raw can sit exactly
        // at 0.75 while still having dropped a trailing phrase.
        if let coverage = contentCoverage(raw: raw, output: text), coverage <= minCoverage {
            return nil
        }
        return text
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Lowercased, punctuation-trimmed word tokens.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Fraction of raw content (non-filler) tokens found in the output, each output
    /// token consumed once (multiset match). nil when raw has no content tokens.
    public static func contentCoverage(raw: String, output: String) -> Double? {
        let all = tokens(raw)
        let restartedTokens = repeatedStartTokens(raw)
        var rawTokens: [String] = []
        rawTokens.reserveCapacity(all.count)
        for (i, token) in all.enumerated() {
            if restartedTokens.contains(i) || fillerTokens.contains(token) || droppableTokens.contains(token) { continue }
            if i + 1 < all.count, correctionMarkers.contains(all[i + 1]) { continue }
            rawTokens.append(token)
        }
        guard !rawTokens.isEmpty else { return nil }
        var outputCounts: [String: Int] = [:]
        for token in tokens(output) { outputCounts[token, default: 0] += 1 }
        var matched = 0
        for token in rawTokens {
            if let n = outputCounts[token], n > 0 {
                outputCounts[token] = n - 1
                matched += 1
            }
        }
        return Double(matched) / Double(rawTokens.count)
    }

    /// Exempt only an explicitly paused, repeated 1–4-word start around a cue.
    /// "the … sorry … the side panel" retains one "the"; a genuine apology or
    /// a repeated word without a cue still counts toward content coverage.
    private static func repeatedStartTokens(_ text: String) -> Set<Int> {
        let original = text.lowercased().split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.trimmingCharacters(in: .punctuationCharacters).isEmpty }
        let words = original.map { $0.trimmingCharacters(in: .punctuationCharacters) }
        var removed: Set<Int> = []
        for cue in correctionCues where words.count >= cue.count + 2 {
            for i in 1 ..< words.count - cue.count
            where words[i ..< i + cue.count].elementsEqual(cue) {
                // A repeated pronoun alone is not evidence of a restart:
                // "I'm sorry I'm late" is a real apology. Require an ASR pause.
                guard original[i - 1].hasSuffix("...") || original[i - 1].hasSuffix("…") else { continue }
                let after = i + cue.count
                let maxLength = min(4, i, words.count - after)
                for length in (1 ... maxLength).reversed()
                where words[i - length ..< i].elementsEqual(words[after ..< after + length]) {
                    removed.formUnion(i - length ..< after)
                    break
                }
            }
        }
        return removed
    }

    /// Self-correction phrases — the speaker restating what they just said.
    /// Bare "no"/"bukan" are excluded: they're ordinary words, not cues.
    static let correctionCues: [[String]] = [
        ["i", "mean"], ["no", "wait"], ["sorry"],
        ["maksudnya"], ["maksud", "saya"], ["eh", "maksud", "saya"],
    ]

    /// True when rule-processed text has nothing for the cleanup LLM to fix:
    /// no filler tokens, no back-to-back repeated word or 2–4-word phrase, and
    /// no self-correction cue. Whisper output is already punctuated, so clean
    /// input can skip the model entirely.
    public static func isClean(_ text: String) -> Bool {
        let tokens = tokens(text)
        guard !tokens.isEmpty else { return true }

        for cue in correctionCues where cue.count <= tokens.count {
            if cue.count == 1 {
                if tokens.contains(cue[0]) { return false }
            } else {
                for i in 0 ... tokens.count - cue.count
                where tokens[i ..< i + cue.count].elementsEqual(cue) {
                    return false
                }
            }
        }
        for token in tokens where fillerTokens.contains(token) {
            return false
        }
        // Back-to-back repeated n-gram (n = 1…4): "the the",
        // "prosesnya sangat lalu prosesnya sangat lalu".
        for n in 1 ... 4 where tokens.count >= 2 * n {
            for i in 0 ... tokens.count - 2 * n
            where tokens[i ..< i + n].elementsEqual(tokens[i + n ..< i + 2 * n]) {
                return false
            }
        }
        return true
    }
}

public enum CleanupTimeoutError: Swift.Error {
    case timedOut
}

/// Wraps any `Cleaner` with the 8-second timeout and the `CleanupGuard` fallback rule.
public actor GuardedCleaner: FallbackReportingCleaner, CleanupStatsReporting {
    public static let defaultTimeout: TimeInterval = 8

    private let inner: any Cleaner
    private let timeout: TimeInterval
    public private(set) var lastCleanupFellBack = false
    public private(set) var lastCleanupRun: CleanupRunInfo?

    public init(_ inner: any Cleaner, timeout: TimeInterval = GuardedCleaner.defaultTimeout) {
        self.inner = inner
        self.timeout = timeout
    }

    public func prepare() async throws {
        try await inner.prepare()
    }

    /// `raw` must already be rule-processed (replacements applied); on fallback it is
    /// returned unchanged, per spec.
    public func clean(_ raw: String, style: CleanupStyle, terms: [String]) async throws -> String {
        // Fast path: Whisper's output is already punctuated, so text with no
        // fillers/repeats/corrections has nothing for the LLM to fix. Formal
        // style always runs — it's a rewrite, not a cleanup.
        if style != .formal, CleanupGuard.isClean(raw) {
            lastCleanupFellBack = false
            lastCleanupRun = CleanupRunInfo(usedLLM: false)
            cleanupLog.info("cleanup → skipped (clean input)")
            return raw
        }
        do {
            let output = try await withTimeout(timeout) {
                try await self.inner.clean(raw, style: style, terms: terms)
            }
            if let text = CleanupGuard.normalize(output, raw: raw) {
                lastCleanupFellBack = false
                await recordRunStats()
                return text
            }
        } catch {
            // Any failure (throw, timeout) falls back below.
        }
        lastCleanupFellBack = true
        await recordRunStats()
        return raw
    }

    private func recordRunStats() async {
        if let mlx = inner as? MLXCleaner, let stats = await mlx.lastRunStats {
            lastCleanupRun = CleanupRunInfo(
                usedLLM: true,
                promptTokens: stats.promptTokens + stats.cachedPrefixTokens,
                generatedTokens: stats.generatedTokens)
        } else {
            lastCleanupRun = CleanupRunInfo(usedLLM: true)
        }
    }
}

/// Race an async operation against a timeout; the loser is cancelled.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CleanupTimeoutError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
