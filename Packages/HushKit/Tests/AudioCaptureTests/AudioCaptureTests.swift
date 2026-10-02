import AVFoundation
import Foundation
import Testing
@testable import AudioCapture
import HushCore

@Test func resampler48kSineTo16k() throws {
    // 1 s of 440 Hz sine at 48 kHz.
    let inputRate = 48_000.0
    let frequency = 440.0
    let samples = (0 ..< 48_000).map { i in
        Float(sin(2 * .pi * frequency * Double(i) / inputRate)) * 0.5
    }

    let converter = try SampleRateConverter(inputSampleRate: inputRate)
    let output = try converter.convertSamples(samples, inputRate: inputRate)

    // Length: within 2% of the expected 16 000 samples.
    #expect(abs(Double(output.count) - 16_000) < 320)

    // Frequency: count positive-going zero crossings in the middle 0.5 s.
    let mid = Array(output[4_000 ..< 12_000])
    var crossings = 0
    for i in 1 ..< mid.count where mid[i - 1] < 0 && mid[i] >= 0 {
        crossings += 1
    }
    let measured = Double(crossings) / 0.5
    #expect(abs(measured - frequency) < 5)
}

/// Regression: streaming conversion must keep producing output across many
/// convert() calls on ONE converter instance (the recorder's tap calls it per
/// buffer). The input block previously returned .endOfStream, which ended the
/// shared AVAudioConverter permanently — every buffer after the first yielded
/// 0 frames and recordings came out ~85 ms long ("no speech").
private func expectStreamingConversion(inputRate: Double, bufferFrames: Int = 4800,
                                       bufferCount: Int = 4) throws {
    let converter = try SampleRateConverter(inputSampleRate: inputRate)
    let ratio = SampleRateConverter.outputSampleRate / inputRate
    var totalOut = 0
    for b in 0 ..< bufferCount {
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(bufferFrames))
        else { Issue.record("alloc failed"); return }
        input.frameLength = AVAudioFrameCount(bufferFrames)
        let dest = input.floatChannelData![0]
        for i in 0 ..< bufferFrames {
            dest[i] = Float(sin(2 * .pi * 440 * Double(b * bufferFrames + i) / inputRate)) * 0.5
        }
        let output = try converter.convert(input)
        totalOut += Int(output.frameLength)
        let expected = Double(bufferFrames) * ratio
        // Buffer 0 loses ~15% to resampler priming; later chunks must produce
        // near-full output — this is what the bug broke (they yielded 0).
        let tolerance = b == 0 ? 0.25 : 0.05
        #expect(abs(Double(output.frameLength) - expected) < expected * tolerance,
                "buffer \(b): got \(output.frameLength) frames, expected ~\(Int(expected))")
    }
    // The resampler holds a latency tail that never flushes without EOS —
    // allow ~5% under the ideal total.
    let totalExpected = Double(bufferFrames * bufferCount) * ratio
    #expect(abs(Double(totalOut) - totalExpected) < totalExpected * 0.05)
}

@Test func streamingConversion48kEveryBuffer() throws {
    try expectStreamingConversion(inputRate: 48_000)
}

@Test func streamingConversion44k1EveryBuffer() throws {
    try expectStreamingConversion(inputRate: 44_100)
}

@Test func m4aRoundTripDuration() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "hush-test-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }

    // 1.5 s of audio.
    let samples = (0 ..< 24_000).map { i in
        Float(sin(2 * .pi * 220 * Double(i) / 16_000)) * 0.3
    }
    try AudioEncoder.writeM4A(AudioBuffer16k(samples: samples), to: url)

    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.fileFormat.sampleRate
    #expect(abs(duration - 1.5) < 0.050)
}

// MARK: - LevelMeter

@Test func levelMeterDbMapping() {
    // −55 dBFS → 0, −15 dBFS → 1 (clamped).
    #expect(LevelMeter.normalized(rms: 0) == 0)
    #expect(LevelMeter.normalized(rms: 1e-9) == 0)
    #expect(abs(LevelMeter.normalized(rms: Float(pow(10.0, -55.0 / 20.0))) - 0) < 0.01)
    #expect(abs(LevelMeter.normalized(rms: Float(pow(10.0, -15.0 / 20.0))) - 1) < 0.01)
    #expect(LevelMeter.normalized(rms: 0.5) == 1)
    // Quiet-dictation speech (measured RMS ≈ 0.01–0.02) reads mid-scale —
    // the old rms*4 mapping put the same level at 0.06, barely visible.
    let quiet = LevelMeter.normalized(rms: 0.015)
    #expect(quiet > 0.35 && quiet < 0.6)
}

// MARK: - CaptureSink streams

private func makePCMBuffer(_ samples: [Float] = [0.1, -0.1, 0.2, -0.2]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
        interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
    return buffer
}

@Test func levelStreamReceivesAppendedChunks() async {
    let sink = CaptureSink()
    var it = sink.makeLevelStream().makeAsyncIterator()
    sink.append(makePCMBuffer())
    let level = await it.next()
    #expect(level != nil && level! > 0)
}

/// Regression for the flat second-recording waveform: an AsyncStream terminates
/// when its consumer is cancelled (verified: a second iterator on the same
/// stream gets nil immediately and later yields return .terminated). Each
/// recording therefore gets a fresh stream from makeLevelStream — the sink
/// finishes the previous continuation and installs the new one.
@Test func freshLevelStreamAfterConsumerCancelled() async {
    let sink = CaptureSink()

    // Recording 1: consume one level, then cancel the pump (as stop() does).
    let stream1 = sink.makeLevelStream()
    let pump1 = Task { for await _ in stream1 {} }
    sink.append(makePCMBuffer())
    try? await Task.sleep(nanoseconds: 20_000_000)
    pump1.cancel()
    try? await Task.sleep(nanoseconds: 20_000_000)

    // Recording 2: a fresh stream receives new levels.
    var it = sink.makeLevelStream().makeAsyncIterator()
    sink.append(makePCMBuffer())
    let level = await it.next()
    #expect(level != nil && level! > 0)
}

