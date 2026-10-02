import Foundation
import HushCore
import Testing
@testable import Store

private func makeStore() throws -> DictationStore {
    try DictationStore(inMemoryAt: FileManager.default.temporaryDirectory
        .appending(path: "hush-test-\(UUID().uuidString)"))
}

private func input(cleaned: String, raw: String = "raw", daysAgo: Double = 0,
                   duration: Double = 5, audio: Bool = false) -> (DictationInput, Date) {
    let at = Date().addingTimeInterval(-daysAgo * 86400)
    let buffer = audio ? AudioBuffer16k(samples: [Float](repeating: 0.01, count: 16000)) : nil
    return (DictationInput(rawText: raw, cleanedText: cleaned, style: "default",
                           cleanupFallback: false, durationSec: duration,
                           appBundleID: "com.test.App", appName: "TestApp",
                           audio: buffer), at)
}

@Test func migrationCreatesTables() async throws {
    let store = try makeStore()
    // If any table were missing these reads would throw.
    _ = try await store.recent()
    _ = try await store.stats()
}

@Test func saveAndQuery() async throws {
    let store = try makeStore()
    let (i1, at1) = input(cleaned: "hello world", audio: true)
    let saved = try await store.save(i1, at: at1)
    #expect(saved.wordCount == 2)
    #expect(saved.audioPath == "\(saved.id).m4a")
    let audioURL = await store.audioDirectory.appending(path: saved.audioPath!)
    #expect(FileManager.default.fileExists(atPath: audioURL.path))

    let all = try await store.search("")
    #expect(all.count == 1)
    #expect(all[0].cleanedText == "hello world")
    #expect(all[0].appBundleID == "com.test.App")
}

@Test func searchIsCaseInsensitiveSubstringOverBothTexts() async throws {
    let store = try makeStore()
    let (i1, at1) = input(cleaned: "Deploy ke production", raw: "eh deploy ke production")
    _ = try await store.save(i1, at: at1)
    let (i2, at2) = input(cleaned: "Send the report", raw: "send report")
    _ = try await store.save(i2, at: at2)

    #expect(try await store.search("PRODUCTION").count == 1)   // matches cleaned
    #expect(try await store.search("deploy").count == 1)
    #expect(try await store.search("send").count == 1)         // matches raw too
    #expect(try await store.search("nothing").isEmpty)
    #expect(try await store.search("").count == 2)             // empty = all
}

@Test func retentionDeletesOldRowsAndFilesOnly() async throws {
    let store = try makeStore()
    let (old, oldAt) = input(cleaned: "old note", daysAgo: 40, audio: true)
    let savedOld = try await store.save(old, at: oldAt)
    let (fresh, freshAt) = input(cleaned: "fresh note", daysAgo: 5, audio: true)
    let savedFresh = try await store.save(fresh, at: freshAt)

    let deleted = try await store.enforceRetention(days: 30)
    #expect(deleted == 1)
    #expect(try await store.search("").map(\.id) == [savedFresh.id])

    let dir = await store.audioDirectory
    #expect(!FileManager.default.fileExists(
        atPath: dir.appending(path: savedOld.audioPath!).path))
    #expect(FileManager.default.fileExists(
        atPath: dir.appending(path: savedFresh.audioPath!).path))
}

@Test func statsAggregateAndDerive() async throws {
    let store = try makeStore()
    // 60 words in 60 s → spoken WPM 60; typing at 40 wpm would take 90 s → saved 30 s.
    let (i1, at1) = input(cleaned: String(repeating: "word ", count: 60), duration: 60)
    _ = try await store.save(i1, at: at1)
    let stats = try await store.stats(typingWPM: 40)
    #expect(stats.totalWords == 60)
    #expect(stats.totalSessions == 1)
    #expect(stats.todayWords == 60)
    #expect(stats.speakingSeconds == 60)
    #expect(abs(stats.spokenWPM - 60) < 0.001)
    #expect(abs(stats.timeSavedSeconds - 30) < 0.001)
}

@Test func retentionDoesNotTouchStatsAggregates() async throws {
    let store = try makeStore()
    let (old, oldAt) = input(cleaned: "twenty words " + String(repeating: "w ", count: 20), daysAgo: 40)
    _ = try await store.save(old, at: oldAt)
    _ = try await store.enforceRetention(days: 30)
    #expect(try await store.search("").isEmpty)
    let stats = try await store.stats()
    #expect(stats.totalWords > 0)   // aggregate survives
    #expect(stats.totalSessions == 1)
}

@Test func deleteRemovesRowAndFile() async throws {
    let store = try makeStore()
    let (i, at) = input(cleaned: "gone", audio: true)
    let saved = try await store.save(i, at: at)
    try await store.delete(id: saved.id)
    #expect(try await store.search("").isEmpty)
    let dir = await store.audioDirectory
    #expect(!FileManager.default.fileExists(
        atPath: dir.appending(path: saved.audioPath!).path))
}
