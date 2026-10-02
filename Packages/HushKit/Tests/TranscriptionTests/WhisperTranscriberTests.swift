import AVFoundation
import Foundation
import Testing
@testable import Transcription
import AudioCapture
import HushCore

private let integrationEnabled = ProcessInfo.processInfo.environment["HUSH_INTEGRATION"] == "1"

@Test func notReadyBeforePrepare() async {
    let t = WhisperTranscriber(modelsDirectory: FileManager.default.temporaryDirectory)
    #expect(!(await t.isReady))
    await #expect(throws: (any Error).self) {
        _ = try await t.transcribe(AudioBuffer16k(samples: [0, 0]), prompt: [])
    }
}

// MARK: - dual-decode selection

@Test func pickChoosesHigherScore() {
    let candidates = [
        (language: "en", text: "hello there", score: Float(-0.5)),
        (language: "id", text: "halo di sana", score: Float(-0.2)),
    ]
    #expect(WhisperTranscriber.pick(candidates) == 1)
}

@Test func pickTreatsEmptyTextAsLosing() {
    // Empty text scores −∞ no matter what avgLogprob says — a real clip where
    // forced-id returned "" with lp 0 while forced-en decoded the speech.
    let candidates = [
        (language: "en", text: "is there any way", score: Float(-0.17)),
        (language: "id", text: "", score: Float(0)),
    ]
    #expect(WhisperTranscriber.pick(candidates) == 0)
    let whitespace = [
        (language: "en", text: "is there any way", score: Float(-0.9)),
        (language: "id", text: "   ", score: Float(0)),
    ]
    #expect(WhisperTranscriber.pick(whitespace) == 0)
    // Both empty → the earlier candidate (en) is kept.
    let bothEmpty = [
        (language: "en", text: "", score: Float(0)),
        (language: "id", text: "", score: Float(0)),
    ]
    #expect(WhisperTranscriber.pick(bothEmpty) == 0)
}

@Test func pickBreaksTiesTowardEnglish() {
    let candidates = [
        (language: "en", text: "testing, testing", score: Float(-0.05)),
        (language: "id", text: "testing, testing", score: Float(-0.05)),
    ]
    #expect(WhisperTranscriber.pick(candidates) == 0)
}

@Test func stripWrappingQuotesRemovesOnePair() {
    #expect(WhisperTranscriber.stripWrappingQuotes("\"hello world\"") == "hello world")
    #expect(WhisperTranscriber.stripWrappingQuotes("“hello world”") == "hello world")
    // One pair only.
    #expect(WhisperTranscriber.stripWrappingQuotes("\"\"hi\"\"") == "\"hi\"")
    // Mismatched / unclosed quotes stay.
    #expect(WhisperTranscriber.stripWrappingQuotes("\"hello world") == "\"hello world")
    #expect(WhisperTranscriber.stripWrappingQuotes("she said \"hi\" today") == "she said \"hi\" today")
}

/// Synthesize speech with `say`, resample to 16 kHz mono Float samples.
private func synthesize(voice: String, text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", voice, "-o", url.path, text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RecorderError.engineFailed("say failed for voice \(voice)")
    }
}

private func readWAV16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: file.fileFormat.sampleRate,
        channels: file.fileFormat.channelCount,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount(file.length)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw RecorderError.engineFailed("cannot allocate buffer")
    }
    try file.read(into: pcm)
    let channels = Int(format.channelCount)
    let n = Int(pcm.frameLength)
    var mono = [Float](repeating: 0, count: n)
    for ch in 0 ..< channels {
        let data = pcm.floatChannelData![ch]
        for i in 0 ..< n { mono[i] += data[i] }
    }
    return mono.map { $0 / Float(channels) }
}

@Test(.enabled(if: integrationEnabled))
func whisperIntegrationEnglish() async throws {
    let dir = FileManager.default.temporaryDirectory
    let aiff = dir.appending(path: "hush-en-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: aiff) }

    try synthesize(
        voice: "Samantha",
        text: "Please deploy the build to production after lunch",
        to: aiff
    )
    let samples = try readWAV16k(aiff)
    let converter = try SampleRateConverter(inputSampleRate: 22_050)  // say's AIFF rate on this Mac
    let resampled = try converter.convertSamples(
        samples, inputRate: AVAudioFile(forReading: aiff).fileFormat.sampleRate)

    let transcriber = WhisperTranscriber()
    let loadStart = Date()
    try await transcriber.prepare()
    print("[integration] model ready in \(Date().timeIntervalSince(loadStart))s")

    let start = Date()
    let transcript = try await transcriber.transcribe(
        AudioBuffer16k(samples: resampled), prompt: [])
    let latency = Date().timeIntervalSince(start)
    print("[integration] EN transcript (\(String(format: "%.2f", latency))s): \(transcript.text)")
    print("[integration] EN language: \(transcript.language ?? "?")")

    // Measure how much an in-flight partial delays the final transcription.
    // Feed the same audio through the partials stream, let it start decoding,
    // then request the final — the partial must be cancelled so the final runs.
    let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: AudioBuffer16k.self)
    let partials = transcriber.partials(chunkStream, prompt: [])
    var partialIt = partials.makeAsyncIterator()
    let partialTask = Task { try? await partialIt.next() }
    chunkContinuation.yield(AudioBuffer16k(samples: resampled))
    try await Task.sleep(nanoseconds: 200_000_000)  // let the partial start decoding

    let start2 = Date()
    let finalTask = Task { try await transcriber.transcribe(
        AudioBuffer16k(samples: resampled), prompt: []) }
    // Simulate the pipeline's stop: terminate the partials stream while final runs.
    chunkContinuation.finish()
    let transcript2 = try await finalTask.value
    let latency2 = Date().timeIntervalSince(start2)
    print("[integration] EN final with in-flight partial (\(String(format: "%.2f", latency2))s): \(transcript2.text)")
    partialTask.cancel()

    let start3 = Date()
    _ = try await transcriber.transcribe(AudioBuffer16k(samples: resampled), prompt: [])
    print("[integration] EN final without partial (\(String(format: "%.2f", Date().timeIntervalSince(start3)))s)")

    #expect(transcript.text.localizedCaseInsensitiveContains("production"))
}

@Test(.enabled(if: integrationEnabled))
func whisperIntegrationIndonesian() async throws {
    let dir = FileManager.default.temporaryDirectory
    let aiff = dir.appending(path: "hush-id-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: aiff) }

    try synthesize(
        voice: "Damayanti",
        text: "Nanti kita rapat jam tiga sore",
        to: aiff
    )
    let samples = try readWAV16k(aiff)
    let actualRate = try AVAudioFile(forReading: aiff).fileFormat.sampleRate
    let converter = try SampleRateConverter(inputSampleRate: actualRate)
    let resampled = try converter.convertSamples(samples, inputRate: actualRate)

    let transcriber = WhisperTranscriber()
    try await transcriber.prepare()

    let start = Date()
    let transcript = try await transcriber.transcribe(
        AudioBuffer16k(samples: resampled), prompt: [])
    let latency = Date().timeIntervalSince(start)
    print("[integration] ID transcript (\(String(format: "%.2f", latency))s): \(transcript.text)")
    print("[integration] ID language: \(transcript.language ?? "?")")

    #expect(transcript.text.localizedCaseInsensitiveContains("rapat"))
}
