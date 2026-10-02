import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import Cleanup
import HushCore

private let benchEnabled = ProcessInfo.processInfo.environment["HUSH_BENCH"] == "1"

/// Anchor so `Bundle(for:)` resolves to this test bundle.
private final class BenchBundleAnchor {}

/// See CleanupIntegrationTests — under `swift test` the runner's main bundle is the
/// toolchain helper, so mlx-c can't find its metallib unless it's colocated.
private func colocateMLXMetallib() throws {
    let bundle = Bundle(for: BenchBundleAnchor.self)
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

/// Process physical footprint (peak-ish current RSS) via task_info.
private func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), iptr, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

private struct BenchModel {
    let id: String
    let factoryPath: String
    let factory: (any ModelFactory)?
    let additionalContext: [String: any Sendable]?
}

private struct BenchRow {
    var model: String
    var pass: String
    var inputIndex: Int
    var latency: TimeInterval
    var promptTokens: Int
    var cachedPrefixTokens: Int
    var prefillTime: TimeInterval
    var decodeTime: TimeInterval
    var generatedTokens: Int
    var rawOutput: String
    var finalOutput: String
    var fellBack: Bool
    var coverage: Double?
}

private let benchModels: [BenchModel] = [
    BenchModel(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
               factoryPath: "MLXLLM (LLMModelFactory)",
               factory: LLMModelFactory.shared,
               additionalContext: nil),
    BenchModel(id: "mlx-community/Qwen3-1.7B-4bit",
               factoryPath: "MLXLLM (LLMModelFactory), enable_thinking=false",
               factory: LLMModelFactory.shared,
               additionalContext: ["enable_thinking": false]),
]

private let benchInputs: [(raw: String, style: CleanupStyle)] = [
    ("eh jadi um besok kita deploy ke production ya, uh, after lunch", .casual),
    ("um so I think we should, uh, move the meeting to Thursday, no, Friday at 3", .default),
    ("jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya", .casual),
    ("okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen", .default),
    ("can you send me the report by tomorrow", .formal),
    ("eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng", .casual),
]

