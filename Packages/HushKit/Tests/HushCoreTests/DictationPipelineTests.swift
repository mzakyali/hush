import Foundation
import Testing
@testable import HushCore

// MARK: - fakes

final class FakeRecorder: AudioRecording, @unchecked Sendable {
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private(set) var isRecording = false
    private(set) var cancelled = false
    /// Device UIDs the pipeline tried to start on, in order (§4a fallback).
    private(set) var attemptedUIDs: [String?] = []
    /// UIDs that should throw on start.
    var failingUIDs: Set<String?> = []
    var activeDeviceName: String? { "Fake Mic" }

    func makeLevelStream() -> AsyncStream<Float> {
        AsyncStream { continuation in
            levelContinuation?.finish()
            levelContinuation = continuation
        }
    }
    func makeChunkStream() -> AsyncStream<AudioBuffer16k> {
        AsyncStream { _ in }
    }
    /// Emit a level as the tap would while recording.
    func emitLevel(_ value: Float) { levelContinuation?.yield(value) }

    struct StartError: Error {}
    func start(deviceUID: String?) async throws {
        attemptedUIDs.append(deviceUID)
        if failingUIDs.contains(deviceUID) { throw StartError() }
        isRecording = true
    }
    func stop() async throws -> RecordedAudio {
        isRecording = false
        return RecordedAudio(buffer: AudioBuffer16k(samples: [0, 0, 0]), duration: 0.2)
    }
    func cancel() async { isRecording = false; cancelled = true }
}

actor FakeTranscriber: Transcriber {
    var transcriptText = "raw transcript"
    var delay: TimeInterval = 0
    var onTranscribe: (@Sendable () -> Void)?
    private(set) var transcribeCount = 0
    func setDelay(_ d: TimeInterval) { delay = d }
    func setTranscript(_ t: String) { transcriptText = t }
    func setOnTranscribe(_ f: (@Sendable () -> Void)?) { onTranscribe = f }

    func prepare() async throws {}
    func transcribe(_ audio: AudioBuffer16k, prompt: [String]) async throws -> Transcript {
        transcribeCount += 1
        onTranscribe?()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return Transcript(text: transcriptText, language: "en")
    }
    nonisolated func partials(_ stream: AsyncStream<AudioBuffer16k>, prompt: [String])
        -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("partial")
            continuation.finish()
        }
    }
}

actor FakeCleaner: FallbackReportingCleaner {
    var fellBack = false
    var delay: TimeInterval = 0
    private(set) var lastCleanupFellBack = false
    private(set) var cleanCount = 0
    private(set) var lastStyle: CleanupStyle?
    func setFellBack(_ v: Bool) { fellBack = v }

    func prepare() async throws {}
    func clean(_ raw: String, style: CleanupStyle, terms: [String]) async throws -> String {
        cleanCount += 1
        lastStyle = style
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        lastCleanupFellBack = fellBack
        return fellBack ? raw : "cleaned: \(raw)"
    }
}

actor FakeInserter: Inserting {
    /// Mirrors Inserter's contract: if the frontmost pid changes between capture and
    /// insert, the text goes to the clipboard instead of being pasted.
    var capturedPid: pid_t? = 42
    var currentPid: pid_t? = 42
    private(set) var inserted: [String] = []
    private(set) var capturedTargets: [InsertionTarget] = []
    /// (raw, cleaned) pairs the pipeline asked to paste over the last insertion.
    private(set) var replaceCalls: [(raw: String?, cleaned: String?)] = []

    func setPids(captured: pid_t?, current: pid_t?) {
        capturedPid = captured
        currentPid = current
    }

    func captureTarget() -> InsertionTarget {
        let target = InsertionTarget(bundleID: "com.test.app", pid: capturedPid)
        capturedTargets.append(target)
        return target
    }

    func insert(_ text: String, target: InsertionTarget) async throws -> InsertionResult {
        if currentPid != target.pid { return .copiedToClipboard }
        inserted.append(text)
        return .pasted(appBundleID: target.bundleID, element: target.element,
                       insertedLength: text.utf16.count)
    }

    func replaceLastInsertion(raw: String?, cleaned: String?) async {
        replaceCalls.append((raw, cleaned))
    }
}

