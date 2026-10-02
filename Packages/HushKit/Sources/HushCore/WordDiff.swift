import Foundation

/// Word-level diff between a raw transcript and its cleaned text (History UI).
/// Whitespace-token LCS: words that survive cleanup render as `.same`, words the
/// cleaner dropped as `.removed`, and words it added/changed to as `.added`.
public enum WordDiff {
    public enum Op: Sendable, Equatable {
        case same(String)
        case removed(String)
        case added(String)
        /// A removed word replaced by a case/punctuation variant of itself
        /// (`ship`→`Ship`, `off`→`off.`) — rendered as the new word alone.
        case changed(old: String, new: String)
    }

    public static func compute(old: String, new: String) -> [Op] {
        let a = old.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = new.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !a.isEmpty, !b.isEmpty else {
            return coalesce(a.map { .removed($0) } + b.map { .added($0) })
        }
        // Longest-common-subsequence table, filled bottom-up.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                         count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                ops.append(.same(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.removed(a[i]))
                i += 1
            } else {
                ops.append(.added(b[j]))
                j += 1
            }
        }
        while i < a.count { ops.append(.removed(a[i])); i += 1 }
        while j < b.count { ops.append(.added(b[j])); j += 1 }
        return coalesce(ops)
    }

    /// A `.removed` immediately followed by an `.added` whose tokens match
    /// after lowercasing and stripping edge punctuation is one change, not a
    /// deletion plus an insertion — a struck-out twin adds noise.
    private static func coalesce(_ ops: [Op]) -> [Op] {
        var out: [Op] = []
        var i = 0
        while i < ops.count {
            if case .removed(let old) = ops[i],
               i + 1 < ops.count, case .added(let new) = ops[i + 1] {
                let o = normalized(old), n = normalized(new)
                if !o.isEmpty, o == n {
                    out.append(.changed(old: old, new: new))
                    i += 2
                    continue
                }
            }
            out.append(ops[i])
            i += 1
        }
        return out
    }

    /// Case + leading/trailing punctuation are cleanup's most common edits:
    /// normalise them away to recognise a word swap.
    private static func normalized(_ token: String) -> String {
        token.lowercased()
            .trimmingCharacters(in: .alphanumerics.inverted)
    }
}
