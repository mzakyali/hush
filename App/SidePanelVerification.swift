import AppKit
import SwiftUI

/// Window-server regression probe; run with --render-snapshots <dir> --verify-side-panel.
@MainActor
enum SidePanelVerification {
    static func run(model: AppModel) async -> Bool {
        guard let screen = NSScreen.main else { return false }
        // A command-line launch does not activate its desktop Space.
        NSApp.activate(ignoringOtherApps: true)
        model.edgePanel.show()
        defer { model.edgePanel.hide() }
        try? await Task.sleep(for: .milliseconds(300))
        guard let panel = NSApp.windows.first(where: {
            $0.contentView is NSHostingView<EdgePanelView>
        }) else { return false }
        let visible = screen.visibleFrame
        let win = EdgePanelLayout.window
        let m = EdgePanelLayout.margin

        func screenPoint(in rect: CGRect) -> NSPoint {
            NSPoint(x: panel.frame.minX + rect.midX,
                    y: panel.frame.maxY - rect.midY)
        }
        func shapeRect(expanded: Bool) -> CGRect {
            EdgePanelLayout.shapeRect(
                expanded: expanded, sliver: model.sidePanelSliver,
                attachment: model.geometry.edgeAttachment,
                railCenterY: model.geometry.railCenterY ?? win.height / 2,
                in: panel.frame.size)
        }
        // ignoresMouseEvents reaches the WindowServer asynchronously — give
        // the routing a beat before querying windowNumber.
        func routesToBeneath(_ point: NSPoint) async -> Bool {
            model.edgePanel.syncInteraction(at: point)
            guard panel.ignoresMouseEvents else { return false }
            try? await Task.sleep(for: .milliseconds(50))
            return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                == NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: panel.windowNumber)
        }
        func routesToPanel(_ point: NSPoint) async -> Bool {
            model.edgePanel.syncInteraction(at: point)
            guard !panel.ignoresMouseEvents else { return false }
            try? await Task.sleep(for: .milliseconds(50))
            return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber
        }

        // The window is a fixed card-sized frame plus shadow margin — most of
        // it is transparent and must route events to the app beneath.
        guard panel.frame.size == win else {
            print("FAIL: side panel is not the fixed window size (frame \(panel.frame))")
            return false
        }
        print("PASS: panel window is fixed-size")