// MARK: - helpers

/// Lock-guarded flag readable from @Sendable hooks.
final class MutexedProbe: @unchecked Sendable {
    private var _transcribing = false
    private let lock = NSLock()
    var transcribing: Bool { lock.withLock { _transcribing } }
    func markTranscribing() { lock.withLock { _transcribing = true } }
}

/// Collect pipeline updates for assertions.
final class UpdateCollector: @unchecked Sendable {
    private(set) var updates: [DictationPipeline.Update] = []
    private let lock = NSLock()

    func start(_ pipeline: DictationPipeline) {
        Task {
            for await update in pipeline.updates {
                lock.withLock { updates.append(update) }
            }
        }
    }

    func latest() -> [DictationPipeline.Update] { lock.withLock { updates } }

    func wait(for predicate: (DictationPipeline.Update) -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if latest().contains(where: predicate) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

private func makePipeline(
    recorder: FakeRecorder = FakeRecorder(),
    transcriber: FakeTranscriber = FakeTranscriber(),
    cleaner: FakeCleaner = FakeCleaner(),
    inserter: FakeInserter = FakeInserter(),
    hooks: PipelineHooks = .init()
) -> DictationPipeline {
    DictationPipeline(
        recorder: recorder, transcriber: transcriber,
        cleaner: cleaner, inserter: inserter, hooks: hooks
    )
}

// MARK: - tests

@Test func holdStartThenEndInsertsCleanedText() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.holdStart)
    #expect(await pipeline.state == .recording)
    await pipeline.handle(.holdEnd)

    let ok = await collector.wait { $0 == .stateChanged(.idle) }
    #expect(ok)
    #expect(await inserter.inserted == ["cleaned: raw transcript"])
}

@Test func toggleStartsAndStops() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    #expect(await pipeline.state == .recording)
    await pipeline.handle(.toggle)
    let ok = await collector.wait { $0 == .stateChanged(.idle) }
    #expect(ok)
    #expect(await inserter.inserted.count == 1)
}

@Test func cancelDiscardsRecording() async {
    let recorder = FakeRecorder()
    let inserter = FakeInserter()
    let finished = MutexedProbe()
    let pipeline = makePipeline(
        recorder: recorder, inserter: inserter,
        hooks: PipelineHooks(didFinish: { _ in finished.markTranscribing() })
    )
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.holdStart)
    #expect(await pipeline.state == .recording)
    await pipeline.handle(.cancel)
    // Esc emits .recordingCancelled so the overlay can run its exit animation.
    #expect(await collector.wait { $0 == .recordingCancelled })
    #expect(await pipeline.state == .idle)
    #expect(recorder.cancelled)
    #expect(await inserter.inserted.isEmpty)
    // Nothing is persisted: didFinish never fires.
    #expect(!finished.transcribing)
}

@Test func completedDictationCallsDidFinish() async {
    let box = MutexedResultBox()
    let pipeline = makePipeline(
        hooks: PipelineHooks(didFinish: { result in await box.set(result) })
    )
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    let ok = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }
    #expect(ok)

    let result = await box.value
    #expect(result?.rawText == "raw transcript")
    #expect(result?.cleanedText == "cleaned: raw transcript")
    #expect(result?.appBundleID == "com.test.app")
    #expect(result?.durationSec == 0.2)
    #expect(result?.copiedToClipboard == false)
}

@Test func emptyTranscriptFailsWithoutInsertingOrSaving() async {
    let transcriber = FakeTranscriber()
    await transcriber.setTranscript("   ")
    let inserter = FakeInserter()
    let finished = MutexedProbe()
    let pipeline = makePipeline(
        transcriber: transcriber, inserter: inserter,
        hooks: PipelineHooks(didFinish: { _ in finished.markTranscribing() })
    )
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    let ok = await collector.wait {
        if case .failed = $0 { return true } else { return false }
    }
    #expect(ok)
    #expect(await inserter.inserted.isEmpty)
    #expect(!finished.transcribing)
    #expect(await pipeline.state == .idle)
}

