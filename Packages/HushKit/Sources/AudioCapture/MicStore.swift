import Foundation

/// One input device Hush has seen (spec §4a). Identified by CoreAudio UID so the
/// priority order survives reconnects and reboots.
public struct MicEntry: Codable, Sendable, Equatable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Mic priority list + manual pin, persisted in UserDefaults (spec §4a).
/// Thread-safe: `candidates()` is called from the pipeline actor while the app
/// refreshes the device list on the main thread.
public final class MicStore: @unchecked Sendable {
    private static let entriesKey = "micPriority"
    private static let pinnedKey = "micPinnedUID"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    /// Ordered known devices — top is highest priority. Disconnected devices
    /// stay in the list so their place in the order survives.
    private var entries: [MicEntry] = []
    /// UID the user pinned via the Microphone submenu; nil = automatic.
    public private(set) var pinnedUID: String?
    /// UIDs connected as of the last `refresh` — the resolver's live set.
    private var connected: Set<String> = []

    /// `defaults: nil` runs in-memory only (snapshots/tests that must not write).
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let defaults,
           let data = defaults.data(forKey: Self.entriesKey),
           let saved = try? JSONDecoder().decode([MicEntry].self, from: data) {
            entries = saved
        }
        pinnedUID = defaults?.string(forKey: Self.pinnedKey)
    }

    /// Every known device in priority order with a live `isConnected` flag.
    public func devices() -> [InputDevice] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { InputDevice(uid: $0.uid, name: $0.name,
                                         isConnected: connected.contains($0.uid)) }
    }

    /// The currently connected UIDs in priority order.
    public func connectedUIDs() -> [String] {
        devices().filter(\.isConnected).map(\.uid)
    }

    /// Merge the live CoreAudio list into the priority list: existing order is
    /// kept, newly seen UIDs append at the bottom, names refresh, and a pin on a
    /// now-disconnected device is released (auto mode resumes).
    public func refresh(connected live: [InputDevice]) {
        lock.lock()
        let merged = MicSelector.merge(known: entries.map(\.uid),
                                       seen: live.map(\.uid))
        var names = Dictionary(entries.map { ($0.uid, $0.name) }) { _, new in new }
        for device in live { names[device.uid] = device.name }
        entries = merged.map { MicEntry(uid: $0, name: names[$0] ?? $0) }
        connected = Set(live.map(\.uid))
        if let pin = pinnedUID, !connected.contains(pin) {
            pinnedUID = nil
        }
        persistLocked()
        lock.unlock()
    }

    /// Pin a device (nil = Automatic). A pin on a disconnected device is kept —
    /// `refresh` releases it — so a briefly-removed device doesn't lose the pin
    /// if the list just hasn't updated yet.
    public func pin(_ uid: String?) {
        lock.lock()
        pinnedUID = uid
        persistLocked()
        lock.unlock()
    }

    /// Drag-to-reorder the priority list (SwiftUI `List`/`onMove` signature;
    /// `move(fromOffsets:toOffset:)` itself lives in SwiftUI, so this inlines
    /// the same semantics on Foundation's Array).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        lock.lock()
        let moving = source.sorted().map { entries[$0] }
        for index in source.sorted(by: >) { entries.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        entries.insert(contentsOf: moving, at: insertAt)
        persistLocked()
        lock.unlock()
    }

    /// The UID to record from, or nil for the system default (spec §4a).
    public func resolvedUID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return MicSelector.resolve(known: entries.map(\.uid), connected: connected,
                                   pinned: pinnedUID)
    }

    /// Ordered start candidates for `PipelineHooks.deviceUIDs`: the resolved
    /// device first, then every other connected device in priority order, then
    /// nil (system default) as the last resort.
    public func candidates() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        let resolved = MicSelector.resolve(known: entries.map(\.uid),
                                           connected: connected, pinned: pinnedUID)
        var list: [String?] = []
        if let resolved { list.append(resolved) }
        for entry in entries where connected.contains(entry.uid) && entry.uid != resolved {
            list.append(entry.uid)
        }
        list.append(nil)
        return list
    }

    /// Display name for a UID; nil is the system-default sentinel.
    public func name(for uid: String?) -> String? {
        guard let uid else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.uid == uid }?.name
    }

    private func persistLocked() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
        defaults.set(pinnedUID, forKey: Self.pinnedKey)
    }
}
