import Foundation
import OSLog

private let pipelineLog = Logger(subsystem: "com.local.hush", category: "pipeline")

/// Pluggable hooks — replaced by real modules in later milestones
/// (replacements T8, styles T10, device priority T12, dictionary terms T8).
public struct PipelineHooks: Sendable {
    /// Dictionary terms fed to ASR prompt tokens and the cleanup `{terms}` line.
    public var terms: @Sendable () -> [String]
    /// Deterministic replacement rules, applied before and after cleanup.
    /// Identity until T8.
    public var replacements: @Sendable (String) -> String
    /// Cleanup style for the insertion target. `.default` until T10.
    public var style: @Sendable () -> CleanupStyle
    /// Ordered input-device candidates (CoreAudio UIDs; nil = system default),
    /// resolved at recording start by spec §4a/T12. If the first device fails to
    /// start, the next connected device in priority order is tried, with the
    /// system default last.
    public var deviceUIDs: @Sendable () -> [String?]
    /// Called once per completed dictation (after insert) so the store can persist
    /// it (T7). Not called on cancel or failure.
    public var didFinish: @Sendable (DictationResult) async -> Void

    public init(
        terms: @escaping @Sendable () -> [String] = { [] },
        replacements: @escaping @Sendable (String) -> String = { $0 },
        style: @escaping @Sendable () -> CleanupStyle = { .default },
        deviceUIDs: @escaping @Sendable () -> [String?] = { [nil] },
        didFinish: @escaping @Sendable (DictationResult) async -> Void = { _ in }
    ) {
        self.terms = terms
        self.replacements = replacements
        self.style = style
        self.deviceUIDs = deviceUIDs
        self.didFinish = didFinish
    }
}

/// One completed dictation, handed to `PipelineHooks.didFinish` for persistence.
public struct DictationResult: Sendable {
    public var rawText: String
    public var cleanedText: String
    public var style: CleanupStyle
    public var cleanupFallback: Bool
    public var durationSec: Double
    public var appBundleID: String?
    public var pid: pid_t?
    public var audio: AudioBuffer16k
    /// True when the text was left on the clipboard instead of pasted.
    public var copiedToClipboard: Bool

    public init(rawText: String, cleanedText: String, style: CleanupStyle,
                cleanupFallback: Bool, durationSec: Double, appBundleID: String?,
                pid: pid_t?, audio: AudioBuffer16k, copiedToClipboard: Bool) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.style = style
        self.cleanupFallback = cleanupFallback
        self.durationSec = durationSec
        self.appBundleID = appBundleID
        self.pid = pid
        self.audio = audio
        self.copiedToClipboard = copiedToClipboard
    }
}