/// Mutexed holder for the single DictationResult a test expects.
private actor MutexedResultBox {
    private(set) var value: DictationResult?
    func set(_ v: DictationResult) { value = v }
}

@Test func startArrivingDuringProcessingIsQueued() async {
    let transcriber = FakeTranscriber()
    await transcriber.setDelay(0.15)
    let inserter = FakeInserter()
    let pipeline = makePipeline(transcriber: transcriber, inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)              // start first recording
    await pipeline.handle(.toggle)              // stop → processing begins

    // Send another start while processing is in flight.
    let queued = Task { await pipeline.handle(.toggle) }
    let ok = await collector.wait { $0 == .stateChanged(.processing) }
    #expect(ok)

    await queued.value                          // handled after processing → starts recording
    #expect(await pipeline.state == .recording)

    await pipeline.handle(.toggle)              // finish the queued recording
    let done = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }
    #expect(done)
    #expect(await inserter.inserted.count == 2)
}

@Test func cleanupFallbackFlagPropagates() async {
    let cleaner = FakeCleaner()
    await cleaner.setFellBack(true)
    let inserter = FakeInserter()
    let pipeline = makePipeline(cleaner: cleaner, inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)

    let ok = await collector.wait {
        if case .inserted(_, _, let fellBack) = $0 { return fellBack }
        return false
    }
    #expect(ok)
    // Fell back → inserted text is the rule-processed raw, not cleaned.
    #expect(await inserter.inserted == ["raw transcript"])
}

@Test func appSwitchBetweenStopAndInsertCopiesToClipboard() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    // User switches apps while the pipeline is still transcribing/cleaning:
    // the fake's "current frontmost" no longer matches the captured pid.
    await inserter.setPids(captured: 42, current: 43)
    await pipeline.handle(.toggle)

    let ok = await collector.wait {
        if case .inserted(_, let copied, _) = $0 { return copied }
        return false
    }
    #expect(ok)
    #expect(await inserter.inserted.isEmpty)
}

@Test func styleIsEvaluatedAtStopNotInsert() async {
    // The style hook returns .formal once transcription has started; if the pipeline
    // evaluates it at stop time (before transcribe) the cleaner sees .default.
    let transcriber = FakeTranscriber()
    let cleaner = FakeCleaner()
    let probe = MutexedProbe()
    await transcriber.setOnTranscribe { probe.markTranscribing() }
    let pipeline = makePipeline(
        transcriber: transcriber, cleaner: cleaner,
        hooks: PipelineHooks(style: { probe.transcribing ? .formal : .default })
    )
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    let ok = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }
    #expect(ok)
    #expect(await cleaner.lastStyle == .default)
}

/// Regression: the level pump terminates its AsyncStream when cancelled at
/// stop — the next recording must pump a fresh stream or the waveform is flat.
@Test func levelUpdatesFlowOnEveryRecording() async {
    let recorder = FakeRecorder()
    let pipeline = makePipeline(recorder: recorder)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.holdStart)
    recorder.emitLevel(0.5)
    #expect(await collector.wait {
        if case .level(let v) = $0 { return v == 0.5 }; return false
    })
    await pipeline.handle(.holdEnd)
    _ = await collector.wait { $0 == .stateChanged(.idle) }

    await pipeline.handle(.holdStart)
    recorder.emitLevel(0.7)
    #expect(await collector.wait {
        if case .level(let v) = $0 { return v == 0.7 }; return false
    })
    await pipeline.handle(.cancel)
}

