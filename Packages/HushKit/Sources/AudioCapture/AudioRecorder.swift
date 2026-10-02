import AVFoundation
import CoreAudio
import Foundation
import HushCore

public enum RecorderError: Swift.Error {
    case alreadyRecording
    case notRecording
    case converterFailed
    case deviceNotFound(String)
    case engineFailed(String)
}

/// Records microphone audio as 16 kHz mono Float32. Levels and converted chunks are
/// published through per-recording AsyncStreams (`makeLevelStream`/`makeChunkStream`)
/// for the overlay and streaming ASR partials.
public actor AudioRecorder: AudioRecording {
    /// Set at `start`; nonisolated so it satisfies the protocol's sync getter.
    public nonisolated var activeDeviceName: String? { sink.deviceName }

    private let sink = CaptureSink()
    private var engine: AVAudioEngine?

    public init() {}

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

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

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

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
    }

    /// Stop recording and return the accumulated audio.
    @discardableResult
    public func stop() async throws -> RecordedAudio {
        guard let engine else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        let samples = sink.takeSamples()
        return RecordedAudio(buffer: AudioBuffer16k(samples: samples),
                             duration: Double(samples.count) / 16_000)
    }

    /// Abort recording; captured audio is discarded.
    public func cancel() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
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
        lock.withLock { samples = [] }
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

    func takeSamples() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }

    func errorOccurred(_ error: any Swift.Error) {
        errorHandler?(error)
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
