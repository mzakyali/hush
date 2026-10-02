import Foundation
import Testing
@testable import AudioCapture

// MARK: - MicSelector.resolve (spec §4a)

private struct ResolveCase {
    var known: [String]
    var connected: Set<String>
    var pinned: String?
    var expected: String?
}

@Test(arguments: [
    // Pin wins while the device is connected.
    ResolveCase(known: ["a", "b"], connected: ["a", "b"], pinned: "b", expected: "b"),
    // A disconnected pin is ignored → first connected in known order.
    ResolveCase(known: ["a", "b"], connected: ["a"], pinned: "b", expected: "a"),
    // Auto mode: highest-priority connected device.
    ResolveCase(known: ["a", "b", "c"], connected: ["b", "c"], pinned: nil, expected: "b"),
    // Everything disconnected → nil (system default).
    ResolveCase(known: ["a", "b"], connected: [], pinned: nil, expected: nil),
    // Pinned but nothing at all connected → nil.
    ResolveCase(known: ["a", "b"], connected: [], pinned: "a", expected: nil),
    // A device that is connected but never merged into `known` is not picked.
    ResolveCase(known: ["a"], connected: ["zzz"], pinned: nil, expected: nil),
    // Empty world → nil.
    ResolveCase(known: [], connected: [], pinned: nil, expected: nil),
])
private func micSelectorResolve(_ c: ResolveCase) {
    #expect(MicSelector.resolve(known: c.known, connected: c.connected,
                                pinned: c.pinned) == c.expected)
}

// MARK: - MicSelector.merge

private struct MergeCase {
    var known: [String]
    var seen: [String]
    var expected: [String]
}

@Test(arguments: [
    // Newly seen UIDs join at the bottom (spec §4a).
    MergeCase(known: ["a"], seen: ["a", "b", "c"], expected: ["a", "b", "c"]),
    // Existing order is kept; already-known UIDs are not duplicated.
    MergeCase(known: ["b", "a"], seen: ["a", "b"], expected: ["b", "a"]),
    // A mix: "a" stays first, "c" appends below the previously known "b".
    MergeCase(known: ["a", "b"], seen: ["c", "a"], expected: ["a", "b", "c"]),
    // First run: everything appends in seen order.
    MergeCase(known: [], seen: ["x", "y"], expected: ["x", "y"]),
    // No devices seen → list unchanged.
    MergeCase(known: ["a"], seen: [], expected: ["a"]),
])
private func micSelectorMerge(_ c: MergeCase) {
    #expect(MicSelector.merge(known: c.known, seen: c.seen) == c.expected)
}

// MARK: - MicStore

/// Fresh in-memory store — tests never touch real UserDefaults.
private func makeStore() -> MicStore { MicStore(defaults: nil) }

private func device(_ uid: String, connected: Bool = true) -> InputDevice {
    InputDevice(uid: uid, name: "Mic \(uid)", isConnected: connected)
}

@Test func micStoreRefreshAppendsAndMarksConnected() {
    let store = makeStore()
    store.refresh(connected: [device("a"), device("b")])
    #expect(store.devices().map(\.uid) == ["a", "b"])
    #expect(store.devices().map(\.isConnected) == [true, true])
    // Second refresh: "b" keeps its place, new "c" appends at the bottom, and
    // "a" stays known but disconnected.
    store.refresh(connected: [device("b"), device("c")])
    #expect(store.devices().map(\.uid) == ["a", "b", "c"])
    #expect(store.devices().map(\.isConnected) == [false, true, true])
}

@Test func micStorePinReleasedOnDisconnect() {
    let store = makeStore()
    store.refresh(connected: [device("a"), device("b")])
    store.pin("b")
    #expect(store.resolvedUID() == "b")
    // "b" disconnects → pin released, auto mode picks "a".
    store.refresh(connected: [device("a")])
    #expect(store.pinnedUID == nil)
    #expect(store.resolvedUID() == "a")
}

@Test func micStoreMoveReordersPriority() {
    let store = makeStore()
    store.refresh(connected: [device("a"), device("b"), device("c")])
    store.move(fromOffsets: IndexSet([2]), toOffset: 0)
    #expect(store.devices().map(\.uid) == ["c", "a", "b"])
    #expect(store.resolvedUID() == "c")
}

/// candidates() = resolved device, then remaining connected in priority order,
/// then nil (system default) — the pipeline walks this on start failure.
@Test func micStoreCandidatesOrder() {
    let store = makeStore()
    store.refresh(connected: [device("a"), device("b")])
    store.refresh(connected: [device("b"), device("c")])   // "a" disconnects
    #expect(store.candidates() == ["b", "c", nil])
    // Pinned device leads the list, then the rest in priority order.
    store.pin("c")
    #expect(store.candidates() == ["c", "b", nil])
}

@Test func micStorePersistsAcrossInstances() {
    let suite = "hush-test-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!

    let store = MicStore(defaults: defaults)
    store.refresh(connected: [device("a"), device("b")])
    store.pin("b")
    store.move(fromOffsets: IndexSet([1]), toOffset: 0)

    let reloaded = MicStore(defaults: defaults)
    // Order + names + pin survive the round-trip.
    #expect(reloaded.devices().map(\.uid) == ["b", "a"])
    #expect(reloaded.name(for: "b") == "Mic b")
    #expect(reloaded.pinnedUID == "b")
    // A fresh instance has no live connected set yet → resolved is nil until refresh.
    #expect(reloaded.resolvedUID() == nil)
}
