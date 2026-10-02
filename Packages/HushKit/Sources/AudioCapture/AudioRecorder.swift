import AVFoundation
import CoreAudio
import Foundation
import HushCore
import OSLog

private let audioLog = Logger(subsystem: "com.local.hush", category: "audio")

public enum RecorderError: Swift.Error {
    case alreadyRecording
    case notRecording
    case converterFailed
    case deviceNotFound(String)
    case engineFailed(String)
}

/// Restart budget for AVAudioEngine configuration changes — another app
/// grabbing the input device (a Discord call) can make it flap, so restarts
/// are capped per recording instead of looping forever.
struct RestartBudget: Sendable, Equatable {
    static let limit = 5
    private(set) var used = 0

    /// True while restarts remain; consumes one.
    mutating func consume() -> Bool {
        guard used < Self.limit else { return false }
        used += 1
        return true
    }
}

/// Records microphone audio as 16 kHz mono Float32. Levels and converted chunks are
/// published through per-recording AsyncStreams (`makeLevelStream`/`makeChunkStream`)
/// for the overlay and streaming ASR partials.
///
/// Another app reconfiguring the shared input device (format change, hog mode)
/// makes AVAudioEngine stop itself — `.AVAudioEngineConfigurationChange` fires
/// for our engine and the tap goes silent. `handleConfigurationChange` rebuilds
/// the input chain on the same engine and sink, so samples keep accumulating;
/// if the rebuild keeps failing the sink records the error and `stop()` throws
/// it — the user gets an error instead of a silent "no speech".
public actor AudioRecorder: AudioRecording {
    /// Set at `start`; nonisolated so it satisfies the protocol's sync getter.
    public nonisolated var activeDeviceName: String? { sink.deviceName }

    /// The tap's accumulation buffer. nonisolated: the realtime tap thread and
    /// tests reach it without hopping onto the actor.
    nonisolated let sink = CaptureSink()
    private var engine: AVAudioEngine?
    /// UID passed to `start` — re-applied on each restart so the rebuilt input
    /// chain stays on the selected device.
    private var deviceUID: String?
    private var configObserver: NSObjectProtocol?
    private var restartBudget = RestartBudget()
    /// Config changes arrive in bursts — one reconfiguration (another app
    /// grabbing the device mid-call) can post 5+ notifications over ~1.5 s.
    /// Debounce: each notification marks pending; a restart runs once the
    /// burst goes quiet, so one event costs one restart slot, not the budget.
    private var restartPending = false
    private var restartTask: Task<Void, Never>?
    /// Our own teardown + restart posts a config change too — notifications
    /// inside this window are dropped, otherwise every restart would chain
    /// into another until the budget ran out. A real change then (rare) still
    /// surfaces through its own notification burst.
    private var suppressConfigChangesUntil = Date.distantPast
    /// Engine start seam — tests swap in a no-op so no real I/O is opened.
    var startEngine: @Sendable (AVAudioEngine) throws -> Void = { engine in
        engine.prepare()
        try engine.start()
    }

    public init() {}

    /// Testing seam: replace prepare()+start() on engine (re)starts.
    func setEngineStarter(_ starter: @escaping @Sendable (AVAudioEngine) throws -> Void) {
        startEngine = starter
    }

    public nonisolated func makeLevelStream() -> AsyncStream<Float> {
        sink.makeLevelStream()
    }

    public nonisolated func makeChunkStream() -> AsyncStream<AudioBuffer16k> {
        sink.makeChunkStream()
    }

    /// Start recording. `deviceUID` is a CoreAudio device UID; nil = system default input.
    public func start(deviceUID: String? = nil) async throws {
        guard engine == nil else { throw RecorderError.alreadyRecording }
        sink.reset()
        restartBudget = RestartBudget()
        self.deviceUID = deviceUID

        let engine = AVAudioEngine()
        do {
            try installInputTap(on: engine)
        } catch {
            self.deviceUID = nil
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.noteConfigurationChange() }
        }
        do {
            try startEngine(engine)
        } catch {
            removeConfigObserver()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            self.deviceUID = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    /// Rebuild the capture path on `engine`: re-select the device, re-read the
    /// input format, install a fresh converter + tap into the shared sink. The
    /// sink is untouched, so previously captured samples survive a restart.
    /// Returns the input sample rate.
    @discardableResult
    func installInputTap(on engine: AVAudioEngine) throws -> Double {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        if let deviceUID {
            guard let deviceID = AudioDevices.deviceID(forUID: deviceUID) else {
                throw RecorderError.deviceNotFound(deviceUID)
            }
            var id = deviceID
            let status = AudioUnitSetProperty(
                inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw RecorderError.engineFailed("could not select input device (status \(status))")
            }
            sink.deviceName = AudioDevices.name(of: deviceID)
        } else {
            sink.deviceName = AudioDevices.defaultInputDeviceID().flatMap { AudioDevices.name(of: $0) }
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.engineFailed("no input device available")
        }
        let converter = try SampleRateConverter(inputFormat: inputFormat)
        let sink = self.sink

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            do {
                let converted = try converter.convert(buffer)
                sink.append(converted)
            } catch {
                sink.errorOccurred(error)
            }
        }
        return inputFormat.sampleRate
    }

    /// Notification entry point — coalesces the HAL's per-event burst into a
    /// single debounced restart (150 ms quiet window). Internal for tests.
    func noteConfigurationChange() {
        guard Date() >= suppressConfigChangesUntil else { return }
        restartPending = true
        guard restartTask == nil else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.performPendingRestart()
        }
    }

    private func performPendingRestart() {
        restartTask = nil
        guard restartPending, engine != nil else { return }
        restartPending = false
        suppressConfigChangesUntil = Date().addingTimeInterval(0.25)
        handleConfigurationChange()
    }

    /// Rebuild the input chain in place. Called once per debounced
    /// configuration-change burst, and directly by tests.
    ///
    /// The engine may or may not have stopped itself by the time we run —
    /// `stop()` before `start()` covers both. A failed rebuild marks the
    /// recording failed but leaves the budget open: the *next* config change
    /// (e.g. the other app releasing the device) retries. Only a successful
    /// rebuild clears the failure.
    func handleConfigurationChange() {
        guard let engine else { return }
        guard restartBudget.consume() else {
            failRecording(RecorderError.engineFailed(
                "audio input kept changing — restart limit reached"))
            return
        }
        do {
            let rate = try installInputTap(on: engine)
            engine.stop()
            try startEngine(engine)
            sink.clearFailure()
            audioLog.info("input restarted after device config change — \(self.sink.deviceName ?? "system default", privacy: .public) @ \(rate, privacy: .public) Hz")
        } catch {
            failRecording(error)
        }
    }

    /// The engine is unusable: drop the tap, stop it, and record the failure
    /// so `stop()` throws instead of returning a truncated "no speech" take.
    private func failRecording(_ error: any Swift.Error) {
        sink.markFailed(error)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func removeConfigObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        restartTask?.cancel()
        restartTask = nil
        restartPending = false
    }

    /// Stop recording and return the accumulated audio.
    @discardableResult
    public func stop() async throws -> RecordedAudio {
        guard let engine else { throw RecorderError.notRecording }
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        deviceUID = nil
        let samples = sink.takeSamples()
        if let failure = sink.takeFailure() {
            throw failure
        }
        return RecordedAudio(buffer: AudioBuffer16k(samples: samples),
                             duration: Double(samples.count) / 16_000)
    }

    /// Abort recording; captured audio is discarded.
    public func cancel() async {
        removeConfigObserver()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        deviceUID = nil
        sink.reset()
    }
}

