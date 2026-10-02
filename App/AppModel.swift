import AppKit
import AudioCapture
import AVFoundation
import Cleanup
import Dictionary
import EditWatcher
import HushCore
import HotkeyService
import Insertion
import OSLog
import Store
import SwiftUI
import Transcription

private let modelLog = Logger(subsystem: "com.local.hush", category: "models")
private let appLog = Logger(subsystem: "com.local.hush", category: "app")

/// Set-once indirection so `PipelineHooks.didFinish` (installed at pipeline
/// init time) can reach the AppModel once it exists.
private final class FinishRelay: @unchecked Sendable {
    var body: (@MainActor (DictationResult) async -> Void)?
    func run(_ result: DictationResult) async { await body?(result) }
}

/// The single AppModel. MenuBarExtra content is built lazily, so the model is
/// owned by this singleton and created from `applicationDidFinishLaunching` —
/// not by the menu's `.task` (which may never run until the menu is clicked).
enum SharedAppModel {
    nonisolated static let model = AppModel()
}

/// App wiring: hotkeys → DictationPipeline → overlay/inserter, plus the
/// GRDB store, permissions status and the main-window controller.
@MainActor
final class AppModel: ObservableObject {
    private let paths = AppPaths()

    let pipeline: DictationPipeline
    private let recorder = AudioRecorder()
    private let transcriber: WhisperTranscriber
    private let cleaner: GuardedCleaner
    private let inserter: Inserter
    private let hotkeys = HotkeyService()
    private var didStart = false

    // Pipeline/menu state.
    @Published var pipelineState: DictationPipeline.State = .idle
    @Published var micName: String?
    @Published var lastError: String?
    @Published var whisperStatus: ModelLoadState = .notDownloaded
    @Published var cleanupStatus: ModelLoadState = .notDownloaded

    // Hot UI state lives on focused feeds (StateFeeds.swift) so views that
    // don't read it don't re-evaluate on every level tick or animation frame:
    // RecordingFeed ~12 Hz during dictation, SidePanelGeometry per hover
    // frame, PlaybackFeed 10 Hz during audio playback.
    let recording = RecordingFeed()
    let geometry = SidePanelGeometry()
    let playback = PlaybackFeed()

    // Store + history.
    let store: DictationStore?
    @Published var dictations: [Dictation] = []
    @Published var recentDictations: [Dictation] = []
    @Published var stats = DictationStats()
    /// "YYYY-MM-DD" → words, for the Activity heatmap (last 84 days).
    @Published var wordsPerDay: [String: Int] = [:]
    var historySearch = ""   // bound in HistoryView

    // Dictionary (§5) + edit learning (§6). The engine is a plain locked
    // class — the pipeline's sync `terms`/`replacements` hooks read it
    // directly; `dictEntries`/`pendingSuggestions` back the UI and refresh
    // together in `refreshData`.
    private let replacementEngine = ReplacementEngine()
    private let editWatcher = EditWatcher()
    @Published var dictEntries: [DictionaryEntry] = []
    @Published var pendingSuggestions: [Suggestion] = []

    // Permissions.
    struct Permissions {
        var mic = false
        var accessibility = false
        var inputMonitoring = false
    }
    @Published var permissions = Permissions()
    /// True when the event tap can't start even though AX + Input Monitoring
    /// are granted — the only fix is a fresh process.
    @Published var needsRelaunch = false
    private var permissionPollTask: Task<Void, Never>?

    @Published var retentionDays: Int = {
        let stored = UserDefaults.standard.integer(forKey: "retentionDays")
        return stored > 0 ? stored : AppModel.defaultRetentionDays
    }() {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }
    nonisolated static let defaultRetentionDays = 30
    nonisolated static let typingWPM = 40.0

