import ApplicationServices
import Foundation
import HushCore
import os

/// §6 learning loop (plan T9): after a `.pasted` insertion into an
/// AX-readable, non-secure element, watch that element's `AXValue` for up to
/// 60s. When the user edits the pasted text, `EditDiff` turns the change
/// into replacement candidates which the store records as suggestions
/// (second sighting → auto-learned). Never logs text content.
///
/// Injection seams keep tests AX-free: `readValue`, `readFocused`, `poll`,
/// `timeout` and `onCandidates` are all injectable.
public actor EditWatcher {
    public typealias Candidate = (from: String, to: String)
    public typealias ValueReader = @Sendable (AXUIElement) -> String?
    public typealias FocusReader = @Sendable (pid_t) -> AXUIElement?

    private static let log = Logger(subsystem: "com.local.hush", category: "edits")

    private let readValue: ValueReader
    private let readFocused: FocusReader
    /// Interval between value reads when no AXObserver fires.
    private let pollInterval: Duration
    /// Maximum watch duration.
    private let timeout: Duration
    /// Quiet period after the last observed change before the edit is final.
    private let settle: Duration
    /// Caller-supplied sink for observed `(from, to)` pairs — records them
    /// as suggestions (first sighting) or learned replacements (second).
    private var onCandidates: @Sendable ([Candidate]) -> Void = { _ in }

    public func setOnCandidates(_ handler: @escaping @Sendable ([Candidate]) -> Void) {
        onCandidates = handler
    }

    private var task: Task<Void, Never>?

    public init(
        readValue: @escaping ValueReader = EditWatcher.axValue,
        readFocused: @escaping FocusReader = EditWatcher.axFocusedElement,
        pollInterval: Duration = .seconds(1),
        timeout: Duration = .seconds(60),
        settle: Duration = .seconds(2)
    ) {
        self.readValue = readValue
        self.readFocused = readFocused
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.settle = settle
    }

    /// Begin watching. Any in-flight watch (a previous paste) is cancelled.
    /// `element` is the `InsertedElement` box (AXUIElement isn't Sendable);
    /// `endOffset` = UTF-16 caret offset right after the paste.
    public nonisolated func watch(element: InsertedElement, pid: pid_t,
                                  inserted: String, endOffset: Int) {
        Task { await self._watch(element: element, pid: pid,
                                 inserted: inserted, endOffset: endOffset) }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func _watch(element: InsertedElement, pid: pid_t,
                        inserted: String, endOffset: Int) {
        cancel()
        let onCandidates = self.onCandidates
        Self.log.info("watch started pid=\(pid, privacy: .public)")
        task = Task { [readValue, readFocused, pollInterval, timeout, settle, element] in
            let element = element.element
            let notify = try? await Self.attachObserver(element: element, pid: pid)
            var lastSeen = readValue(element)
            var lastChangeAt: Date? = nil
            let deadline = Date().addingTimeInterval(Self.seconds(timeout))
            let settleSeconds = Self.seconds(settle)

            while Date() < deadline, !Task.isCancelled {
                // Focus left the element → the edit is done.
                guard let focused = readFocused(pid), CFEqual(focused, element) else { break }
                if notify?.changed() == true || notify == nil {
                    let current = readValue(element)
                    if current != lastSeen {
                        lastSeen = current
                        lastChangeAt = Date()
                    }
                }
                // Value settled for `settle` after a change → diff now.
                if let changed = lastChangeAt,
                   Date().timeIntervalSince(changed) >= settleSeconds {
                    break
                }
                // With an observer: 200ms ticks check the flag + focus.
                // Without one: read the value every poll interval (1s).
                try? await Task.sleep(for: notify == nil ? pollInterval : .milliseconds(200))
            }
            notify?.detach()
            guard !Task.isCancelled else { return }
            Self.finish(element: element, inserted: inserted,
                        endOffset: endOffset, readValue: readValue,
                        onCandidates: onCandidates)
        }
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Read the final value, locate the span, emit candidates. Fails silent.
    private static func finish(element: AXUIElement, inserted: String,
                               endOffset: Int, readValue: ValueReader,
                               onCandidates: @Sendable ([Candidate]) -> Void) {
        guard let final = readValue(element) else {
            log.info("watch ended — element unreadable")
            return
        }
        guard let span = InsertedSpan.locate(inserted: inserted,
                                             endOffset: endOffset, in: final) else {
            log.info("watch ended — inserted span not found")
            return
        }
        // The span covers the separator too — strip leading whitespace so the
        // diff compares text bodies, not context glue.
        let body = span.drop(while: { $0.isWhitespace })
        let insertedBody = inserted.trimmingCharacters(in: .whitespaces)
        let pairs = EditDiff.candidates(inserted: insertedBody, edited: String(body))
            .map { Candidate(from: $0.from, to: $0.to) }
        if pairs.isEmpty {
            log.info("watch ended — no learnable edit")
        } else {
            log.info("watch ended — \(pairs.count) candidate(s)")
        }
        onCandidates(pairs)
    }

    // MARK: - AX plumbing

    /// Shared flag set by the AXObserver callback (main-runloop source).
    final class Flag: @unchecked Sendable {
        let lock = NSLock()
        var value = false
        func changed() -> Bool { lock.withLock { let v = value; value = false; return v } }
        func fire() { lock.withLock { value = true } }
    }

    /// CFRunLoopSource isn't Sendable — it's a process-local CF reference,
    /// safe to move between threads for add/remove.
    private struct SendableSource: @unchecked Sendable {
        let source: CFRunLoopSource
    }

    struct ObserverHandle {
        let flag: Flag
        let detach: @Sendable () -> Void
        func changed() -> Bool { flag.changed() }
    }

    /// Observe `kAXValueChangedNotification` on the element. The observer
    /// runs on the main run loop (AX requires a run-loop source); the
    /// polling loop below still drives settle/focus/deadline checks.
    static func attachObserver(element: AXUIElement,
                               pid: pid_t) async throws -> ObserverHandle {
        let flag = Flag()
        var observer: AXObserver?
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            if let refcon { Unmanaged<Flag>.fromOpaque(refcon).takeUnretainedValue().fire() }
        }, &observer)
        guard err == .success, let observer else {
            throw NSError(domain: "hush.editwatcher", code: Int(err.rawValue))
        }
        let refcon = Unmanaged.passUnretained(flag).toOpaque()
        let addErr = AXObserverAddNotification(observer, element,
                                               kAXValueChangedNotification as CFString,
                                               refcon)
        guard addErr == .success else {
            throw NSError(domain: "hush.editwatcher", code: Int(addErr.rawValue))
        }
        let source = SendableSource(source: AXObserverGetRunLoopSource(observer))
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source.source, .defaultMode)
        return ObserverHandle(flag: flag) {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(),
                                  source.source, .defaultMode)
        }
    }

    // MARK: - default readers

    public static let axValue: ValueReader = { element in
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &value) == .success,
              let s = value as? String else { return nil }
        return s
    }

    public static let axFocusedElement: FocusReader = { pid in
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success else { return nil }
        return (focused as! AXUIElement)
    }
}
