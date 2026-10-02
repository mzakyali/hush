import AppKit
import Foundation

/// Sendable reference to an NSPasteboard. Pasteboard reads/writes are
/// system-serialized, so crossing actor boundaries with the reference is safe;
/// the individual calls remain nonisolated and callable from any context.
public struct PasteboardRef: @unchecked Sendable {
    public let pasteboard: NSPasteboard
    public init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    public static let general = PasteboardRef(.general)
}

/// Full snapshot of a pasteboard's items so the user's clipboard can be restored
/// after Hush writes the text it pastes.
public struct PasteboardSnapshot: Sendable {
    public struct Item: Sendable {
        public var types: [String]
        public var data: [String: Data]
    }

    public var items: [Item]
    public var changeCount: Int

    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [Item] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var data: [String: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) {
                    data[type.rawValue] = d
                }
            }
            items.append(Item(types: item.types.map(\.rawValue), data: data))
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    /// Restore the snapshot. Callers should check `changeCount` hasn't moved since the
    /// paste write (i.e. the user didn't copy something else in between).
    public func restore(to pasteboard: NSPasteboard) {
        guard pasteboard.changeCount == changeCount + 1 || pasteboard.changeCount == changeCount else {
            return  // the user copied something else — don't clobber it
        }
        pasteboard.clearContents()
        let items = self.items.map { item -> NSPasteboardItem in
            let pbItem = NSPasteboardItem()
            for (type, data) in item.data {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return pbItem
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
