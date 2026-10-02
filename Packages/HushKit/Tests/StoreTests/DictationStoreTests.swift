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

// MARK: - daily aggregates (§3.15 / T14)

@Test func saveIncrementsDailyStats() async throws {
    let store = try makeStore()
    let (i1, at1) = input(cleaned: "one two three", duration: 4)
    let (i2, at2) = input(cleaned: "four five", duration: 6)
    _ = try await store.save(i1, at: at1)
    _ = try await store.save(i2, at: at2)
    let (old, oldAt) = input(cleaned: "yesterday entry", daysAgo: 1, duration: 2)
    _ = try await store.save(old, at: oldAt)

    let stats = try await store.stats()
    #expect(stats.todayWords == 5)
    #expect(stats.todaySessions == 2)
    #expect(stats.totalWords == 7)
    #expect(stats.totalSessions == 3)
    #expect(abs(stats.speakingSeconds - 12) < 0.001)

    let todayKey = DictationStore.dayKey(Date())
    let yesterdayKey = DictationStore.dayKey(Date().addingTimeInterval(-86400))
    let perDay = try await store.wordsPerDay(last: 7)
    #expect(perDay[todayKey] == 5)
    #expect(perDay[yesterdayKey] == 2)
}

/// §3.15: wiping `stats_daily` then running the v2 backfill must reproduce
/// exactly what `stats()`/`wordsPerDay()` reported before — the migration
/// can never change a user's numbers.
@Test func backfillRestoresAggregates() async throws {
    let store = try makeStore()
    let (i1, at1) = input(cleaned: "alpha beta gamma", duration: 3)
    _ = try await store.save(i1, at: at1)
    let (i2, at2) = input(cleaned: "delta epsilon", daysAgo: 1, duration: 5)
    _ = try await store.save(i2, at: at2)
    let (i3, at3) = input(cleaned: "zeta", daysAgo: 1, duration: 2)
    _ = try await store.save(i3, at: at3)
    let before = try await store.stats()
    let beforePerDay = try await store.wordsPerDay(last: 30)

    try await store.resetStatistics()
    #expect(try await store.stats().totalSessions == 0)

    try await store.backfillDailyStats()
    #expect(try await store.stats() == before)
    #expect(try await store.wordsPerDay(last: 30) == beforePerDay)
}

@Test func resetStatisticsClearsAggregatesOnly() async throws {
    let store = try makeStore()
    let (i, at) = input(cleaned: "kept in history", audio: true)
    let saved = try await store.save(i, at: at)
    try await store.resetStatistics()

    let stats = try await store.stats()
    #expect(stats.totalWords == 0)
    #expect(stats.totalSessions == 0)
    #expect(stats.speakingSeconds == 0)
    #expect(try await store.wordsPerDay(last: 30).isEmpty)
    // History (and its audio) survives a stats reset.
    #expect(try await store.search("").map(\.id) == [saved.id])
}

@Test func deleteAndDeleteAllKeepAggregates() async throws {
    let store = try makeStore()
    let (i1, at1) = input(cleaned: "stays", daysAgo: 1)
    let first = try await store.save(i1, at: at1)
    let (i2, at2) = input(cleaned: "goes today")
    _ = try await store.save(i2, at: at2)

    try await store.delete(id: first.id)
    var stats = try await store.stats()
    #expect(stats.totalSessions == 2)   // single delete keeps aggregates

    _ = try await store.deleteAll()
    #expect(try await store.search("").isEmpty)
    stats = try await store.stats()
    #expect(stats.totalSessions == 2)   // delete-all keeps aggregates
    #expect(stats.totalWords == 3)
}

// MARK: - app styles (§3.7 / T10)

@Test func appStyleOverrideCRUD() async throws {
    let store = try makeStore()
    #expect(try await store.styleOverrides().isEmpty)

    try await store.setStyleOverride(bundleID: "com.apple.mail",
                                     appName: "Mail", style: "formal")
    try await store.setStyleOverride(bundleID: "com.hnc.Discord", style: "minimal")
    var overrides = try await store.styleOverrides()
    #expect(overrides.count == 2)
    #expect(overrides[0].bundleID == "com.apple.mail")
    #expect(overrides[0].appName == "Mail")
    #expect(overrides[0].style == "formal")

    // Re-set updates style, keeps the stored name when none is given.
    try await store.setStyleOverride(bundleID: "com.apple.mail", style: "default")
    overrides = try await store.styleOverrides()
    #expect(overrides[0].style == "default")
    #expect(overrides[0].appName == "Mail")

    try await store.removeStyleOverride(bundleID: "com.apple.mail")
    overrides = try await store.styleOverrides()
    #expect(overrides.map(\.bundleID) == ["com.hnc.Discord"])
}

@Test func dictationAppsReturnsHistoryApps() async throws {
    let store = try makeStore()
    let (i, at) = input(cleaned: "hi")
    _ = try await store.save(i, at: at)
    let apps = try await store.dictationApps()
    #expect(apps.map(\.bundleID) == ["com.test.App"])
    #expect(apps[0].appName == "TestApp")
}
