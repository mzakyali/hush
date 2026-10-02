import Foundation
import Testing
@testable import Store

private func makeStore() throws -> DictationStore {
    try DictationStore(inMemoryAt: FileManager.default.temporaryDirectory
        .appending(path: "hush-test-\(UUID().uuidString)"))
}

// MARK: - entries (§5)

@Test func addTermIsIdempotent() async throws {
    let store = try makeStore()
    let a = try await store.addTerm("Supabase")
    let b = try await store.addTerm("Supabase")   // same term → same row
    #expect(a.id == b.id)
    let terms = try await store.dictionaryEntries(kind: "term")
    #expect(terms.count == 1)
    #expect(terms[0].toText == "Supabase")
    #expect(terms[0].kind == "term")
    #expect(terms[0].source == "manual")
}

@Test func addReplacementUpdatesSameFrom() async throws {
    let store = try makeStore()
    let a = try await store.addReplacement(from: "teh", to: "the")
    let b = try await store.addReplacement(from: "teh", to: "thee",
                                           source: "learned")
    #expect(a.id == b.id)
    let rules = try await store.dictionaryEntries(kind: "replacement")
    #expect(rules.count == 1)
    #expect(rules[0].toText == "thee")
    #expect(rules[0].source == "learned")
}

@Test func deleteEntryRemoves() async throws {
    let store = try makeStore()
    let t = try await store.addTerm("tokopedia", source: "history")
    try await store.deleteEntry(id: t.id)
    #expect(try await store.dictionaryEntries().isEmpty)
}

@Test func hitCountsBump() async throws {
    let store = try makeStore()
    let r = try await store.addReplacement(from: "a", to: "b")
    try await store.bumpHitCounts([r.id: 3])
    try await store.bumpHitCounts([r.id: 2])
    let rows = try await store.dictionaryEntries(kind: "replacement")
    #expect(rows[0].hitCount == 5)
}

// MARK: - suggestions (§6)

@Test func firstSightingIsPending() async throws {
    let store = try makeStore()
    let outcome = try await store.recordSuggestion(from: "supabase", to: "Supabase")
    #expect(outcome == .pending)
    let pending = try await store.suggestions()
    #expect(pending.count == 1)
    #expect(pending[0].seenCount == 1)
    #expect(pending[0].status == "pending")
    // Nothing was added to the dictionary.
    #expect(try await store.dictionaryEntries().isEmpty)
}

@Test func secondSightingAutoAccepts() async throws {
    let store = try makeStore()
    _ = try await store.recordSuggestion(from: "supabase", to: "Supabase")
    let outcome = try await store.recordSuggestion(from: "supabase", to: "Supabase")
    #expect(outcome == .autoAccepted)
    #expect(try await store.suggestions().isEmpty)   // no longer pending
    let entries = try await store.dictionaryEntries()
    // The learned replacement AND the term both land.
    #expect(entries.contains { $0.kind == "replacement" && $0.fromText == "supabase"
        && $0.toText == "Supabase" && $0.source == "learned" })
    #expect(entries.contains { $0.kind == "term" && $0.toText == "Supabase"
        && $0.source == "learned" })
}

@Test func rejectedNeverResurfaces() async throws {
    let store = try makeStore()
    _ = try await store.recordSuggestion(from: "gak", to: "nggak")
    let pending = try await store.suggestions()
    try await store.rejectSuggestion(id: pending[0].id)
    // Seeing the same edit again (and again) stays ignored.
    #expect(try await store.recordSuggestion(from: "gak", to: "nggak") == .ignored)
    #expect(try await store.recordSuggestion(from: "gak", to: "nggak") == .ignored)
    #expect(try await store.suggestions().isEmpty)
    #expect(try await store.dictionaryEntries().isEmpty)
}

@Test func approveManuallyAddsLearnedEntries() async throws {
    let store = try makeStore()
    _ = try await store.recordSuggestion(from: "xcode", to: "Xcode")
    let pending = try await store.suggestions()
    try await store.approveSuggestion(id: pending[0].id)
    #expect(try await store.suggestions().isEmpty)
    let entries = try await store.dictionaryEntries()
    #expect(entries.contains { $0.kind == "replacement" && $0.source == "learned" })
    #expect(entries.contains { $0.kind == "term" && $0.toText == "Xcode" })
    // Approving again is a no-op (already accepted).
    try await store.approveSuggestion(id: pending[0].id)
    #expect(try await store.dictionaryEntries().count == 2)
}

@Test func differentPairsAreIndependent() async throws {
    let store = try makeStore()
    _ = try await store.recordSuggestion(from: "a", to: "A")
    _ = try await store.recordSuggestion(from: "b", to: "B")
    #expect(try await store.suggestions().count == 2)
}
