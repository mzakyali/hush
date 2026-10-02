import Foundation

/// Locations under `~/Library/Application Support/Hush/` (spec §7). Tests inject a temp dir.
public struct AppPaths: Sendable {
    public var root: URL
    public var database: URL { root.appending(path: "hush.sqlite") }
    public var audio: URL { root.appending(path: "audio") }
    public var models: URL { root.appending(path: "models") }
    public var modelsWhisper: URL { models.appending(path: "whisper") }
    public var modelsLLM: URL { models.appending(path: "llm") }

    public init(root: URL = AppPaths.defaultRoot) {
        self.root = root
    }

    public static let defaultRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Hush")
    }()

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsWhisper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsLLM, withIntermediateDirectories: true)
    }
}
