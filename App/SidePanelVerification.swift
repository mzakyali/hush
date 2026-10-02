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

        // This was inside the invisible full-height window above the visible tab.
        let point = NSPoint(x: screen.visibleFrame.maxX - 100,
                            y: screen.visibleFrame.maxY - 10)
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

        let corner = NSPoint(x: panel.frame.minX + 1, y: panel.frame.maxY - 1)
        model.edgePanel.syncInteraction(at: corner)
        guard panel.ignoresMouseEvents,
              NSWindow.windowNumber(at: corner, belowWindowWithWindowNumber: 0)
                == NSWindow.windowNumber(at: corner, belowWindowWithWindowNumber: panel.windowNumber) else {
            print("FAIL: transparent curved corner intercepted mouseDown")
            return false
        }
        print("PASS: curved corner routes mouseDown to the window beneath")

        let body = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        model.edgePanel.syncInteraction(at: body)
        try? await Task.sleep(for: .milliseconds(30))
        guard !panel.ignoresMouseEvents,
              NSWindow.windowNumber(at: body, belowWindowWithWindowNumber: 0) == panel.windowNumber else {
            print("FAIL: visible panel cannot receive mouseDown (frame \(panel.frame), ignored \(panel.ignoresMouseEvents), actual \(NSWindow.windowNumber(at: body, belowWindowWithWindowNumber: 0)), panel \(panel.windowNumber))")
            return false
        }
        print("PASS: visible panel receives mouseDown")

        let before = panel.frame.origin
        model.edgePanel.drag(to: body)
        model.edgePanel.drag(to: NSPoint(x: body.x - 180, y: body.y - 80))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.maxX == screen.visibleFrame.maxX }
        guard panel.frame.maxX == screen.visibleFrame.maxX, panel.frame.minY == before.y - 80,
              model.geometry.edgeAttachment == .right else {
            print("FAIL: a released middle-screen drag did not snap to the nearest right edge (frame \(panel.frame), before \(before), side \(model.geometry.edgeAttachment))")
            return false
        }
        print("PASS: middle-screen release snaps to the nearest right edge")

        // Snap the card to the opposite edge and keep it inside the display.
        let movedBody = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        model.edgePanel.drag(to: movedBody)
        model.edgePanel.drag(to: NSPoint(x: screen.visibleFrame.midX - 180,
                                         y: movedBody.y))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.minX == screen.visibleFrame.minX }
        guard model.geometry.edgeAttachment == .left, panel.frame.minX == screen.visibleFrame.minX,
              screen.visibleFrame.contains(panel.frame) else {
            print("FAIL: a released middle-screen drag did not snap to the nearest left edge")
            return false
        }
        print("PASS: middle-screen release snaps to the nearest left edge")

        let leftBody = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        model.edgePanel.drag(to: leftBody)
        model.edgePanel.drag(to: NSPoint(x: screen.visibleFrame.maxX - 30, y: leftBody.y))
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.maxX == screen.visibleFrame.maxX }
        // Continue the synthetic pointer movement through the final snap tick.
        // Reaching the target frame precedes the animation task's completion.
        await waitUntil {
            model.edgePanel.syncInteraction(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
            return model.geometry.edgeExpanded && panel.frame.width == EdgePanelView.size(expanded: true).width
        }
        guard model.geometry.edgeExpanded, panel.frame.width == EdgePanelView.size(expanded: true).width else {
            print("FAIL: hovering did not reveal the detail panel")
            return false
        }
        let expandedFrame = panel.frame
        let expandedBody = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        model.edgePanel.drag(to: expandedBody)
        model.edgePanel.drag(to: NSPoint(x: expandedBody.x - 200, y: expandedBody.y))
        guard panel.frame.minX == expandedFrame.minX - 200 else {
            print("FAIL: dragging the expanded panel jumped horizontally")
            return false
        }
        model.edgePanel.endDrag()
        await waitUntil { panel.frame.maxX == screen.visibleFrame.maxX && panel.frame.width == EdgePanelView.size(expanded: false).width }
        print("PASS: hover reveals details; dragging the expanded panel keeps its position continuous")
        model.edgePanel.hide()
        let reduced = EdgePanelController(model: model, reducedMotion: { true })
        reduced.show()
        defer { reduced.hide() }
        guard let reducedPanel = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView is NSHostingView<EdgePanelView>
        }) else { return false }
        let reducedBody = NSPoint(x: reducedPanel.frame.midX, y: reducedPanel.frame.midY)
        reduced.drag(to: reducedBody)
        reduced.drag(to: NSPoint(x: screen.visibleFrame.midX - 180, y: reducedBody.y))
        reduced.endDrag()
        guard reducedPanel.frame.minX == screen.visibleFrame.minX else {
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