        // This was inside the invisible full-height window above the visible tab.
        let point = NSPoint(x: visible.maxX - 100, y: visible.maxY - 10)
        let underneath = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: panel.windowNumber)
        let actual = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard actual == underneath else {
            print("FAIL: invisible side-panel area intercepted mouseDown (window \(actual), expected \(underneath))")
            return false
        }
        print("PASS: invisible side-panel area routes mouseDown to the window beneath")
        guard !panel.isKeyWindow else {
            print("FAIL: side panel took keyboard focus")
            return false
        }
        print("PASS: side panel stays nonactivating")

        // Collapsed: the transparent margin beside the rail must click through.
        let marginPoint = NSPoint(x: panel.frame.minX + 2, y: panel.frame.midY)
        guard await routesToBeneath(marginPoint) else {
            print("FAIL: transparent margin intercepted mouseDown (collapsed)")
            return false
        }
        print("PASS: transparent margin routes mouseDown beneath (collapsed)")

        // Collapsed: a point inside the rail receives events.
        let railPt = screenPoint(in: shapeRect(expanded: false))
        guard await routesToPanel(railPt) else {
            let topmost = NSWindow.windowNumber(at: railPt, belowWindowWithWindowNumber: 0)
            let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])?
                .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 }
                .map { "win\($0[kCGWindowNumber as String] ?? "?") \($0[kCGWindowOwnerName as String] ?? "?") \($0[kCGWindowBounds as String] ?? [:])" }
                .joined(separator: " | ") ?? "?"
            print("FAIL: resting rail cannot receive mouseDown — point \(railPt), frame \(panel.frame), ignores \(panel.ignoresMouseEvents), topmost \(topmost), panel \(panel.windowNumber); onscreen: \(info)")
            return false
        }
        print("PASS: resting rail receives mouseDown")

        let before = panel.frame.origin
        model.edgePanel.drag(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        model.edgePanel.drag(to: NSPoint(x: panel.frame.midX - 180, y: panel.frame.midY - 80))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.maxX == visible.maxX + m }
        guard panel.frame.maxX == visible.maxX + m, panel.frame.minY == before.y - 80,
              model.geometry.edgeAttachment == .right else {
            print("FAIL: a released middle-screen drag did not snap to the nearest right edge (frame \(panel.frame), before \(before), side \(model.geometry.edgeAttachment))")
            return false
        }
        print("PASS: middle-screen release snaps to the nearest right edge")

        // Snap to the opposite edge; the card (not the shadow margin) stays
        // inside the display.
        model.edgePanel.drag(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        model.edgePanel.drag(to: NSPoint(x: visible.midX - 180, y: panel.frame.midY))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.minX == visible.minX - m }
        guard model.geometry.edgeAttachment == .left,
              panel.frame.minX == visible.minX - m,
              visible.contains(panel.frame.insetBy(dx: m, dy: m)) else {
            print("FAIL: a released middle-screen drag did not snap to the nearest left edge")
            return false
        }
        print("PASS: middle-screen release snaps to the nearest left edge")

        // Back to the right edge, then hover-expand into the card.
        model.edgePanel.drag(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        model.edgePanel.drag(to: NSPoint(x: visible.maxX - 30, y: panel.frame.midY))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.maxX == visible.maxX + m }
        // Keep the synthetic pointer inside the rail through the hover delay.
        let railPoint = screenPoint(in: shapeRect(expanded: false))
        await waitUntil {
            model.edgePanel.syncInteraction(at: railPoint)
            return model.geometry.edgeExpanded
        }
        guard model.geometry.edgeExpanded else {
            let local = NSPoint(x: railPoint.x - panel.frame.minX,
                                y: panel.frame.maxY - railPoint.y)
            let pathInside = EdgePanelLayout.path(
                expanded: false, sliver: model.sidePanelSliver,
                attachment: model.geometry.edgeAttachment,
                railCenterY: model.geometry.railCenterY ?? win.height / 2,
                in: panel.frame.size).contains(local)
            print("FAIL: hovering did not reveal the detail panel — railPt \(railPoint), frame \(panel.frame), local \(local), pathInside \(pathInside), ignores \(panel.ignoresMouseEvents), attach \(model.geometry.edgeAttachment)")
            return false
        }
        print("PASS: hover reveals the detail panel")

        // Expanded: a point inside the card (outside the rail's column) and
        // one in the margin both route correctly.
        let cardOnly = shapeRect(expanded: true)
        let cardPoint = NSPoint(x: panel.frame.minX + cardOnly.minX + 12,
                                y: panel.frame.maxY - cardOnly.midY)
        guard await routesToPanel(cardPoint) else {
            print("FAIL: expanded card area cannot receive mouseDown")
            return false
        }
        print("PASS: expanded card receives mouseDown")
        guard await routesToBeneath(marginPoint) else {
            print("FAIL: transparent margin intercepted mouseDown (expanded)")
            return false
        }
        print("PASS: transparent margin routes mouseDown beneath (expanded)")

        // Dragging the expanded panel keeps its position continuous.
        let expandedBody = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let expandedOrigin = panel.frame.origin
        model.edgePanel.drag(to: expandedBody)
        model.edgePanel.drag(to: NSPoint(x: expandedBody.x - 200, y: expandedBody.y))
        guard panel.frame.minX == expandedOrigin.x - 200 else {
            print("FAIL: dragging the expanded panel jumped horizontally")
            return false
        }
        model.edgePanel.endDrag()
        await waitUntil {
            panel.frame.maxX == visible.maxX + m && !model.geometry.edgeExpanded
        }
        print("PASS: dragging the expanded panel keeps its position continuous")

        model.edgePanel.hide()
        let reduced = EdgePanelController(model: model, reducedMotion: { true })
        reduced.show()
        defer { reduced.hide() }
        guard let reducedPanel = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView is NSHostingView<EdgePanelView>
        }) else { return false }
        let reducedBody = NSPoint(x: reducedPanel.frame.midX, y: reducedPanel.frame.midY)
        reduced.drag(to: reducedBody)
        reduced.drag(to: NSPoint(x: visible.midX - 180, y: reducedBody.y))
        reduced.endDrag()
        guard reducedPanel.frame.minX == visible.minX - m else {
            print("FAIL: Reduce Motion did not snap immediately to the nearest edge")
            return false
        }
        print("PASS: Reduce Motion snaps immediately without animated travel")
        return true
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
