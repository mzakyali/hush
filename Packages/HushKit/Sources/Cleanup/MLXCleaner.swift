import Foundation
import Hub
import HushCore
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM

/// Local cleanup LLM via mlx-swift-lm.
///
/// Default: `mlx-community/Qwen3-4B-Instruct-2507-4bit` (non-thinking instruct, text-only)
/// via `LLMModelFactory` (MLXLLM). Fallback if it fails to load:
/// `mlx-community/gemma-3-4b-it-4bit` — a vision-language model that must load through
/// `VLMModelFactory` (MLXVLM) instead.
///
/// Lazy load; the model is unloaded after `idleUnloadAfter` seconds of no use.
///
/// The system prompt (~250 tokens) is KV-prefilled once per prompt text and reused:
/// each request copies the cached prefix (`KVCache.copy()`) and prefills only the
/// user-turn tokens on top of it. The split is only used after verifying that
/// `template([system]) + template([user]) == template([system, user])` for the loaded
/// model; otherwise the full prompt is prefilled per request.
public actor MLXCleaner: Cleaner {
    public static let defaultModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    public static let fallbackModelID = "mlx-community/gemma-3-4b-it-4bit"
    public static let defaultIdleUnload: TimeInterval = 600  // 10 min, spec §4

    public enum Error: Swift.Error {
        case notPrepared
        case loadFailed(String)
    }

    /// Prefill/decode split of the most recent `clean` call (for benchmarking).
    public struct RunStats: Sendable {
        /// Tokens prefilled for this request (user turn only when the prefix was cached).
        public var promptTokens: Int
        /// System-prompt tokens skipped via the prefix KV cache (0 if unused).
        public var cachedPrefixTokens: Int
        /// Prefill + first-token time reported by the generation loop.
        public var promptTime: TimeInterval
        /// Decode time for the remaining generated tokens.
        public var generateTime: TimeInterval
        public var generatedTokens: Int
        public var stopReason: GenerateStopReason
        /// Wall-clock time of the whole `clean` call (template + prefill + decode).
        public var totalTime: TimeInterval
    }

    /// Holds a prefix KV cache across `ModelContainer.perform` calls. The caches are
    /// only touched inside `perform` (which serializes model access), and are never
    /// mutated after being stored — requests run on `copy()`s.
    private final class PrefixCacheBox: @unchecked Sendable {
        let caches: [any KVCache]
        let tokenCount: Int
        init(caches: [any KVCache], tokenCount: Int) {
            self.caches = caches
            self.tokenCount = tokenCount
        }
    }

    private struct CleanOutcome: Sendable {
        var text: String
        var info: GenerateCompletionInfo?
        var prefixTokenCount: Int
        var newPrefixBox: PrefixCacheBox?
        var prefixUnsupported: Bool
    }

    public let modelID: String
    public let modelsDirectory: URL
    public let idleUnloadAfter: TimeInterval
    /// Explicit factory (e.g. `LLMModelFactory.shared`) to pin LLM vs VLM loading;
    /// nil = the registry picks the first factory that claims the model type.
    private let modelFactory: (any ModelFactory)?
    private var onProgress: (@Sendable (Double) -> Void)?
    /// Extra chat-template context (e.g. `["enable_thinking": false]` for Qwen3).
    private let additionalContext: [String: any Sendable]?
    /// Reuse the system-prompt KV prefix across calls (see type doc).
    public private(set) var usePrefixCache: Bool

    public func setUsePrefixCache(_ enabled: Bool) {
        usePrefixCache = enabled
    }

    private var container: ModelContainer?
    private var unloadTask: Task<Void, Never>?
    /// Prefix KV caches keyed by system-prompt text.
    private var prefixBoxes: [String: PrefixCacheBox] = [:]
    /// System prompts whose template prefix can't be split off cleanly.
    private var prefixUnsupported: Set<String> = []
    /// Stats of the most recent `clean` call.
    public private(set) var lastRunStats: RunStats?

    public var isReady: Bool { container != nil }

    public init(modelID: String = MLXCleaner.defaultModelID,
                modelsDirectory: URL = AppPaths().modelsLLM,
                idleUnloadAfter: TimeInterval = MLXCleaner.defaultIdleUnload,
                modelFactory: (any ModelFactory)? = nil,
                additionalContext: [String: any Sendable]? = nil,
                usePrefixCache: Bool = true,
                onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.modelID = modelID
        self.modelsDirectory = modelsDirectory
        self.idleUnloadAfter = idleUnloadAfter
        self.modelFactory = modelFactory
        self.additionalContext = additionalContext
        self.usePrefixCache = usePrefixCache
        self.onProgress = onProgress
    }

    public func setProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        onProgress = handler
    }

    /// Directory HubApi downloads the model into: `<base>/models/<org>/<name>`.
    public var localModelDirectory: URL {
        modelsDirectory.appending(path: "models").appending(path: modelID)
    }

    /// True when the model's config + weights are already on disk —
    /// `prepare` can then load without touching the network.
    public var hasLocalModel: Bool {
        FileManager.default.fileExists(
            atPath: localModelDirectory.appending(path: "config.json").path)
    }

    /// Download (if needed) and load the model.
    public func prepare() async throws {
        guard container == nil else { return }
        let hub = HubApi(downloadBase: modelsDirectory)
        // Offline-first: with a complete local snapshot, `.directory` makes
        // `downloadModel` return immediately — zero hub requests.
        let configuration = hasLocalModel
            ? ModelConfiguration(directory: localModelDirectory)
            : ModelConfiguration(id: modelID)
        do {
            if let modelFactory {
                container = try await modelFactory.loadContainer(
                    hub: hub, configuration: configuration
                ) { [onProgress] progress in
                    onProgress?(progress.fractionCompleted)
                }
            } else {
                container = try await loadModelContainer(
                    hub: hub, configuration: configuration
                ) { [onProgress] progress in
                    onProgress?(progress.fractionCompleted)
                }
            }
        } catch {
            throw Error.loadFailed("\(modelID): \(error.localizedDescription)")
        }
    }

    /// Release the model so a future `clean` reloads it (memory pressure / idle).
    public func unload() {
        unloadTask?.cancel()
        container = nil
        prefixBoxes.removeAll()
        prefixUnsupported.removeAll()
    }

    /// Clean a transcript. Max tokens = 2 × raw token count + 64; temperature 0.
    /// The caller (`GuardedCleaner`) applies the fallback guard and timeout.
    public func clean(_ raw: String, style: CleanupStyle, terms: [String]) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else { throw Error.notPrepared }
        scheduleUnload()

        let started = Date()
        let systemPrompt = CleanupPrompt.system(style: style, terms: terms)
        let userPrompt = CleanupPrompt.user(raw)
        let maxTokens = await tokenCount(of: raw) * 2 + 64
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        let additionalContext = self.additionalContext
        let cachedBox = usePrefixCache ? prefixBoxes[systemPrompt] : nil
        let mayBuildPrefix = usePrefixCache && !prefixUnsupported.contains(systemPrompt)

        let outcome = try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model

            func template(_ messages: [Message], gen: Bool) throws -> [Int] {
                try tokenizer.applyChatTemplate(
                    messages: messages,
                    chatTemplate: nil,
                    addGenerationPrompt: gen,
                    truncation: false,
                    maxLength: nil,
                    tools: nil,
                    additionalContext: additionalContext
                )
            }

            let systemMessage: Message = ["role": "system", "content": systemPrompt]
            let userMessage: Message = ["role": "user", "content": userPrompt]

            var cache: [any KVCache]
            var prefixTokenCount = 0
            var newBox: PrefixCacheBox?
            var unsupported = false

            if let cachedBox {
                let inputTokens = try template([userMessage], gen: true)
                cache = cachedBox.caches.map { $0.copy() }
                eval(cache)
                prefixTokenCount = cachedBox.tokenCount
                let (o, i) = try await Self.generate(
                    inputTokens: inputTokens, cache: cache,
                    parameters: parameters, context: context)
                return CleanOutcome(
                    text: o, info: i, prefixTokenCount: prefixTokenCount,
                    newPrefixBox: nil, prefixUnsupported: false)
            }

            var inputTokens: [Int]
            if mayBuildPrefix {
                let userTokens = try template([userMessage], gen: true)
                let fullTokens = try template([systemMessage, userMessage], gen: true)
                let prefixTokens = try? template([systemMessage], gen: false)
                if let prefixTokens, prefixTokens + userTokens == fullTokens {
                    // Prefill the system-prompt prefix into a fresh cache once.
                    let prefix = model.newCache(parameters: parameters)
                    _ = try TokenIterator(
                        input: LMInput(tokens: MLXArray(prefixTokens)),
                        model: model, cache: prefix, parameters: parameters)
                    eval(prefix)
                    newBox = PrefixCacheBox(caches: prefix, tokenCount: prefixTokens.count)
                    cache = prefix.map { $0.copy() }
                    eval(cache)
                    prefixTokenCount = prefixTokens.count
                    inputTokens = userTokens
                } else {
                    // Split isn't a true prefix of the full prompt for this model.
                    inputTokens = fullTokens
                    cache = model.newCache(parameters: parameters)
                    unsupported = true
                }
            } else {
                inputTokens = try template([systemMessage, userMessage], gen: true)
                cache = model.newCache(parameters: parameters)
            }

            let (output, info) = try await Self.generate(
                inputTokens: inputTokens, cache: cache,
                parameters: parameters, context: context)
            return CleanOutcome(
                text: output, info: info, prefixTokenCount: prefixTokenCount,
                newPrefixBox: newBox, prefixUnsupported: unsupported)
        }

        if let box = outcome.newPrefixBox {
            prefixBoxes[systemPrompt] = box
        }
        if outcome.prefixUnsupported {
            prefixUnsupported.insert(systemPrompt)
        }
        if let info = outcome.info {
            lastRunStats = RunStats(
                promptTokens: info.promptTokenCount,
                cachedPrefixTokens: outcome.prefixTokenCount,
                promptTime: info.promptTime,
                generateTime: info.generateTime,
                generatedTokens: info.generationTokenCount,
                stopReason: info.stopReason,
                totalTime: Date().timeIntervalSince(started))
        }
        return outcome.text
    }

    /// Runs generation to completion inside the container's serial access and
    /// returns the output text plus the completion info (prefill/decode split).
    private static func generate(
        inputTokens: [Int], cache: [any KVCache],
        parameters: GenerateParameters, context: ModelContext
    ) async throws -> (String, GenerateCompletionInfo?) {
        let stream = try MLXLMCommon.generate(
            input: LMInput(tokens: MLXArray(inputTokens)),
            cache: cache, parameters: parameters, context: context)
        var output = ""
        var info: GenerateCompletionInfo?
        for await item in stream {
            switch item {
            case .chunk(let chunk): output += chunk
            case .info(let i): info = i
            case .toolCall: break
            }
        }
        return (output, info)
    }

    private func tokenCount(of text: String) async -> Int {
        guard let container else { return CleanupGuard.wordCount(text) }
        return await container.encode(text).count
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let delay = idleUnloadAfter
        guard delay.isFinite, delay > 0 else { return }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
