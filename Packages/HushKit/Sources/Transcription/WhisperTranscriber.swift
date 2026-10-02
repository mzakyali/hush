import Foundation
import HushCore
import OSLog
import WhisperKit

private let asrLog = Logger(subsystem: "com.local.hush", category: "asr")

/// Multilingual ASR via WhisperKit (Core ML). Auto-detect mistranslates accented
/// English into Indonesian, so `transcribe` decodes each clip twice — forced en
/// and forced id — and keeps the decode with the higher mean segment avgLogprob.
/// Dictionary terms are fed as decoder prompt tokens.
///
/// `large-v3_turbo` family names in `argmaxinc/whisperkit-coreml` (verified against the
/// repo's config.json): `openai_whisper-large-v3-v20240930_turbo_632MB` (quantized),
/// `openai_whisper-large-v3_turbo_954MB` (full), `openai_whisper-large-v3-v20240930_626MB`
/// (quantized non-turbo, the M1-recommended fallback).
public actor WhisperTranscriber: Transcriber {
    /// Quantized large-v3 turbo — preferred per plan T3.
    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// M1-recommended fallback if the turbo variant fails to load.
    public static let fallbackVariant = "openai_whisper-large-v3-v20240930_626MB"

    public enum Error: Swift.Error {
        case notPrepared
        case transcriptionFailed(String)
    }

    public let modelVariant: String
    public let modelsDirectory: URL
    /// True once `prepare()` has downloaded+loaded the model.
    public private(set) var isReady = false

    private var onProgress: (@Sendable (Double) -> Void)?
    private var whisper: WhisperKit?

    public init(modelVariant: String = WhisperTranscriber.defaultVariant,
                modelsDirectory: URL = AppPaths().modelsWhisper,
                onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.modelVariant = modelVariant
        self.modelsDirectory = modelsDirectory
        self.onProgress = onProgress
    }

    /// Directory WhisperKit downloads the variant into: `<base>/models/<repo>/<variant>`.
    public var localModelFolder: URL {
        modelsDirectory
            .appending(path: "models/argmaxinc/whisperkit-coreml")
            .appending(path: modelVariant)
    }

    /// True when the variant's compiled Core ML models are already on disk —
    /// `prepare` can then load without touching the network.
    public var hasLocalModel: Bool {
        FileManager.default.fileExists(
            atPath: localModelFolder.appending(path: "AudioEncoder.mlmodelc").path)
    }

    public func setProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        onProgress = handler
    }

    public func prepare() async throws {
        if isReady { return }
        // Offline-first: when the model folder is already on disk, point WhisperKit
        // at it with download disabled so launch makes zero hub requests. Missing
        // files → fetch with progress, then load the same local path.
        var folder = localModelFolder
        if !hasLocalModel {
            folder = try await WhisperKit.download(
                variant: modelVariant,
                downloadBase: modelsDirectory,
                progressCallback: { [onProgress] progress in
                    onProgress?(progress.fractionCompleted)
                })
        }
        let config = WhisperKitConfig(
            downloadBase: modelsDirectory,  // tokenizer search root (local hit)
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        self.whisper = whisper
        isReady = true
    }

    /// Languages decoded for every clip, in tie-break order (en wins ties).
    static let decodeLanguages = ["en", "id"]

    public func transcribe(_ audio: AudioBuffer16k, prompt: [String]) async throws -> Transcript {
        guard let whisper else { throw Error.notPrepared }
        let promptTokens = promptTokenIDs(for: prompt)

        struct Decode {
            var language: String
            var text: String
            var segments: [Segment]
            var score: Float
            var seconds: Double
        }

        var decodes: [Decode] = []
        decodes.reserveCapacity(Self.decodeLanguages.count)
        for language in Self.decodeLanguages {
            var options = DecodingOptions(
                language: language,
                detectLanguage: false,
                withoutTimestamps: false
            )
            if !promptTokens.isEmpty {
                options.promptTokens = promptTokens
            }
            let started = Date()
            let results = await whisper.transcribeWithResults(
                audioArrays: [audio.samples],
                decodeOptions: options
            )
            let seconds = Date().timeIntervalSince(started)
            guard let first = results.first else {
                throw Error.transcriptionFailed("no result")
            }
            let result = try first.get()
            let rawSegments = result.flatMap(\.segments)
            let segments = rawSegments.map {
                Segment(start: Double($0.start), end: Double($0.end), text: $0.text)
            }
            let score = rawSegments.isEmpty
                ? -.infinity
                : rawSegments.map(\.avgLogprob).reduce(0, +) / Float(rawSegments.count)
            decodes.append(Decode(
                language: language,
                text: result.map(\.text).joined(),
                segments: segments,
                score: score,
                seconds: seconds
            ))
        }

        let candidates = decodes.map { (language: $0.language, text: $0.text, score: $0.score) }
        let winner = decodes[Self.pick(candidates)]
        let enDetail = String(format: "en lp=%.3f t=%.2fs", decodes[0].score, decodes[0].seconds)
        let idDetail = String(format: "id lp=%.3f t=%.2fs", decodes[1].score, decodes[1].seconds)
        asrLog.info(
            "asr: \(enDetail, privacy: .public) | \(idDetail, privacy: .public) → \(winner.language, privacy: .public)"
        )
        var scores: [String: Float] = [:]
        for d in decodes { scores[d.language] = d.score }
        return Transcript(
            text: Self.stripWrappingQuotes(winner.text),
            language: winner.language,
            segments: winner.segments,
            languageScores: scores
        )
    }

    /// Index of the best decode by mean avgLogprob. Empty/whitespace text scores
    /// −∞; ties keep the earlier candidate (en is decoded first → en wins ties).
    static func pick(_ candidates: [(language: String, text: String, score: Float)]) -> Int {
        var best = 0
        var bestScore: Float = -.infinity
        for (i, candidate) in candidates.enumerated() {
            let score = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? -.infinity : candidate.score
            if score > bestScore {
                best = i
                bestScore = score
            }
        }
        return best
    }

    /// Forced-language decodes sometimes wrap the whole transcript in quotes —
    /// strip one outer pair (straight or curly double).
    static func stripWrappingQuotes(_ text: String) -> String {
        for (open, close) in [("\"", "\""), ("“", "”")] {
            if text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }

    /// Re-transcribes the accumulated buffer at most every `interval` seconds,
    /// cancelling any in-flight partial. Final transcription runs on stop, not here.
    public nonisolated func partials(
        _ stream: AsyncStream<AudioBuffer16k>,
        prompt: [String]
    ) -> AsyncThrowingStream<String, any Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples: [Float] = []
                var lastEmit = Date.distantPast
                var inflight: Task<String, Swift.Error>?
                for try await chunk in stream {
                    samples += chunk.samples
                    let now = Date()
                    guard now.timeIntervalSince(lastEmit) >= 1.0, !samples.isEmpty else { continue }
                    lastEmit = now
                    inflight?.cancel()
                    let snapshot = samples
                    let task = Task<String, any Swift.Error> {
                        let transcript = try await self.transcribe(
                            AudioBuffer16k(samples: snapshot), prompt: prompt)
                        return transcript.text
                    }
                    inflight = task
                    do {
                        // Awaiting `task.value` alone doesn't propagate outer cancellation —
                        // the partial would keep the WhisperKit actor busy and delay the
                        // final transcription. Cancel it when this stream is cancelled.
                        let text = try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: {
                            task.cancel()
                        }
                        if !Task.isCancelled {
                            continuation.yield(text)
                        }
                    } catch {
                        // A superseded in-flight partial is expected; surface real errors.
                        if !(error is CancellationError) {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                inflight?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tokenize dictionary terms for `DecodingOptions.promptTokens`.
    /// Whisper treats these as "previous text" conditioning.
    private func promptTokenIDs(for terms: [String]) -> [Int] {
        guard let tokenizer = whisper?.tokenizer, !terms.isEmpty else { return [] }
        let text = terms.joined(separator: ", ")
        // Whisper's prompt budget is ~224 tokens; keep the tail.
        return Array(tokenizer.encode(text: text).suffix(200))
    }
}
