import Foundation

/// Pure device-selection rules for spec §4a (plan T12). `known` is the persisted,
/// user-reorderable priority list of CoreAudio UIDs (top = highest).
public enum MicSelector {
    /// The UID Hush should record from:
    /// - a pinned device that is still connected always wins;
    /// - otherwise the first connected device in `known` order;
    /// - `nil` = fall back to the macOS system default input.
    public static func resolve(
        known: [String],
        connected: Set<String>,
        pinned: String?
    ) -> String? {
        if let pinned, connected.contains(pinned) { return pinned }
        return known.first { connected.contains($0) }
    }

    /// Reconcile the persisted priority list with devices seen now: keeps the
    /// existing order and appends newly seen UIDs at the bottom.
    public static func merge(known: [String], seen: [String]) -> [String] {
        var out = known
        for uid in seen where !out.contains(uid) {
            out.append(uid)
        }
        return out
    }
}
