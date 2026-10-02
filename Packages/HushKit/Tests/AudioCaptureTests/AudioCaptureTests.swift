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

@Test func audioDevicesListReturnsConnectedInputs() {
    // Smoke test only — runs without touching hardware state.
    for device in AudioDevices.list() {
        #expect(!device.uid.isEmpty)
        #expect(!device.name.isEmpty)
        #expect(device.isConnected)
    }
}