/// Lock-protected capture buffer fed from the realtime tap thread.
final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Installed by `makeLevelStream`/`makeChunkStream`; nil → nothing is yielded,
    /// so an unconsumed stream never buffers.
    private var levelsContinuation: AsyncStream<Float>.Continuation?
    private var chunksContinuation: AsyncStream<AudioBuffer16k>.Continuation?
    var errorHandler: (@Sendable (any Swift.Error) -> Void)?
    private var _deviceName: String?
    /// Fatal mid-recording error (config-change restart failed or exhausted) —
    /// `stop()` throws it so the failure surfaces instead of silent audio loss.
    private var _failure: (any Swift.Error)?
    var deviceName: String? {
        get { lock.withLock { _deviceName } }
        set { lock.withLock { _deviceName = newValue } }
    }

    /// A stream only lives as long as its consumer — the pipeline cancels its
    /// pump when recording stops, which terminates that stream. Each call makes
    /// a fresh stream and finishes the previous continuation under the lock.
    func makeLevelStream() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(16))
        lock.withLock {
            levelsContinuation?.finish()
            levelsContinuation = continuation
        }
        return stream
    }

    func makeChunkStream() -> AsyncStream<AudioBuffer16k> {
        let (stream, continuation) = AsyncStream<AudioBuffer16k>.makeStream(
            bufferingPolicy: .unbounded)
        lock.withLock {
            chunksContinuation?.finish()
            chunksContinuation = continuation
        }
        return stream
    }

    func reset() {
        lock.withLock {
            samples = []
            _failure = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let channelData = buffer.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: n))

        // RMS level for the meter.
        var sumSquares: Float = 0
        for s in chunk { sumSquares += s * s }
        let rms = sqrtf(sumSquares / Float(n))

        let (levelContinuation, chunkContinuation) = lock.withLock {
            samples += chunk
            return (levelsContinuation, chunksContinuation)
        }
        levelContinuation?.yield(LevelMeter.normalized(rms: rms))
        chunkContinuation?.yield(AudioBuffer16k(samples: chunk))
    }

    /// Accumulated frames — non-destructive peek for tests/harnesses.
    var sampleCount: Int { lock.withLock { samples.count } }

    func takeSamples() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }

    func errorOccurred(_ error: any Swift.Error) {
        errorHandler?(error)
    }

    /// Record a fatal mid-recording failure (keeps the first one) and report
    /// it through the same handler tap errors use.
    func markFailed(_ error: any Swift.Error) {
        let handler = lock.withLock { () -> (@Sendable (any Swift.Error) -> Void)? in
            if _failure == nil { _failure = error }
            return errorHandler
        }
        handler?(error)
    }

    /// A later successful restart clears the failure — the recording recovered.
    func clearFailure() {
        lock.withLock { _failure = nil }
    }

    func takeFailure() -> (any Swift.Error)? {
        lock.withLock {
            defer { _failure = nil }
            return _failure
        }
    }
}

/// RMS → display level for the waveform: −55 dBFS maps to 0, −15 dBFS to 1.
/// Typical dictation speech (RMS ≈ 0.01–0.02, i.e. −40…−34 dBFS) lands ≈ 0.4–0.5.
enum LevelMeter {
    static func normalized(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 55) / 40))
    }
}
