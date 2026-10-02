import AppKit
import HushCore
import Store
import SwiftUI

/// Home (DESIGN.md): 3-column tile grid — Words (span 2) + Activity,
/// Recent (span 2) + Shortcuts, then System across all three columns
/// (models left, permissions right). Rows share a height; content scrolls
/// when the window is short.
struct HomeView: View {
    @ObservedObject var model: AppModel
    var goToHistory: () -> Void = {}
    @HushReducedMotion private var reduceMotion

    /// Content column width at the default window size (784 − 2×32 − 2×12)/3.
    private static let col: CGFloat = 232
    private static let twoCols = col * 2 + Theme.Space.gridGap

    var body: some View {
        Grid(horizontalSpacing: Theme.Space.gridGap, verticalSpacing: Theme.Space.gridGap) {
            GridRow {
                wordsTile.frame(width: Self.twoCols).gridCellColumns(2)
                activityTile.frame(width: Self.col)
            }
            GridRow {
                recentTile.frame(width: Self.twoCols).gridCellColumns(2)
                shortcutsTile.frame(width: Self.col)
            }
            GridRow {
                systemTile.gridCellColumns(3)
            }
        }
    }

    // MARK: - Words

    private var wordsTile: some View {
        Tile("WORDS DICTATED", fillHeight: true, accessory: {
            Text("ALL TIME")
                .font(Theme.Font.data())
                .foregroundStyle(Theme.Color.textTertiary)
        }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(verbatim: model.stats.totalWords.formatted(.number))
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(model.stats.totalWords)))
                    .animation(Theme.Motion.response(reduceMotion), value: model.stats.totalWords)
                    .font(Theme.Font.display())
                    .tracking(-0.02 * 56)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)

                if model.stats.totalWords == 0 {
                    HStack(spacing: Theme.Space.s) {
                        Keycap(legend: "fn")
                        Text("Hold fn and start talking.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                } else {
                    HStack(spacing: Theme.Space.xl) {
                        readout("TODAY", model.stats.todayWords.formatted(.number))
                        readout("AVG WPM", String(format: "%.0f", model.stats.spokenWPM))
                        readout("TIME SAVED", Self.timeSaved(model.stats.timeSavedSeconds))
                    }
                }
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(value)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(Theme.Motion.response(reduceMotion), value: value)
                .font(Theme.Font.dataLg)
                .tracking(-0.01 * 20)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(label).tileLabel()
        }
    }

    static func timeSaved(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s <= 0 { return "0m" }
        if s < 60 { return "<1m" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - Activity

    private var activityTile: some View {
        Tile("ACTIVITY", fillHeight: true, accessory: {
            Text("12 WEEKS")
                .font(Theme.Font.data())
                .foregroundStyle(Theme.Color.textTertiary)
        }) {
            let (levels, today) = Self.heatmap(from: model.wordsPerDay)
            Heatmap(levels: levels, today: today)
                .frame(height: 7 * 15 - 3)
        }
    }

    /// 12 columns (weeks, oldest→newest) × 7 rows (Sun→Sat). Levels are
    /// quartiles over non-zero days. Returns the matrix + today's cell.
    static func heatmap(from wordsPerDay: [String: Int]) -> ([[Int]], (Int, Int)?) {
        var levels = [[Int]](repeating: [Int](repeating: 0, count: 7), count: 12)
        let calendar = Calendar.current
        let today = Date()
        let w0 = calendar.component(.weekday, from: today) - 1   // Sun = 0

        let nonzero = wordsPerDay.values.filter { $0 > 0 }.sorted()
        func level(for words: Int) -> Int {
            guard !nonzero.isEmpty, words > 0 else { return 0 }
            let idx = nonzero.firstIndex { words <= $0 } ?? (nonzero.count - 1)
            return 1 + min(3, idx * 4 / nonzero.count)
        }

        var todayCell: (Int, Int)?
        for offset in 0..<84 {
            let col = 11 - (offset - w0 + 6) / 7
            let row = ((w0 - offset) % 7 + 7) % 7
            guard col >= 0 else { break }
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let words = wordsPerDay[Self.dayKey(day)] ?? 0
            levels[col][row] = level(for: words)
            if offset == 0 { todayCell = (col, row) }
        }
        return (levels, todayCell)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - System (models left, permissions right)

    private var systemTile: some View {
        Tile("SYSTEM") {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    modelRow("Speech model", detail: "Whisper large-v3 turbo",
                             state: model.whisperStatus)
                    modelRow("Cleanup model", detail: "Qwen3 4B",
                             state: model.cleanupStatus)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    permissionRow("Microphone", granted: model.permissions.mic,
                                  pane: .microphone)
                    permissionRow("Accessibility", granted: model.permissions.accessibility,
                                  pane: .accessibility)
                    permissionRow("Input Monitoring", granted: model.permissions.inputMonitoring,
                                  pane: .inputMonitoring)
                    if model.needsRelaunch {
                        Button("Restart Hush") { model.relaunch() }
                            .buttonStyle(.hushPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func modelRow(_ name: String, detail: String, state: ModelLoadState) -> some View {
        HStack(spacing: Theme.Space.s) {
            StatusDot(level: Self.level(for: state), text: "")
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer()
            modelStateText(state)
            if case .failed = state {
                Button("Retry") { model.prepareModels() }
                    .buttonStyle(.hushSecondary)
            }
        }
    }

    @ViewBuilder
    private func modelStateText(_ state: ModelLoadState) -> some View {
        switch state {
        case .optimizing(let startedAt):
            HStack(spacing: 4) {
                Text("Optimizing")
                Text(startedAt, style: .timer)
            }
            .font(Theme.Font.data(11))
            .foregroundStyle(Theme.Color.textSecondary)
        case .downloading(let fraction):
            Text("Downloading \(Int(fraction * 100))%")
                .font(Theme.Font.data(11))
                .foregroundStyle(Theme.Color.textSecondary)
        case .ready:
            Text("Ready")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        case .failed:
            Text("Failed")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.error)
        case .loading:
            Text("Loading")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        case .notDownloaded:
            Text("Not downloaded")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    private func permissionRow(_ name: String, granted: Bool,
                               pane: AppModel.PrivacyPane) -> some View {
        HStack(spacing: Theme.Space.s) {
            StatusDot(level: granted ? .ok : .warn, text: "")
            Text(name)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            if granted {
                Text("Granted")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            } else {
                Button("Allow") { model.requestPermission(pane) }
                    .buttonStyle(.hushSecondary)
            }
        }
    }

    static func level(for state: ModelLoadState) -> StatusDot.Level {
        switch state {
        case .ready: .ok
        case .failed: .error
        case .notDownloaded: .idle
        default: .idle   // loading/optimizing/downloading = in progress
        }
    }

    // MARK: - Shortcuts

    private var shortcutsTile: some View {
        Tile("SHORTCUTS", fillHeight: true) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                shortcutRow(keys: ["fn"], label: "Hold to talk")
                shortcutRow(keys: ["⌥", "⌥"], label: "Toggle")
                shortcutRow(keys: ["esc"], label: "Cancel")
                shortcutRow(keys: ["⌃", "⌥", "Z"], label: "Paste raw")
            }
        }
    }

    private func shortcutRow(keys: [String], label: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(keys, id: \.self) { Keycap(legend: $0) }
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
        }
    }

    // MARK: - Recent

    private var recentTile: some View {
        Tile("RECENT", fillHeight: true, accessory: {
            Button("View all") { goToHistory() }
                .buttonStyle(.hushGhost)
                .font(Theme.Font.caption)
        }) {
            if model.recentDictations.isEmpty {
                Text("Nothing yet.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentDictations) { record in
                        HistoryRow(
                            time: Self.time(record.createdAt),
                            appName: record.appName,
                            appIcon: Self.appIcon(record.appBundleID),
                            text: record.cleanedText,
                            isExpanded: false,
                            onCopy: { Self.copy(record.cleanedText) },
                            onPlay: { model.togglePlayback(record) }
                        )
                    }
                }
            }
        }
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static var iconCache: [String: Image] = [:]
    static func appIcon(_ bundleID: String?) -> Image? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        let image = Image(nsImage: icon)
        iconCache[bundleID] = image
        return image
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