    // Presentation surfaces — Dock, menu-bar extra, side panel. The side panel
    // is the primary affordance; the menu bar is off by default. At least
    // one must stay enabled (the Settings toggles enforce it).
    @Published var showInDock: Bool =
        UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            (NSApp.delegate as? AppDelegate)?.applyActivationPolicy()
        }
    }
    @Published var showSidePanel: Bool =
        UserDefaults.standard.object(forKey: "showSidePanel") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showSidePanel, forKey: "showSidePanel")
            syncSidePanelVisibility()
        }
    }
    /// "Sliver when idle" — the resting panel shrinks to a 6 pt hairline.
    @Published var sidePanelSliver: Bool =
        UserDefaults.standard.bool(forKey: "sidePanelSliver") {
        didSet {
            UserDefaults.standard.set(sidePanelSliver, forKey: "sidePanelSliver")
            edgePanel.relayout()
        }
    }
    @Published var showInMenuBar: Bool =
        UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    /// Side-panel dot states: pulse while either model is still coming up.
    var modelsLoading: Bool {
        switch (whisperStatus, cleanupStatus) {
        case (.ready, .ready): return false
        case (.failed, _), (_, .failed): return false
        default: return true
        }
    }
    /// Side-panel error dot: a permission is missing or a model failed.
    var needsAttention: Bool {
        missingPermissionCount > 0 || modelsFailed
    }

    var modelStatus: String {
        "Speech: \(whisperStatus.label) · Cleanup: \(cleanupStatus.label)"
    }
    var modelsFailed: Bool {
        if case .failed = whisperStatus { return true }
        if case .failed = cleanupStatus { return true }
        return false
    }

    /// A local file load that runs > 3 s is treated as first-run Core ML
    /// optimization (ANE compile), surfaced as `.optimizing` with elapsed time.
    private static let optimizingThreshold: Duration = .seconds(3)
    private var whisperLoading = false
    private var cleanupLoading = false

    private let mlxCleaner: MLXCleaner
    lazy var overlay = OverlayWindowController(model: self)
    lazy var edgePanel = EdgePanelController(model: self)
    lazy var mainWindow = MainWindowController(model: self)

    // Microphone priority (spec §4a, plan T12): persisted ordered UIDs + pin.
    // The pipeline's `deviceUIDs` hook reads this store at recording start, so
    // a device switch never happens mid-recording.
    let micStore: MicStore
    private var deviceMonitor: DeviceListMonitor?
    /// Injectable for snapshot rendering; production = CoreAudio.
    var listInputDevices: () -> [InputDevice] = { AudioDevices.list() }
    /// Every device Hush has seen, in priority order, with live isConnected flags.
    @Published var inputDevices: [InputDevice] = []
    /// Name of the device the next recording would use under the current pin
    /// and priority order ("Automatic" resolution, or the system default).
    @Published var resolvedMicName: String?

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    nonisolated init() {
        let transcriber = WhisperTranscriber(modelsDirectory: paths.modelsWhisper)
        self.transcriber = transcriber
        let innerCleaner = MLXCleaner(modelsDirectory: paths.modelsLLM)
        cleaner = GuardedCleaner(innerCleaner)
        mlxCleaner = innerCleaner
        inserter = Inserter(notify: { message in
            UserNotifications.post(message)
        }, onPasted: { [editWatcher] text, element, endOffset, pid in
            // §6 edit learning: watch the element the paste landed in.
            // No end offset (or pid) → no anchor → skip silently.
            guard let endOffset, let pid else { return }
            editWatcher.watch(element: InsertedElement(element), pid: pid,
                              inserted: text, endOffset: endOffset)
        })
        // Snapshot mode renders UI offscreen against an in-memory store only;
        // the mic store likewise must not write UserDefaults there.
        let snapshot = CommandLine.arguments.contains("--render-snapshots")
        if snapshot {
            store = try? DictationStore(inMemoryAt: nil)
        } else {
            store = try? DictationStore(paths: self.paths)
        }
        if store == nil {
            appLog.error("store failed to open at \(self.paths.database.path, privacy: .public)")
        }
        // Local constant — the hooks closure can't capture `self.micStore`
        // before every stored property is initialized.
        let mics = MicStore(defaults: snapshot ? nil : .standard)
        micStore = mics

        // The pipeline's `hooks` is a let, and self can't be captured before
        // every stored property is initialized — so completion goes through a
        // relay whose body is wired up right after the pipeline exists.
        let finish = FinishRelay()
        let engine = replacementEngine
        var hooks = PipelineHooks()
        // §5/T8: dictionary terms feed ASR prompt tokens + the cleanup
        // {terms} line; replacements run before AND after cleanup.
        hooks.terms = { engine.dictionaryTerms }
        hooks.replacements = { engine.apply($0) }
        hooks.deviceUIDs = { mics.candidates() }
        hooks.didFinish = { result in await finish.run(result) }
        // §3.7/T10: resolve the cleanup style against the app captured at
        // stop — the pipeline passes the same bundleID the insert targets.
        hooks.style = { [store] bundleID in
            guard let store else { return .default }
            let overrides = ((try? await store.styleOverrides()) ?? [])
                .reduce(into: [String: CleanupStyle]()) {
                    $0[$1.bundleID] = CleanupStyle(rawValue: $1.style) ?? .default
                }
            return StyleResolver.resolve(bundleID: bundleID, overrides: overrides)
        }
        pipeline = DictationPipeline(
            recorder: recorder,
            transcriber: transcriber,
            cleaner: cleaner,
            inserter: inserter,
            hooks: hooks
        )
        finish.body = { [weak self] result in
            await self?.saveDictation(result)
        }

        // Mid-recording input failures (a config-change restart that couldn't
        // recover) are surfaced here; stop() still salvages whatever it got.
        recorder.setErrorHandler { error in
            Task { @MainActor in
                appLog.error("audio input failed mid-recording: \(error.localizedDescription, privacy: .public)")
                UserNotifications.post("Mic input was interrupted — keeping what was captured")
            }
        }
    }

    /// Idempotent — invoked from both the main window and the menu bar.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Overlay interaction switches with the pill's state (the old didSet).
        recording.onOverlayStateChange = { [weak self] in
            self?.overlay.syncInteraction()
        }

        if SnapshotRunner.requested {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            Task {
                await SnapshotRunner.renderAll(model: self)
                exit(0)
            }
            return
        }

        NSApp.appearance = NSAppearance(named: .darkAqua)
        checkBundledFonts()
        try? paths.createDirectories()

        // Global hotkeys (requires Input Monitoring — a [user] permission step).
        do {
            try hotkeys.start()
        } catch {
            lastError = "Hotkey tap failed — grant Input Monitoring in System Settings"
        }
        Task { [weak self, hotkeys] in
            for await event in hotkeys.events {
                appLog.debug("hotkey received: \(String(describing: event), privacy: .public)")
                await self?.pipeline.handle(event)
            }
        }
        Task { [weak self, pipeline] in
            for await update in pipeline.updates {
                self?.apply(update)
            }
        }

        // §6: the watcher reports (from, to) edits → suggestion state machine.
        Task { [weak self, editWatcher] in
            await editWatcher.setOnCandidates { pairs in
                Task { @MainActor in self?.recordObservedEdits(pairs) }
            }
        }

        refreshPermissions()
        startPermissionPolling()

        // Mic priority (§4a): fold the live device list into the persisted
        // order at launch, then re-resolve on every connect/disconnect.
        refreshDevices()
        deviceMonitor = DeviceListMonitor { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }

        syncSidePanelVisibility()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.overlay.reposition()
                self?.edgePanel.reposition()
            }
        }

        // Retention: at launch, then every 24 h.
        applyRetention()
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 3600))
                guard !Task.isCancelled else { return }
                self?.applyRetention()
            }
        }

        reloadData()

        // Warm both models in the background, concurrently.
        prepareModels()

        #if DEBUG
        startSyntheticLevelsIfRequested()
        #endif
    }

    #if DEBUG
    /// `--hush-synth-levels` — drive the hot recording-level path without a mic:
    /// pill in `.recording` on-screen, ~12 Hz sine levels through `pushLevel`,
    /// pipelineState `.recording`. Used to sample main-thread render cost
    /// before/after the hot-state feed split. Debug-only.
    private var synthLevelTask: Task<Void, Never>?
    private func startSyntheticLevelsIfRequested() {
        guard CommandLine.arguments.contains("--hush-synth-levels") else { return }
        pipelineState = .recording
        micName = "Synthetic levels"
        recording.overlayState = .recording
        recording.overlayPhase = .visible
        overlay.show()
        // Measurement setup mirrors real use: main window open, side panel up.
        openMainWindow()
        syncSidePanelVisibility()
        var tick = 0
        synthLevelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick += 1
                self.pushLevel(Float(max(0, 0.5 + 0.45 * sin(Double(tick) * 0.45))))
                try? await Task.sleep(for: .milliseconds(83))
            }
        }
    }
    #endif

    func openMainWindow(page: MainPage? = nil) {
        if let page { mainWindow.navigate(to: page) }
        mainWindow.show()
    }

    // MARK: - Fonts

    private func checkBundledFonts() {
        for name in ["GeistMono-Regular", "GeistMono-Medium", "InstrumentSerif-Regular"] {
            if NSFont(name: name, size: 13) != nil {
                appLog.info("font resolved: \(name, privacy: .public)")
            } else {
                appLog.error("font NOT resolved: \(name, privacy: .public)")
            }
        }
    }

    // MARK: - Models

    /// Kick off (or retry) loading for whichever models aren't ready.
    func prepareModels() {
        Task { await loadTranscriber() }
        Task { await loadCleaner() }
    }

    private func loadTranscriber() async {
        guard !whisperLoading else { return }
        whisperLoading = true
        defer { whisperLoading = false }
        let started = Date()
        let local = await transcriber.hasLocalModel
        whisperStatus = local ? .loading : .downloading(0)
        if !local {
            await transcriber.setProgressHandler { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    // At 100% the model is on disk; the remaining time is the
                    // local load (possibly a first-run ANE compile).
                    self.whisperStatus = fraction >= 1 ? .loading : .downloading(fraction)
                }
            }
        }
        // A slow load is first-run Core ML optimization (ANE compile).
        let watcher = watchForOptimize(started, into: \.whisperStatus)
        do {
            try await transcriber.prepare()
            whisperStatus = .ready
        } catch {
            whisperStatus = .failed(error.localizedDescription)
        }
        watcher.cancel()
        modelLog.info("whisper → \(self.whisperStatus.label, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
    }

    private func loadCleaner() async {
        guard !cleanupLoading else { return }
        cleanupLoading = true
        defer { cleanupLoading = false }
        let started = Date()
        let local = await mlxCleaner.hasLocalModel
        cleanupStatus = local ? .loading : .downloading(0)
        if !local {
            await mlxCleaner.setProgressHandler { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.cleanupStatus = fraction >= 1 ? .loading : .downloading(fraction)
                }
            }
        }
        let watcher = watchForOptimize(started, into: \.cleanupStatus)
        do {
            try await cleaner.prepare()
            cleanupStatus = .ready
        } catch {
            cleanupStatus = .failed(error.localizedDescription)
        }
        watcher.cancel()
        modelLog.info("cleanup → \(self.cleanupStatus.label, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
    }

    /// After `optimizingThreshold` on a local-file load, escalate `.loading` to
    /// `.optimizing(startedAt:)` so the UI can show elapsed time (ANE compile).
    private func watchForOptimize(
        _ startedAt: Date, into keyPath: ReferenceWritableKeyPath<AppModel, ModelLoadState>
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.optimizingThreshold)
            guard !Task.isCancelled, let self,
                  case .loading = self[keyPath: keyPath] else { return }
            self[keyPath: keyPath] = .optimizing(startedAt: startedAt)
        }
    }

    // MARK: - Pipeline updates → overlay state machine

    private func apply(_ update: DictationPipeline.Update) {
        switch update {
        case .stateChanged(let state):
            appLog.debug("UI state: \(String(describing: state), privacy: .public)")
            pipelineState = state
            hotkeys.setRecording(state == .recording)
            switch state {
            case .recording:
                // A new recording cancels any running edit watch (§6).
                Task { [editWatcher] in await editWatcher.cancel() }
                recording.overlayGeneration += 1
                recording.overlayState = .recording
                recording.levelHistory = []
                recording.smoothedLevel = 0
                recording.overlayPhase = .entering
                overlay.show()
                Task { [weak self] in self?.recording.overlayPhase = .visible }
            case .processing:
                if recording.overlayState == .recording { recording.overlayState = .processing }
            case .idle:
                recording.levelHistory = []
                recording.smoothedLevel = 0
                // Outcome cases (cancelled/inserted/failed) own the exit; if the
                // pipeline went idle without one, drop the pill immediately.
                if recording.overlayState == .recording || recording.overlayState == .processing {
                    hideOverlay()
                }
            }
        case .level(let level):
            pushLevel(level)
        case .recordingStopped(let count, let duration, let peak):
            appLog.info("recording stopped: \(count, privacy: .public) samples, \(duration, format: .fixed(precision: 2), privacy: .public)s, peak \(peak, format: .fixed(precision: 3), privacy: .public), device \(self.micName ?? "unknown", privacy: .public)")
        case .partial:
            break
        case .micName(let name):
            micName = name
        case .deviceFallback(let from, let to):
            // §4a: the resolved device failed to start; the pipeline moved to
            // the next connected candidate or the system default.
            let fromName = micStore.name(for: from) ?? "system default"
            let toName = micStore.name(for: to) ?? "system default"
            let message = "Mic “\(fromName)” unavailable — using “\(toName)”"
            lastError = message
            UserNotifications.post(message)
        case .recordingCancelled:
            recording.overlayGeneration += 1
            recording.levelHistory = []
            recording.overlayState = .cancelled
            recording.overlayPhase = .exitingCancel
            let generation = recording.overlayGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard let self, self.recording.overlayGeneration == generation else { return }
                self.hideOverlay()
            }
        case .inserted(_, let copied, let fellBack):
            if fellBack { lastError = "Cleanup fell back to raw transcript" }
            recording.overlayGeneration += 1
            recording.doneAt = Date()
            recording.overlayState = copied ? .copied : .done
            exitOverlay(after: copied ? 1.2 : 0.65)
        case .failed(let message):
            lastError = message
            recording.overlayGeneration += 1
            let showPill = recording.overlayState == .hidden
            recording.overlayState = .error(Self.shortError(message))
            if showPill {
                recording.overlayPhase = .entering
                overlay.show()
                Task { [weak self] in self?.recording.overlayPhase = .visible }
            }
            exitOverlay(after: 1.5)
        }
    }

    private static func shortError(_ message: String) -> String {
        if message.contains("no speech") { return "No speech" }
        if message.lowercased().contains("permission") { return "Permission" }
        return "Error"
    }

    /// Exit animation (scale 0.96 + fade, 160 ms) then hide the panel.
    private func exitOverlay(after delay: Double) {
        let generation = recording.overlayGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.recording.overlayGeneration == generation else { return }
            self.recording.overlayPhase = .exiting
            try? await Task.sleep(for: .milliseconds(160))
            guard self.recording.overlayGeneration == generation else { return }
            self.hideOverlay()
        }
    }

    /// The dictation ended (or ended without an outcome) — drop the bottom
    /// pill. The idle affordance is the side panel; it lives in its own window.
    private func hideOverlay() {
        recording.overlayPhase = .hidden
        recording.overlayState = .hidden
        overlay.hide()
    }

    /// Show/hide the right-edge side panel. Hiding it never suppresses the
    /// dictation pill — that's a separate window driven by the pipeline.
    func syncSidePanelVisibility() {
        if showSidePanel {
            edgePanel.show()
        } else {
            edgePanel.hide()
        }
    }

    /// Left-click on the side panel's record button — the same entry point as
    /// the double-tap-⌥ hotkey toggle.
    func toggleDictation() {
        Task { await pipeline.handle(.toggle) }
    }

    // MARK: - Microphone priority (§4a)

    /// Re-read the CoreAudio device list and fold it into the persisted
    /// priority order; releases a pin on a device that just disconnected.
    func refreshDevices() {
        micStore.refresh(connected: listInputDevices())
        inputDevices = micStore.devices()
        if let uid = micStore.resolvedUID() {
            resolvedMicName = micStore.name(for: uid)
        } else {
            resolvedMicName = AudioDevices.defaultInputDeviceID()
                .flatMap { AudioDevices.name(of: $0) }
        }
    }

    /// Menu/Settings pick: nil = Automatic (release the pin).
    func pinMic(_ uid: String?) {
        micStore.pin(uid)
        refreshDevices()
    }

    /// Drag-to-reorder the priority list (SwiftUI `List`/`onMove` signature).
    func moveMic(from source: IndexSet, to destination: Int) {
        micStore.move(fromOffsets: source, toOffset: destination)
        refreshDevices()
    }

    /// The mic name the side-panel header shows: the device actually recording
    /// while dictating, otherwise the resolved next-recording device.
    var currentMicName: String {
        if pipelineState != .idle, let micName { return micName }
        return resolvedMicName ?? "System default"
    }

    /// Consecutive days with ≥1 dictation, ending today or yesterday. A saved
    /// dictation always has ≥1 word, so `wordsPerDay` doubles as the day set.
    var streakDays: Int {
        let calendar = Calendar.current
        let today = Date()
        var streak = 0
        var offset = (wordsPerDay[HomeView.dayKey(today)] ?? 0) > 0 ? 0 : 1
        while let day = calendar.date(byAdding: .day, value: -offset, to: today),
              (wordsPerDay[HomeView.dayKey(day)] ?? 0) > 0 {
            streak += 1
            offset += 1
        }
        return streak
    }

    /// Levels arrive dB-mapped from the recorder (LevelMeter: −55 dB → 0,
    /// −15 dB → 1); here they get attack 0.6 / release 0.15 smoothing and are
    /// pushed onto the rolling history (newest first, capped at 12 samples —
    /// the farthest of 23 symmetric columns is 11 away from the centre).
    private func pushLevel(_ level: Float) {
        recording.smoothedLevel += (level - recording.smoothedLevel)
            * (level > recording.smoothedLevel ? 0.6 : 0.15)
        recording.levelHistory.insert(recording.smoothedLevel, at: 0)
        if recording.levelHistory.count > 12 { recording.levelHistory.removeLast() }
    }

    // MARK: - Store

    private func saveDictation(_ result: DictationResult) async {
        guard let store else { return }
        let appName = await MainActor.run {
            result.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
        do {
            // Flush the replacement hit counts this dictation accumulated
            // before persisting, so reloadData sees fresh numbers.
            try? await store.bumpHitCounts(replacementEngine.takeHits())
            _ = try await store.save(DictationInput(
                rawText: result.rawText,
                cleanedText: result.cleanedText,
                style: result.style.rawValue,
                cleanupFallback: result.cleanupFallback,
                durationSec: result.durationSec,
                appBundleID: result.appBundleID,
                appName: appName,
                audio: result.audio))
            reloadData()
        } catch {
            appLog.error("saveDictation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reloadData(search: String? = nil) {
        let query = search ?? historySearch
        Task { await refreshData(search: query) }
    }

    /// Awaitable variant — used by snapshot rendering which must wait for data.
    func refreshData(search: String = "") async {
        guard let store else { return }
        dictations = (try? await store.search(search)) ?? []
        recentDictations = (try? await store.recent(limit: 5)) ?? []
        stats = (try? await store.stats(typingWPM: Self.typingWPM)) ?? DictationStats()
        wordsPerDay = (try? await store.wordsPerDay(last: 84)) ?? [:]
        let overrides = (try? await store.styleOverrides()) ?? []
        let historyApps = (try? await store.dictationApps()) ?? []
        styleRows = Self.buildStyleRows(overrides: overrides, historyApps: historyApps)
        dictEntries = (try? await store.dictionaryEntries()) ?? []
        pendingSuggestions = (try? await store.suggestions()) ?? []
        refreshEngine()
    }

    // MARK: - Dictionary (§5) + edit learning (§6)

    /// Push the entry list into the engine: `from→to` rules (longest first is
    /// the engine's job) plus the vocabulary (terms + replacement targets)
    /// that feeds Whisper prompt tokens, the cleanup `{terms}` line, and the
    /// continuation-casing "is this a protected word" check.
    private func refreshEngine() {
        let replacements = dictEntries.filter { $0.kind == "replacement" }
        var vocab = Set(dictEntries.filter { $0.kind == "term" }.map(\.toText))
        for r in replacements { vocab.insert(r.toText) }
        replacementEngine.update(
            rules: replacements.map {
                ReplacementRule(entryID: $0.id, from: $0.fromText ?? "", to: $0.toText)
            },
            terms: vocab.sorted())
    }

    /// EditWatcher outcome → store; a second sighting of the same pair
    /// auto-accepts into a `learned` replacement + term (§6).
    private func recordObservedEdits(_ pairs: [(from: String, to: String)]) {
        guard let store else { return }
        Task {
            for pair in pairs where pair.from != pair.to {
                _ = try? await store.recordSuggestion(from: pair.from, to: pair.to)
            }
            reloadData()
        }
    }

    func addDictionaryTerm(_ text: String, source: String = "manual") {
        guard let store, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            _ = try? await store.addTerm(text, source: source)
            reloadData()
        }
    }

    func addDictionaryReplacement(from: String, to: String, source: String = "manual") {
        guard let store else { return }
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        Task {
            _ = try? await store.addReplacement(from: f, to: t, source: source)
            reloadData()
        }
    }

    func deleteDictionaryEntry(id: String) {
        guard let store else { return }
        Task {
            try? await store.deleteEntry(id: id)
            reloadData()
        }
    }

    func approveSuggestion(id: String) {
        guard let store else { return }
        Task {
            try? await store.approveSuggestion(id: id)
            reloadData()
        }
    }

    func rejectSuggestion(id: String) {
        guard let store else { return }
        Task {
            try? await store.rejectSuggestion(id: id)
            reloadData()
        }
    }

    /// Side-panel / menu-bar "N suggestions" row → Dictionary page.
    func openDictionary() {
        openMainWindow(page: .dictionary)
    }

    // MARK: - Styles (§3.7 / T10)

    /// One row per app on the Styles page.
    struct StyleAppRow: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        /// nil = app not installed (override/history only) → generic icon.
        let icon: NSImage?
        /// True when the effective style comes from the built-in map.
        let isBuiltIn: Bool
        /// True when an `app_styles` row exists for this bundleID.
        let isOverridden: Bool
        let effective: CleanupStyle
    }

    @Published var styleRows: [StyleAppRow] = []

    /// Rows = installed built-in-map apps + overridden apps + apps seen in
    /// history, sorted by name. Names/icons resolve via NSWorkspace; history
    /// names fill in for apps that aren't installed.
    static func buildStyleRows(overrides: [AppStyleOverride],
                               historyApps: [AppStyleOverride]) -> [StyleAppRow] {
        var overridesByID: [String: AppStyleOverride] = [:]
        for o in overrides { overridesByID[o.bundleID] = o }
        var names: [String: String] = [:]
        for app in historyApps {
            names[app.bundleID] = app.appName ?? names[app.bundleID]
        }
        var ids: [String] = []
        var seen = Set<String>()
        for bundleID in StyleResolver.builtInDefaults.keys.sorted()
            where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            ids.append(bundleID); seen.insert(bundleID)
        }
        for app in overrides + historyApps where !seen.contains(app.bundleID) {
            ids.append(app.bundleID); seen.insert(app.bundleID)
        }
        let workspace = NSWorkspace.shared
        return ids.map { bundleID in
            let url = workspace.urlForApplication(withBundleIdentifier: bundleID)
            // Not installed (override/history row) → the generic app icon,
            // not a broken placeholder.
            let icon = url.map { workspace.icon(forFile: $0.path) }
                ?? workspace.icon(for: .applicationBundle)
            let name = url?.deletingPathExtension().lastPathComponent
                ?? names[bundleID] ?? bundleID
            let override = overridesByID[bundleID]
            let resolved = StyleResolver.resolve(
                bundleID: bundleID,
                overrides: override.map { [$0.bundleID: CleanupStyle(rawValue: $0.style) ?? .default] } ?? [:])
            return StyleAppRow(
                bundleID: bundleID,
                name: name,
                icon: icon,
                isBuiltIn: override == nil && StyleResolver.builtInDefaults[bundleID] != nil,
                isOverridden: override != nil,
                effective: resolved)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setStyle(bundleID: String, name: String? = nil, style: CleanupStyle) {
        guard let store else { return }
        Task {
            try? await store.setStyleOverride(bundleID: bundleID, appName: name,
                                              style: style.rawValue)
            reloadData()
        }
    }

    func resetStyle(bundleID: String) {
        guard let store else { return }
        Task {
            try? await store.removeStyleOverride(bundleID: bundleID)
            reloadData()
        }
    }

    /// Settings → Privacy: wipe `stats_daily` only; history stays.
    func resetStatistics() {
        guard let store else { return }
        Task {
            _ = try? await store.resetStatistics()
            reloadData()
        }
    }

    func deleteDictation(_ record: Dictation) {
        guard let store else { return }
        Task {
            try? await store.delete(id: record.id)
            reloadData()
        }
    }

    func deleteAllHistory() {
        guard let store else { return }
        Task {
            _ = try? await store.deleteAll()
            reloadData()
        }
    }

    private func applyRetention() {
        guard let store else { return }
        let days = retentionDays
        Task {
            do {
                let removed = try await store.enforceRetention(days: days)
                if removed > 0 {
                    appLog.info("retention removed \(removed, privacy: .public) dictations")
                    reloadData()
                }
            } catch {
                appLog.error("retention failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Audio playback

    func audioURL(for record: Dictation) -> URL? {
        guard let name = record.audioPath else { return nil }
        return (store?.audioDirectory ?? paths.audio).appending(path: name)
    }

    func togglePlayback(_ record: Dictation) {
        if playback.playingDictationID == record.id {
            stopPlayback()
            return
        }
        guard let url = audioURL(for: record),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer = player
        playback.playingDictationID = record.id
        playback.progress = 0
        player.play()
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer else { return }
                if !player.isPlaying {
                    self.stopPlayback()
                } else {
                    self.playback.progress = player.duration > 0
                        ? player.currentTime / player.duration : 0
                }
            }
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playback.playingDictationID = nil
        playback.progress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Permissions

    func refreshPermissions() {
        permissions.mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permissions.accessibility = AXIsProcessTrusted()
        permissions.inputMonitoring = CGPreflightListenEventAccess()
    }

    var missingPermissionCount: Int {
        [permissions.mic, permissions.accessibility, permissions.inputMonitoring]
            .filter { !$0 }.count
    }

    /// Prompt for one permission. macOS won't let apps flip Accessibility /
    /// Input Monitoring themselves, so this fires the system prompt and opens
    /// the right Settings pane; the user flips the switch.
    func requestPermission(_ pane: PrivacyPane) {
        startPermissionPolling()
        appLog.info("permission request → \(String(describing: pane), privacy: .public)")
        switch pane {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    Task { @MainActor in self?.refreshPermissions() }
                }
            } else {
                openPrivacyPane(.microphone)
            }
        case .accessibility:
            // Ad-hoc rebuilds leave a stale enabled row that no longer matches
            // the signature — clear it so the user sees the real state.
            if !AXIsProcessTrusted() { resetTCC(service: "Accessibility") }
            // kAXTrustedCheckOptionPrompt is a mutable C global — not
            // concurrency-safe to reference under Swift 6; the literal
            // bridges to the same CFString key.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacyPane(.accessibility)
        case .inputMonitoring:
            if !CGPreflightListenEventAccess() { resetTCC(service: "ListenEvent") }
            HotkeyService.requestInputMonitoring()
            openPrivacyPane(.inputMonitoring)
        }
    }

    private func resetTCC(service: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.local.hush"]
        do {
            try process.run()
            process.waitUntilExit()
            appLog.info("tccutil reset \(service, privacy: .public) → exit \(process.terminationStatus, privacy: .public)")
        } catch {
            appLog.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 1 s poll while anything is missing — the user flips switches in System
    /// Settings while Hush is in the background, so didBecomeActive isn't
    /// enough. Stops once everything is granted.
    private func startPermissionPolling() {
        guard permissionPollTask == nil else { return }
        permissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.pollPermissions()
            }
        }
    }

    private func pollPermissions() {
        refreshPermissions()
        retryHotkeysIfNeeded()
        guard missingPermissionCount > 0 else {
            permissionPollTask?.cancel()
            permissionPollTask = nil
            return
        }
    }

    /// The tap fails silently at launch when Input Monitoring is missing. Once
    /// AX + IM are granted, retry; if it still can't start, the process needs
    /// a relaunch (TCC applies grants to the *next* process for ad-hoc builds).
    private func retryHotkeysIfNeeded() {
        let granted = permissions.accessibility && permissions.inputMonitoring
        guard granted, !hotkeys.isRunning else { return }
        do {
            try hotkeys.start()
            if lastError == "Hotkey tap failed — grant Input Monitoring in System Settings" {
                lastError = nil
            }
            needsRelaunch = false
        } catch {
            needsRelaunch = true
        }
    }

    /// Relaunch the app so a fresh process picks up newly granted permissions.
    func relaunch() {
        let appPath = Bundle.main.bundleURL.path
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", appPath]
            try? process.run()
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    enum PrivacyPane {
        case microphone, accessibility, inputMonitoring
        var url: URL? {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .inputMonitoring:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            }
        }
    }

    func openPrivacyPane(_ pane: PrivacyPane) {
        if let url = pane.url { NSWorkspace.shared.open(url) }
    }
}
