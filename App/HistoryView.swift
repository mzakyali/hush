import HushCore
import Store
import SwiftUI

/// History (DESIGN.md): search field top-right, day-grouped sections of
/// list rows; click a row for inline expansion (cleaned text, RAW, audio
/// player + actions). Empty state: centred flat dot-matrix line + hint.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @HushReducedMotion private var reduceMotion
    @State private var search = ""
    @State private var expandedID: String?
    @State private var pendingDelete: Dictation?

    init(model: AppModel, initialExpandedID: String? = nil) {
        self.model = model
        _expandedID = State(initialValue: initialExpandedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(Theme.Font.title)
                    .tracking(-0.01 * 22)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                searchField
            }
            .padding(.bottom, Theme.Space.xl)

            if model.dictations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    listContent
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(Theme.Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.Motion.response(reduceMotion), value: expandedID)
        .onAppear { model.reloadData(search: search) }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let record = pendingDelete {
                    expandedID = nil
                    model.deleteDictation(record)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cleaned text, raw transcript and audio are deleted permanently.")
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textTertiary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .onChange(of: search) { _, new in
                    model.historySearch = new
                    model.reloadData(search: new)
                }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(width: 240, height: 32)
        .background(Theme.Color.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private var listContent: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.s, pinnedViews: []) {
            ForEach(grouped, id: \.0) { (header, records) in
                section(header: header, records: records)
            }
        }
    }

    // MARK: - grouping

    private var grouped: [(String, [Dictation])] {
        var out: [(String, [Dictation])] = []
        var day = ""
        for record in model.dictations {
            let d = Self.dayKey(record.createdAt)
            if d != day {
                day = d
                out.append((Self.header(for: record.createdAt), [record]))
            } else {
                out[out.count - 1].1.append(record)
            }
        }
        return out
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func header(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    private func section(header: String, records: [Dictation]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(header)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text("\(records.count)")
                    .font(Theme.Font.data())
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(.top, Theme.Space.m)

            VStack(spacing: 0) {
                ForEach(records) { record in
                    if expandedID == record.id {
                        expandedCard(record)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    } else {
                        Button {
                            withAnimation(Theme.Motion.response(reduceMotion)) {
                                expandedID = record.id
                            }
                        } label: {
                            HistoryRow(
                                time: HomeView.time(record.createdAt),
                                appName: record.appName,
                                appIcon: HomeView.appIcon(record.appBundleID),
                                text: record.cleanedText,
                                isExpanded: false,
                                onCopy: { HomeView.copy(record.cleanedText) },
                                onPlay: { model.togglePlayback(record) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - expanded card

    /// One continuous `surface.raised` container: the row line on top (time,
    /// icon, cleaned text wrapped in full — click to collapse), then RAW +
    /// raw text, the dot-matrix player and the action row.
    private func expandedCard(_ record: Dictation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                withAnimation(Theme.Motion.response(reduceMotion)) { expandedID = nil }
            } label: {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Text(HomeView.time(record.createdAt))
                        .font(Theme.Font.data(12))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(width: 44, alignment: .leading)
                    if let icon = HomeView.appIcon(record.appBundleID) {
                        icon
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Color.textTertiary)
                            .frame(width: 16, height: 16)
                    }
                    Text(record.cleanedText)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // Raw and cleaned are identical most of the time — Whisper's
                // output is already punctuated and the cleanup fast path skips
                // the LLM — so a second identical block reads as a bug. Show a
                // chip instead; show the word-level diff when they differ.
                if record.cleanedText == record.rawText {
                    cleanupChip(fellBack: record.cleanupFallback)
                } else {
                    Text("CHANGES").tileLabel()
                    diffText(record)
                }

                if record.audioPath != nil {
                    audioPlayer(record)
                }

                HStack(spacing: Theme.Space.s) {
                    Button("Copy") { HomeView.copy(record.cleanedText) }
                        .buttonStyle(.hushSecondary)
                    if record.cleanedText != record.rawText {
                        Button("Copy raw") { HomeView.copy(record.rawText) }
                            .buttonStyle(.hushSecondary)
                    }
                    Spacer()
                    Button("Delete") { pendingDelete = record }
                        .buttonStyle(.hushGhost)
                        .foregroundStyle(Theme.Color.error)
                }
            }
            .padding(.leading, 44 + Theme.Space.m + 16)  // under the text column
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    /// Shown when raw == cleaned: the LLM wasn't needed, or it fell back.
    private func cleanupChip(fellBack: Bool) -> some View {
        Text(fellBack ? "CLEANUP FELL BACK" : "NO CLEANUP NEEDED")
            .tileLabel()
            .foregroundStyle(fellBack ? Theme.Color.warn : Theme.Color.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 4)
            .background(Theme.Color.tile, in: Capsule())
            .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 1))
    }

    /// Word-level raw→cleaned diff (WordDiff): removed words struck out in
    /// tertiary, added words in signal, unchanged in secondary.
    private func diffText(_ record: Dictation) -> Text {
        var out = Text("")
        for op in WordDiff.compute(old: record.rawText, new: record.cleanedText) {
            switch op {
            case .same(let word):
                out = out + Text("\(word) ")
                    .foregroundStyle(Theme.Color.textSecondary)
            case .removed(let word):
                out = out + Text("\(word) ")
                    .foregroundStyle(Theme.Color.textTertiary)
                    .strikethrough()
            case .added(let word):
                out = out + Text("\(word) ")
                    .foregroundStyle(Theme.Color.signal)
            case .changed(_, let new):
                // A case/punctuation swap — just the new word, no struck twin.
                out = out + Text("\(new) ")
                    .foregroundStyle(Theme.Color.signal)
            }
        }
        return out.font(Theme.Font.caption)
    }

    /// Play/pause + dot-matrix scrubber: one row of dots, played = text.primary.
    private func audioPlayer(_ record: Dictation) -> some View {
        let isPlaying = model.playingDictationID == record.id
        let progress = isPlaying ? model.playbackProgress : 0
        return HStack(spacing: Theme.Space.m) {
            Button {
                model.togglePlayback(record)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.hushGhost)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Scrubber(progress: progress)
                .frame(maxWidth: 200)
                .frame(height: 12)
        }
    }

    // MARK: - empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            // Flat lit centre line — the silence waveform.
            DotMatrix(columns: [Double](repeating: 1, count: 23),
                      rows: 1, dot: 3.5, gap: 2.5)
                .frame(width: 23 * 6 - 2.5, height: 3.5)
            Text("Your dictations will show up here.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
            HStack(spacing: Theme.Space.s) {
                Text("Hold")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Keycap(legend: "fn")
                Text("and start talking.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Theme.Space.huge)
    }
}

/// One row of dots as a playback scrubber.
struct Scrubber: View {
    var progress: Double   // 0…1
    var columns: Int = 34
    var dot: CGFloat = 3.5
    var gap: CGFloat = 2.5

    var body: some View {
        Canvas { ctx, size in
            let pitch = dot + gap
            let w = CGFloat(columns) * pitch - gap
            let ox = (size.width - w) / 2
            let played = Int((progress * Double(columns)).rounded())
            for c in 0..<columns {
                let rect = CGRect(x: ox + CGFloat(c) * pitch,
                                  y: (size.height - dot) / 2,
                                  width: dot, height: dot)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(c < played ? Theme.Color.textPrimary : Theme.Color.dotOff))
            }
        }
    }
}
