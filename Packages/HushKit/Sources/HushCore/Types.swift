import ApplicationServices
import Foundation

public struct Segment: Sendable, Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Sendable {
    public var text: String
    public var language: String?
    public var segments: [Segment]
    /// Mean segment avgLogprob per decoded language (e.g. ["en": -0.2, "id": -0.6]),
    /// when the transcriber decodes more than one candidate language.
    public var languageScores: [String: Float]

    public init(text: String, language: String? = nil, segments: [Segment] = [],
                languageScores: [String: Float] = [:]) {
        self.text = text
        self.language = language
        self.segments = segments
        self.languageScores = languageScores
    }
}

public protocol Transcriber: Sendable {
    func prepare() async throws  // load/download model
    func transcribe(_ audio: AudioBuffer16k, prompt: [String]) async throws -> Transcript
    func partials(_ stream: AsyncStream<AudioBuffer16k>, prompt: [String]) -> AsyncThrowingStream<String, Error>
}

public enum CleanupStyle: String, Codable, Sendable {
    case `default`, casual, formal, minimal
}

public protocol Cleaner: Sendable {
    func prepare() async throws
    func clean(_ raw: String, style: CleanupStyle, terms: [String]) async throws -> String
}

/// A cleaner that can report whether the last clean fell back to the rule-processed raw text.
/// `async` so actor-based cleaners can satisfy it.
public protocol FallbackReportingCleaner: Cleaner {
    var lastCleanupFellBack: Bool { get async }
}

/// What the last `clean` call did — for the pipeline timing log.
public struct CleanupRunInfo: Sendable {
    /// False when the rule-processed text was clean enough to skip the LLM.
    public var usedLLM: Bool
    /// Prompt tokens (incl. cached prefix) when `usedLLM`.
    public var promptTokens: Int
    public var generatedTokens: Int

    public init(usedLLM: Bool, promptTokens: Int = 0, generatedTokens: Int = 0) {
        self.usedLLM = usedLLM
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
    }
}

public protocol CleanupStatsReporting: Cleaner {
    var lastCleanupRun: CleanupRunInfo? { get async }
}

public struct AudioBuffer16k: Sendable {
    public var samples: [Float]  // 16 kHz mono

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval {
        Double(samples.count) / 16_000
    }
}

public struct Replacement: Codable, Sendable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public enum HotkeyEvent: Sendable, Equatable {
    case holdStart, holdEnd, toggle, cancel, pasteRaw
}

/// Per-model load lifecycle for status display.
public enum ModelLoadState: Sendable, Equatable {
    case notDownloaded
    /// fraction 0...1
    case downloading(Double)
    /// Local files present but load is slow (e.g. first-run Core ML / ANE compile).
    /// `startedAt` lets the UI show elapsed seconds.
    case optimizing(startedAt: Date)
    case loading
    case ready
    case failed(String)

    public var label: String {
        switch self {
        case .notDownloaded: "not downloaded"
        case .downloading(let f): "downloading \(Int((f * 100).rounded()))%"
        case .optimizing: "optimizing (one-time, may take several minutes)…"
        case .loading: "loading…"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }
}