@Test func replacementsAppliedBeforeAndAfterCleanup() async {
    let inserter = FakeInserter()
    let hooks = PipelineHooks(replacements: { text in
        text.replacingOccurrences(of: "raw", with: "R")
    })
    let pipeline = makePipeline(inserter: inserter, hooks: hooks)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    let ok = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }
    #expect(ok)
    // "raw transcript" → "R transcript" (pre-clean) → "cleaned: R transcript" (post-clean pass is identity).
    #expect(await inserter.inserted == ["cleaned: R transcript"])
}

// MARK: - paste-raw (§3.9/T11)

/// ⌃⌥Z while idle hands the last dictation's raw + inserted text to the
/// inserter, which does the AX verify + replace.
@Test func pasteRawHandsLastDictationToInserter() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    let ok = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }
    #expect(ok)

    await pipeline.handle(.pasteRaw)
    let calls = await inserter.replaceCalls
    #expect(calls.count == 1)
    #expect(calls[0].raw == "raw transcript")
    #expect(calls[0].cleaned == "cleaned: raw transcript")
}

/// ⌃⌥Z mid-recording is ignored — it can only act on a completed insertion.
@Test func pasteRawIgnoredWhileRecording() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    await pipeline.handle(.toggle)
    _ = await collector.wait {
        if case .inserted = $0 { return true } else { return false }
    }

    await pipeline.handle(.toggle)              // recording again
    await pipeline.handle(.pasteRaw)            // ignored
    #expect(await inserter.replaceCalls.isEmpty)
    await pipeline.handle(.cancel)
}

/// With no completed dictation there's nothing to replace; the inserter still
/// gets the call (nil texts → its "Nothing to undo" notification path).
@Test func pasteRawWithNoDictationNotifies() async {
    let inserter = FakeInserter()
    let pipeline = makePipeline(inserter: inserter)

    await pipeline.handle(.pasteRaw)
    let calls = await inserter.replaceCalls
    #expect(calls.count == 1)
    #expect(calls[0].raw == nil)
    #expect(calls[0].cleaned == nil)
}

// MARK: - mic fallback (§4a/T12)

@Test func recordingStartsOnFirstCandidate() async {
    let recorder = FakeRecorder()
    let hooks = PipelineHooks(deviceUIDs: { ["uid-a", "uid-b", nil] })
    let pipeline = makePipeline(recorder: recorder, hooks: hooks)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    #expect(await pipeline.state == .recording)
    #expect(recorder.attemptedUIDs == ["uid-a"])
    await pipeline.handle(.cancel)
}

/// If the resolved device fails to start, the next connected candidate in
/// priority order is tried and a .deviceFallback update reports the hop.
@Test func failedCandidateFallsBackToNext() async {
    let recorder = FakeRecorder()
    recorder.failingUIDs = ["uid-a"]
    let hooks = PipelineHooks(deviceUIDs: { ["uid-a", "uid-b", nil] })
    let pipeline = makePipeline(recorder: recorder, hooks: hooks)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    #expect(await pipeline.state == .recording)
    #expect(recorder.attemptedUIDs == ["uid-a", "uid-b"])
    let fellBack = await collector.wait {
        if case .deviceFallback(let from, let to) = $0 {
            return from == "uid-a" && to == "uid-b"
        }
        return false
    }
    #expect(fellBack)
    await pipeline.handle(.cancel)
}

/// All devices failing → falls through to the system default (nil); when even
/// that fails, the pipeline reports the last error and never records.
@Test func allCandidatesFailEndsInFailedUpdate() async {
    let recorder = FakeRecorder()
    recorder.failingUIDs = ["uid-a", nil]
    let hooks = PipelineHooks(deviceUIDs: { ["uid-a", nil] })
    let pipeline = makePipeline(recorder: recorder, hooks: hooks)
    let collector = UpdateCollector(); collector.start(pipeline)

    await pipeline.handle(.toggle)
    #expect(recorder.attemptedUIDs == ["uid-a", nil])
    #expect(await collector.wait {
        if case .failed = $0 { return true }; return false
    })
    #expect(await pipeline.state == .idle)
    #expect(!recorder.isRecording)
}
