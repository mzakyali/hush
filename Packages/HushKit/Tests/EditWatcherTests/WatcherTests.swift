import ApplicationServices
import Foundation
import Testing
@testable import EditWatcher
import HushCore

/// Lock-guarded box for values mutated inside @Sendable closures.
private final class Mutexed<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

/// The watcher's own element — a real AXUIElement for our test process, so
/// `CFEqual` in the focus check works on a genuine object. Observer attach
/// fails (no trust/attributes), which is fine: the poll path is what the
/// injected readers drive.
private func fakeElement() -> AXUIElement {
    AXUIElementCreateApplication(getpid())
}

/// Poll for a condition instead of sleeping a fixed amount.
private func wait(_ predicate: @Sendable () -> Bool,
                  timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(15))
    }
    return false
}

@Test func editDuringWatchYieldsCandidate() async {
    // Value starts as the inserted text, then the user fixes casing.
    let reads = Mutexed(0)
    let watcher = EditWatcher(
        readValue: { _ in
            reads.withLock { $0 += 1; return $0 > 1 ? "use Supabase" : "use supabase" }
        },
        readFocused: { _ in fakeElement() },
        pollInterval: .milliseconds(30),
        timeout: .seconds(2),
        settle: .milliseconds(120))
    let got = Mutexed<[[EditWatcher.Candidate]]>([])
    await watcher.setOnCandidates { pairs in got.withLock { $0.append(pairs) } }

    watcher.watch(element: InsertedElement(fakeElement()), pid: getpid(),
                  inserted: "use supabase", endOffset: 12)
    let fired = await wait { !got.withLock({ $0 }).isEmpty }
    #expect(fired)
    let pairs = got.withLock { $0.first ?? [] }
    #expect(pairs.contains { $0.from == "supabase" && $0.to == "Supabase" })
}

@Test func cancelStopsWatchSilently() async {
    let watcher = EditWatcher(
        readValue: { _ in "abc" },
        readFocused: { _ in fakeElement() },
        pollInterval: .milliseconds(30),
        timeout: .seconds(5),
        settle: .milliseconds(50))
    let got = Mutexed(0)
    await watcher.setOnCandidates { _ in got.withLock { $0 += 1 } }

    watcher.watch(element: InsertedElement(fakeElement()), pid: getpid(),
                  inserted: "abc", endOffset: 3)
    try? await Task.sleep(for: .milliseconds(120))   // let the task start
    await watcher.cancel()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(got.withLock { $0 } == 0)
}

@Test func focusLeavingEndsTheWatch() async {
    // Second focus read returns a different element → watch finalizes.
    let watched = InsertedElement(fakeElement())
    let focusReads = Mutexed(0)
    let watcher = EditWatcher(
        readValue: { _ in "same text" },
        readFocused: { _ in
            // Focus loss after the first read — another app's element is
            // never CFEqual to ours.
            focusReads.withLock { $0 += 1; return $0 <= 1
                ? watched.element : AXUIElementCreateApplication(1) }
        },
        pollInterval: .milliseconds(30),
        timeout: .seconds(5),
        settle: .milliseconds(50))
    let got = Mutexed(0)
    await watcher.setOnCandidates { _ in got.withLock { $0 += 1 } }

    watcher.watch(element: watched, pid: getpid(),
                  inserted: "same text", endOffset: 9)
    // Watch ends on focus loss → finish() runs → handler fires (empty).
    let fired = await wait { got.withLock { $0 } > 0 }
    #expect(fired)
}

@Test func unreadableElementIsSilent() async {
    let watcher = EditWatcher(
        readValue: { _ in nil },
        readFocused: { _ in fakeElement() },
        pollInterval: .milliseconds(30),
        timeout: .milliseconds(300),
        settle: .milliseconds(50))
    let got = Mutexed(0)
    await watcher.setOnCandidates { _ in got.withLock { $0 += 1 } }

    watcher.watch(element: InsertedElement(fakeElement()), pid: getpid(),
                  inserted: "abc", endOffset: 3)
    try? await Task.sleep(for: .milliseconds(600))
    #expect(got.withLock { $0 } == 0)
}

@Test func newWatchCancelsTheOld() async {
    let element = InsertedElement(fakeElement())
    let which = Mutexed(1)
    let watcher = EditWatcher(
        readValue: { _ in which.withLock { $0 } == 1 ? "aaa" : "bbb" },
        readFocused: { _ in element.element },
        pollInterval: .milliseconds(30),
        // Value never changes, so only the deadline ends the surviving
        // watch — keep it short.
        timeout: .milliseconds(500),
        settle: .milliseconds(80))
    // The watch that survives ("bbb" → identical → empty candidate list)
    // still calls the handler once when it finalizes.
    let fired = Mutexed(0)
    await watcher.setOnCandidates { pairs in
        // A stale first watch would emit "aaa"-based candidates, not [].
        if pairs.isEmpty { fired.withLock { $0 += 1 } }
    }

    watcher.watch(element: element, pid: getpid(),
                  inserted: "aaa", endOffset: 3)
    try? await Task.sleep(for: .milliseconds(120))
    which.withLock { $0 = 2 }
    watcher.watch(element: element, pid: getpid(),
                  inserted: "bbb", endOffset: 3)
    let done = await wait { fired.withLock { $0 } > 0 }
    #expect(done)
}
