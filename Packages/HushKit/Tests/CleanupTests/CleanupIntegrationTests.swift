import Foundation
import Testing
@testable import Cleanup
import HushCore

private let integrationEnabled = ProcessInfo.processInfo.environment["HUSH_INTEGRATION"] == "1"

/// Anchor so `Bundle(for:)` resolves to this test bundle.
private final class BundleAnchor {}

/// Under `swift test` the runner's main bundle is the toolchain helper, so mlx-c's
/// SwiftPM bundle scan never finds `mlx-swift_Cmlx.bundle`. mlx-c also looks for
/// `<test binary dir>/Resources/default.metallib` — symlink it there.
private func colocateMLXMetallib() throws {
    let bundle = Bundle(for: BundleAnchor.self)
    guard let execDir = bundle.executableURL?.deletingLastPathComponent(),
          let resources = bundle.resourceURL else { return }
    let metallib = resources
        .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard FileManager.default.fileExists(atPath: metallib.path) else { return }
    let resDir = execDir.appending(path: "Resources")
    try FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)
    let link = resDir.appending(path: "default.metallib")
    try? FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: metallib)
}

// Both tests use the same GPU. Run sequentially so competing model loads do
// not trip the production 8-second cleanup deadline.
@Suite(.serialized)
struct LocalCleanupIntegrationTests {
    @Test(.enabled(if: integrationEnabled))
    func gemmaCleanupIntegration() async throws {
        try colocateMLXMetallib()
        let cleaner = MLXCleaner(onProgress: { progress in
            if progress == 0 || progress == 1 {
                print("[integration] llm download: \(Int(progress * 100))%")
            }
        })
        let loadStart = Date()
        try await cleaner.prepare()
        print("[integration] llm ready in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")

        let guarded = GuardedCleaner(cleaner)
        let raw = "eh jadi um besok kita deploy ke production ya, uh, after lunch"
        let start = Date()
        let output = try await guarded.clean(raw, style: .casual, terms: [])
        let latency = Date().timeIntervalSince(start)
        print("[integration] cleanup (\(String(format: "%.2f", latency))s) fellBack=\(await guarded.lastCleanupFellBack): \(output)")

        let lowered = output.lowercased()
        #expect(lowered.contains("deploy"))
        #expect(lowered.contains("production"))
        // "after lunch" is content — either the model kept it or the guard fell back to raw.
        #expect(lowered.contains("lunch"))
        // Fillers removed — check words, not substrings ("deploy" must not count "um" in "summary").
        let words = lowered
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        #expect(!words.contains("um"))
        #expect(!words.contains("uh"))
        // Language preserved — not translated.
        #expect(lowered.contains("besok"))
    }

    /// Replays the user's hesitation through the cached, local cleanup model.
    /// Requires an explicit integration opt-in and refuses to download missing weights.
    @Test(.enabled(if: integrationEnabled))
    func cleanupRemovesAbandonedStartsIntegration() async throws {
        try colocateMLXMetallib()
        let cleaner = MLXCleaner()
        guard await cleaner.hasLocalModel else { throw MLXCleaner.Error.notPrepared }
        try await cleaner.prepare()
        let raw = "Can you find out why sometimes the... sorry... the... clean up version it's capitalized some words that doesn't have to be capitalized. Do you know why?"
        let guarded = GuardedCleaner(cleaner)
        let result = try await guarded.clean(raw, style: .default, terms: [])
        print("[cleanup-regression] output: \(result)")
        #expect(!result.lowercased().contains("sorry"))
        #expect(!result.contains("..."))
        #expect(result.lowercased().contains("capitalized"))
        #expect(result.contains("Do you know why?"))
        #expect(await guarded.lastCleanupFellBack == false)

        let second = "Also yeah, like this, the... sorry, the... it doesn't have to be like that I think, it should be cleaned up."
        let secondResult = try await guarded.clean(second, style: .default, terms: [])
        print("[cleanup-regression] second output: \(secondResult)")
        #expect(!secondResult.lowercased().contains("sorry"))
        #expect(!secondResult.contains("..."))
        #expect(secondResult.lowercased().contains("cleaned up"))
        #expect(secondResult.lowercased().contains("doesn't have to be like that"))
        #expect(secondResult.contains("I think"))
        #expect(await guarded.lastCleanupFellBack == false)

        let apology = "Um, I'm sorry I missed the meeting. Please send me the report after lunch."
        let apologyResult = try await guarded.clean(apology, style: .default, terms: [])
        #expect(apologyResult.contains("I'm sorry I missed the meeting."))
        #expect(apologyResult.lowercased().contains("after lunch"))
        #expect(!apologyResult.lowercased().hasPrefix("um"))
        #expect(await guarded.lastCleanupFellBack == false)

        let names = "Um, please check the side panel in Hush and push camelCase to GitHub after CI passes."
        let namesResult = try await guarded.clean(names, style: .default, terms: ["Hush", "camelCase", "GitHub", "CI"])
        #expect(namesResult.contains("side panel"))
        #expect(namesResult.contains("camelCase"))
        #expect(namesResult.contains("GitHub"))
        #expect(namesResult.contains("CI"))
        #expect(await guarded.lastCleanupFellBack == false)
    }

}