@Test(.enabled(if: benchEnabled))
func cleanupBench() async throws {
    try colocateMLXMetallib()
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CleanupTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HushKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
    let spikeDir = repoRoot.appending(path: "spike")
    try FileManager.default.createDirectory(at: spikeDir, withIntermediateDirectories: true)
    let outURL = spikeDir.appending(path: "cleanup-bench-results.md")

    var markdown = "# Cleanup model bench (HUSH_BENCH=1) — round 2\n\n"
    markdown += "Machine: Apple M1, 16 GB. Prompt = plan prompt with new self-correction rule "
    markdown += "+ keep-content rule. Guard = CleanupGuard ratio + coverage (>0.75 strict, "
    markdown += "filler + droppable + corrected-away tokens excluded). Temperature 0.\n\n"
    markdown += "\"cached\" = system-prompt prefix KV-cache reuse (prefill only user-turn "
    markdown += "tokens); \"plain\" = full re-prefill each call (ChatSession behaviour).\n\n"
    markdown += "| # | model | pass | latency s | prefill s | decode s | prompt tok | cached tok | fellBack | coverage | final output |\n"
    markdown += "|---|---|---|---|---|---|---|---|---|---|---|\n"
    var verbatim = ""

    for model in benchModels {
        print("[bench] loading \(model.id) via \(model.factoryPath)")
        let cleaner = MLXCleaner(modelID: model.id, idleUnloadAfter: .infinity,
                                 modelFactory: model.factory,
                                 additionalContext: model.additionalContext)
        let loadStart = Date()
        do {
            try await cleaner.prepare()
        } catch {
            print("[bench] FAILED to load \(model.id): \(error.localizedDescription)")
            markdown += "\n**\(model.id) FAILED to load:** \(error.localizedDescription)\n"
            continue
        }
        let loadTime = Date().timeIntervalSince(loadStart)
        print("[bench] \(model.id) ready in \(String(format: "%.1f", loadTime))s")

        _ = try? await cleaner.clean("hello there", style: .default, terms: [])  // warm-up

        // Two passes per model: without prefix cache (plain), then with it (cached).
        for pass in [("plain", false), ("cached", true)] {
            await cleaner.setUsePrefixCache(pass.1)
            var rows: [BenchRow] = []
            for (i, input) in benchInputs.enumerated() {
                let start = Date()
                let rawOutput = (try? await cleaner.clean(input.raw, style: input.style, terms: []))
                    ?? "<error>"
                let latency = Date().timeIntervalSince(start)
                let stats = await cleaner.lastRunStats
                let normalized = CleanupGuard.normalize(rawOutput, raw: input.raw)
                let fellBack = normalized == nil
                let final = normalized ?? input.raw
                let coverage = CleanupGuard.contentCoverage(raw: input.raw, output: rawOutput)
                rows.append(BenchRow(
                    model: model.id, pass: pass.0, inputIndex: i + 1, latency: latency,
                    promptTokens: stats?.promptTokens ?? 0,
                    cachedPrefixTokens: stats?.cachedPrefixTokens ?? 0,
                    prefillTime: stats?.promptTime ?? 0,
                    decodeTime: stats?.generateTime ?? 0,
                    generatedTokens: stats?.generatedTokens ?? 0,
                    rawOutput: rawOutput, finalOutput: final,
                    fellBack: fellBack, coverage: coverage))
                print("[bench] \(model.id) [\(pass.0)] input \(i + 1): "
                      + String(format: "%.2f", latency) + "s "
                      + "prefill=\(String(format: "%.2f", stats?.promptTime ?? 0))s "
                      + "decode=\(String(format: "%.2f", stats?.generateTime ?? 0))s "
                      + "ptok=\(stats?.promptTokens ?? 0) cached=\(stats?.cachedPrefixTokens ?? 0) "
                      + "fellBack=\(fellBack) cov=\(coverage.map { String(format: "%.2f", $0) } ?? "n/a")")
                print("[bench]   raw: \(rawOutput)")
                print("[bench]   final: \(final)")
            }

            markdown += "\n### \(model.id) — \(model.factoryPath) — pass: \(pass.0)\n\n"
            if pass.0 == "plain" {
                markdown += "load: \(String(format: "%.1f", loadTime))s\n\n"
            }
            for row in rows {
                let cov = row.coverage.map { String(format: "%.2f", $0) } ?? "n/a"
                markdown += "| \(row.inputIndex) | \(row.model) | \(row.pass) | "
                    + String(format: "%.2f", row.latency) + " | "
                    + String(format: "%.2f", row.prefillTime) + " | "
                    + String(format: "%.2f", row.decodeTime) + " | "
                    + "\(row.promptTokens) | \(row.cachedPrefixTokens) | "
                    + "\(row.fellBack) | \(cov) | "
                    + row.finalOutput.replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                    + " |\n"
            }
            verbatim += "\n## Raw outputs — \(model.id) [\(pass.0)]\n\n"
            for row in rows {
                verbatim += "### input \(row.inputIndex): \(benchInputs[row.inputIndex - 1].raw)\n\n"
                verbatim += "```\n\(row.rawOutput)\n```\n\n"
                verbatim += "final: `\(row.finalOutput)` (fellBack=\(row.fellBack))\n\n"
            }
        }

        let rss = physFootprint()
        let gb = Double(rss) / 1_073_741_824
        print("[bench] \(model.id) phys_footprint \(String(format: "%.2f", gb)) GB")
        markdown += "\nphys_footprint after \(model.id): \(String(format: "%.2f", gb)) GB\n"

        await cleaner.unload()
        Memory.clearCache()
        print("[bench] unloaded \(model.id)")
    }

    markdown += verbatim
    try markdown.write(to: outURL, atomically: true, encoding: .utf8)
    print("[bench] wrote \(outURL.path)")
}