/// The talk → cleaned-text-pasted pipeline (plan T6).
///
/// States: `idle → recording → processing → idle`.
/// - hold: start on `holdStart`, stop on `holdEnd`.
/// - toggle: start/stop alternately.
/// - `cancel` while recording → discard; nothing is inserted.
/// - Events are actor-serialized, so a start arriving while `processing` is handled
///   right after the in-flight run finishes — i.e. queued, per plan.
///
/// Flow on stop: transcribe → replacements → clean → replacements → insert.
public actor DictationPipeline {
    public enum State: String, Sendable {
        case idle, recording, processing
    }

    /// UI-facing updates (overlay, menu).
    public enum Update: Sendable, Equatable {
        case stateChanged(State)
        case level(Float)
        case partial(String)
        case micName(String?)
        /// Esc during recording — the overlay needs it to run the cancel animation.
        case recordingCancelled
        /// Audio captured when recording stopped — lets the app log evidence
        /// (e.g. a 0.1 s capture producing "no speech").
        case recordingStopped(sampleCount: Int, durationSec: Double, peak: Float)
        case inserted(text: String, copiedToClipboard: Bool, cleanupFallback: Bool)
        /// The resolved device failed to start and recording fell back to a
        /// later candidate (§4a). nil = system default. Emitted once per hop.
        case deviceFallback(from: String?, to: String?)
        case failed(String)
    }

    public nonisolated let updates: AsyncStream<Update>
    public private(set) var state: State = .idle

    private let continuation: AsyncStream<Update>.Continuation
    private let recorder: any AudioRecording
    private let transcriber: any Transcriber
    private let cleaner: any Cleaner
    private let inserter: any Inserting
    private let hooks: PipelineHooks

    private var pumpTasks: [Task<Void, Never>] = []
    /// Raw + inserted text of the last completed dictation — the ⌃⌥Z paste-raw
    /// source (the inserter verifies the target before replacing).
    private var lastUndo: (raw: String, cleaned: String)?

    public init(
        recorder: any AudioRecording,
        transcriber: any Transcriber,
        cleaner: any Cleaner,
        inserter: any Inserting,
        hooks: PipelineHooks = .init()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.hooks = hooks
        var continuation: AsyncStream<Update>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func handle(_ event: HotkeyEvent) async {
        switch (state, event) {
        case (.idle, .holdStart), (.idle, .toggle):
            await startRecording()
        case (.recording, .holdEnd), (.recording, .toggle):
            await finishRecording()
        case (.recording, .cancel):
            await cancelRecording()
        case (.idle, .pasteRaw):
            // §3.9/T11 — replace the last insertion with the raw transcript.
            // Only while idle; the inserter verifies the target's text first.
            await inserter.replaceLastInsertion(
                raw: lastUndo?.raw, cleaned: lastUndo?.cleaned)
        default:
            // .processing ignores everything (a start arriving then is naturally
            // queued by the actor); idle ignores stray holdEnd/cancel.
            break
        }
    }

    // MARK: - state transitions

    private func startRecording() async {
        pumpTasks.removeAll()
        let candidates = hooks.deviceUIDs()
        var lastError: Error?
        for (index, uid) in candidates.enumerated() {
            do {
                try await recorder.start(deviceUID: uid)
                if index > 0 {
                    emit(.deviceFallback(from: candidates[0], to: uid))
                }
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError {
            emit(.failed("could not start recording: \(lastError.localizedDescription)"))
            return
        }
        state = .recording
        emit(.stateChanged(.recording))
        emit(.micName(recorder.activeDeviceName))  // nonisolated property

        // Partials are intentionally not run: the overlay is waveform-only, so
        // partial decodes would only compete with the final transcription for
        // the model. `Transcriber.partials` stays available if a UI needs it —
        // call `makeChunkStream()` then, since nothing else consumes chunks.
        // Fresh level stream per recording: cancelling this pump at stop
        // terminates the stream, so a shared one would be dead next time.
        pumpTasks.append(Task { [continuation, levels = recorder.makeLevelStream()] in
            for await level in levels {
                continuation.yield(.level(level))
            }
        })
    }

    private func finishRecording() async {
        pumpTasks.forEach { $0.cancel() }
        pumpTasks.removeAll()
        state = .processing
        emit(.stateChanged(.processing))

        do {
            let stopAt = Date()
            let audio = try await recorder.stop()
            let peak = audio.buffer.samples.reduce(0) { max($0, abs($1)) }
            emit(.recordingStopped(sampleCount: audio.buffer.samples.count,
                                   durationSec: audio.duration, peak: peak))
            // Spec: the insertion target and style are the ones focused/selected when
            // recording stops — capture before transcription, which can take seconds.
            let target = await inserter.captureTarget()
            let style = hooks.style()

            let asrStart = Date()
            let transcript = try await transcriber.transcribe(audio.buffer, prompt: hooks.terms())
            let asrSec = Date().timeIntervalSince(asrStart)

            let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                emit(.failed("no speech"))
                breakPipeline()
                return
            }

            let cleanStart = Date()
            var text = hooks.replacements(transcript.text)
            text = try await cleaner.clean(text, style: style, terms: hooks.terms())
            let cleanSec = Date().timeIntervalSince(cleanStart)
            var fellBack = false
            if let reporting = cleaner as? FallbackReportingCleaner {
                fellBack = await reporting.lastCleanupFellBack
            }
            text = hooks.replacements(text)

            let insertStart = Date()
            let outcome = try await inserter.insert(text, target: target)
            let insertSec = Date().timeIntervalSince(insertStart)
            let totalSec = Date().timeIntervalSince(stopAt)

            await logTiming(audioSec: audio.duration, transcript: transcript,
                            asrSec: asrSec, cleanSec: cleanSec, insertSec: insertSec,
                            totalSec: totalSec)

            let copied: Bool
            if case .copiedToClipboard = outcome { copied = true } else { copied = false }
            lastUndo = (raw: raw, cleaned: text)
            emit(.inserted(text: text, copiedToClipboard: copied, cleanupFallback: fellBack))
            await hooks.didFinish(DictationResult(
                rawText: transcript.text, cleanedText: text, style: style,
                cleanupFallback: fellBack, durationSec: audio.duration,
                appBundleID: target.bundleID, pid: target.pid,
                audio: audio.buffer, copiedToClipboard: copied))
        } catch {
            emit(.failed("dictation failed: \(error.localizedDescription)"))
        }

        state = .idle
        emit(.stateChanged(.idle))
    }

    /// One info line per dictation — stage durations and ASR language scores.
    /// No transcript text is logged.
    private func logTiming(audioSec: Double, transcript: Transcript, asrSec: Double,
                           cleanSec: Double, insertSec: Double, totalSec: Double) async {
        var asrDetail = transcript.language ?? "?"
        if !transcript.languageScores.isEmpty {
            let scores = transcript.languageScores
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \(String(format: "%.2f", $0.value))" }
                .joined(separator: ", ")
            asrDetail = "\(scores) → \(transcript.language ?? "?")"
        }
        var cleanupDetail = "llm"
        if let reporting = cleaner as? CleanupStatsReporting,
           let run = await reporting.lastCleanupRun {
            cleanupDetail = run.usedLLM
                ? "llm prompt \(run.promptTokens) gen \(run.generatedTokens)"
                : "skipped"
        }
        let line = String(
            format: "pipeline: audio %.2fs | asr %.2fs (%@) | cleanup %.2fs (%@) | " +
                "insert %.2fs | total stop→done %.2fs",
            audioSec, asrSec, asrDetail, cleanSec, cleanupDetail, insertSec, totalSec)
        pipelineLog.info("\(line, privacy: .public)")
    }

    private func breakPipeline() {
        state = .idle
        emit(.stateChanged(.idle))
    }

    private func cancelRecording() async {
        pumpTasks.forEach { $0.cancel() }
        pumpTasks.removeAll()
        await recorder.cancel()
        state = .idle
        emit(.recordingCancelled)
        emit(.stateChanged(.idle))
    }

    private func emit(_ update: Update) {
        continuation.yield(update)
    }
}