/// With no chunk consumer installed, append yields chunks nowhere — samples
/// still accumulate (that path feeds stop() → transcription).
@Test func appendWithoutChunkConsumerRetainsNothing() async {
    let sink = CaptureSink()
    sink.append(makePCMBuffer([0.05, 0.05, 0.05]))
    #expect(sink.takeSamples().count == 3)
}

// MARK: - configuration-change restart

/// The Discord-call scenario: another app changes the shared input device,
/// AVAudioEngine stops itself. `handleConfigurationChange` rebuilds the tap
/// onto the same sink — samples captured before AND after the restart must
/// all come back from takeSamples()/stop().
@Test func restartPreservesSamplesAcrossRebuild() async throws {
    let recorder = AudioRecorder()
    // No real I/O in tests — replace prepare()+start() with a no-op.
    await recorder.setEngineStarter { _ in }
    try await recorder.start(deviceUID: nil)

    recorder.sink.append(makePCMBuffer([0.1, 0.2, 0.3]))   // "before" audio
    await recorder.handleConfigurationChange()             // simulated restart
    recorder.sink.append(makePCMBuffer([0.4, 0.5]))        // "after" audio

    let audio = try await recorder.stop()
    #expect(audio.buffer.samples == [0.1, 0.2, 0.3, 0.4, 0.5])
}

/// Restarts are capped per recording; once the budget is exhausted the
/// recording is marked failed and stop() throws instead of silently
/// returning a truncated take.
@Test func restartCapSurfacesErrorAtStop() async throws {
    let recorder = AudioRecorder()
    await recorder.setEngineStarter { _ in }
    try await recorder.start(deviceUID: nil)

    for _ in 0 ..< RestartBudget.limit {       // all within budget — OK
        await recorder.handleConfigurationChange()
    }
    recorder.sink.append(makePCMBuffer([0.1]))
    await recorder.handleConfigurationChange()  // one over → marked failed

    await #expect(throws: RecorderError.self) {
        _ = try await recorder.stop()
    }
}

/// A failed rebuild doesn't kill the recording permanently: the next config
/// change retries (the other app released the device) and clears the failure.
@Test func failedRestartRetriesOnNextChange() async throws {
    struct Boom: Error {}
    let recorder = AudioRecorder()
    let failing = MutexedFlag()
    await recorder.setEngineStarter { engine in
        engine.prepare()
        if failing.value { throw Boom() }
    }
    try await recorder.start(deviceUID: nil)

    failing.set(true)
    await recorder.handleConfigurationChange()   // restart fails → marked
    // The other app released the device: the next change retries and wins.
    failing.set(false)
    await recorder.handleConfigurationChange()
    recorder.sink.append(makePCMBuffer([0.9]))
    let audio = try await recorder.stop()
    #expect(audio.buffer.samples == [0.9])
}

/// One reconfiguration posts a burst of notifications (a hog event fired 6+
/// in ~1.5 s in the harness). They must coalesce into ONE restart — without
/// the debounce a single Discord-call event burned the whole restart budget.
@Test func configChangeBurstCoalescesToOneRestart() async throws {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }
    let starts = Counter()
    let recorder = AudioRecorder()
    await recorder.setEngineStarter { engine in
        engine.prepare()
        starts.bump()
    }
    try await recorder.start(deviceUID: nil)      // 1 start

    for _ in 0 ..< 6 { await recorder.noteConfigurationChange() }
    try? await Task.sleep(for: .milliseconds(800))  // past the 150 ms quiet window

    #expect(starts.value == 2)                    // start + one coalesced restart
    recorder.sink.append(makePCMBuffer([0.5]))
    let audio = try await recorder.stop()
    #expect(audio.buffer.samples == [0.5])
}

/// A second, well-separated event still restarts — debounce only collapses
/// bursts, it doesn't swallow later changes. (The 700 ms gap clears the
/// 150 ms debounce + 250 ms self-notification suppression.)
@Test func separatedConfigChangesEachRestart() async throws {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }
    let starts = Counter()
    let recorder = AudioRecorder()
    await recorder.setEngineStarter { engine in
        engine.prepare()
        starts.bump()
    }
    try await recorder.start(deviceUID: nil)

    await recorder.noteConfigurationChange()
    try? await Task.sleep(for: .milliseconds(700))
    await recorder.noteConfigurationChange()
    try? await Task.sleep(for: .milliseconds(700))

    #expect(starts.value == 3)                    // start + two restarts
    _ = try await recorder.stop()
}

private final class MutexedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.withLock { flag } }
    func set(_ v: Bool) { lock.withLock { flag = v } }
}

@Test func restartBudgetCountsToFive() {
    var budget = RestartBudget()
    var results: [Bool] = []
    for _ in 0 ..< 7 { results.append(budget.consume()) }
    #expect(results == [true, true, true, true, true, false, false])
}

@Test func audioDevicesListReturnsConnectedInputs() {
    // Smoke test only — runs without touching hardware state.
    for device in AudioDevices.list() {
        #expect(!device.uid.isEmpty)
        #expect(!device.name.isEmpty)
        #expect(device.isConnected)
    }
}
