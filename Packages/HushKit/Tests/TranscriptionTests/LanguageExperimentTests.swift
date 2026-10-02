import AVFoundation
import Foundation
import HushCore
import Testing
@testable import Transcription
import WhisperKit

/// Opt-in experiment: replays saved recordings (m4a, 16 kHz mono) through
/// Whisper with auto / forced-en / forced-id decoding and prints language
/// probabilities, text, avg log-prob and timing for each.
/// Run: HUSH_INTEGRATION=1 HUSH_LANG_DIR=<dir> swift test --filter languageExperiment
private let langDir = ProcessInfo.processInfo.environment["HUSH_LANG_DIR"]
private let experimentEnabled =
    ProcessInfo.processInfo.environment["HUSH_INTEGRATION"] == "1" && langDir != nil

private func loadMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    let n = Int(pcm.frameLength)
    let channels = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for ch in 0 ..< channels {
        let data = pcm.floatChannelData![ch]
        for i in 0 ..< n { mono[i] += data[i] / Float(channels) }
    }
    precondition(format.sampleRate == 16_000, "expected 16 kHz, got \(format.sampleRate)")
    return mono
}

private struct Run {
    let text: String
    let language: String
    let avgLogprob: Float
    let seconds: Double
}

private func decode(_ whisper: WhisperKit, _ samples: [Float], language: String?) async throws -> Run {
    let options = DecodingOptions(
        language: language,
        detectLanguage: language == nil,
        withoutTimestamps: false
    )
    let start = Date()
    let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
    let seconds = Date().timeIntervalSince(start)
    let segments = results.flatMap(\.segments)
    let avg = segments.isEmpty ? 0 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
    return Run(
        text: results.map(\.text).joined().trimmingCharacters(in: .whitespaces),
        language: results.first?.language ?? "?",
        avgLogprob: avg,
        seconds: seconds
    )
}

@Test(.enabled(if: experimentEnabled))
func languageExperiment() async throws {
    let dir = URL(fileURLWithPath: langDir!)
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "m4a" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let transcriber = WhisperTranscriber()
    try await transcriber.prepare()
    let config = WhisperKitConfig(
        downloadBase: await transcriber.modelsDirectory,
        modelFolder: await transcriber.localModelFolder.path,
        verbose: false, logLevel: .error, load: true, download: false
    )
    let whisper = try await WhisperKit(config)

    for file in files {
        let samples = try loadMono16k(file)
        let peak = samples.map(abs).max() ?? 0
        let detected = try await whisper.detectLangauge(audioArray: samples)
        let en = detected.langProbs["en"] ?? -.infinity
        let id = detected.langProbs["id"] ?? -.infinity
        let normalized = peak > 0 ? samples.map { $0 * (0.5 / peak) } : samples
        let detectedNorm = try await whisper.detectLangauge(audioArray: normalized)

        let auto = try await decode(whisper, samples, language: nil)
        let forcedEN = try await decode(whisper, samples, language: "en")
        let forcedID = try await decode(whisper, samples, language: "id")
        let picked = try await transcriber.transcribe(AudioBuffer16k(samples: samples), prompt: [])

        print("""
        [lang] ==== \(file.lastPathComponent) dur=\(String(format: "%.2f", Double(samples.count) / 16_000))s peak=\(String(format: "%.3f", peak))
        [lang] detect top=\(detected.language) logp(en)=\(String(format: "%.2f", en)) logp(id)=\(String(format: "%.2f", id)) | normalized top=\(detectedNorm.language) logp(en)=\(String(format: "%.2f", detectedNorm.langProbs["en"] ?? 0)) logp(id)=\(String(format: "%.2f", detectedNorm.langProbs["id"] ?? 0))
        [lang] auto[\(auto.language)] lp=\(String(format: "%.3f", auto.avgLogprob)) t=\(String(format: "%.2f", auto.seconds)): \(auto.text)
        [lang] en         lp=\(String(format: "%.3f", forcedEN.avgLogprob)) t=\(String(format: "%.2f", forcedEN.seconds)): \(forcedEN.text)
        [lang] id         lp=\(String(format: "%.3f", forcedID.avgLogprob)) t=\(String(format: "%.2f", forcedID.seconds)): \(forcedID.text)
        [lang] PICKED[\(picked.language ?? "?")]: \(picked.text.trimmingCharacters(in: .whitespaces))
        """)
    }
}
