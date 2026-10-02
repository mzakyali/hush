import AppKit
import AudioCapture
import HushCore
import SwiftUI

/// A nonactivating window pinned to a screen edge. The window stays at
/// `EdgePanelLayout.window` size while visible — collapse/expand morphs the
/// SwiftUI silhouette inside it — so `setFrame` runs only on show, drag,
/// dock and screen changes, never on an animation frame.
@MainActor
final class EdgePanelController {
    private var panel: NSPanel?
    private let model: AppModel
    private let reducedMotion: @MainActor () -> Bool
    private let menuTarget = MenuTarget()
    /// Screen-space centre of the resting rail/sliver (y-up). Size-independent,
    /// so toggling the sliver doesn't shift the resting spot.
    private var restingCentre: NSPoint?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var morphTask: Task<Void, Never>?
    /// True while the rail↔card morph settles — the hit-test accepts the
    /// paths of both states so the transient silhouette never drops events.
    private var morphAnimating = false
    private var pointerInside = false
    private var dragStart: (mouse: NSPoint, frame: NSRect)?

    init(model: AppModel, reducedMotion: @escaping @MainActor () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.model = model
        self.reducedMotion = reducedMotion
        menuTarget.model = model
    }

    private var collapsedSize: CGSize {
        EdgePanelLayout.collapsedSize(sliver: model.sidePanelSliver)
    }

    func show() {
        let panel = ensurePanel()
        restorePosition()
        layout()
        panel.orderFrontRegardless()
        startMonitoring()
        syncInteraction()
    }

    func hide() {
        hoverTask?.cancel()
        morphTask?.cancel()
        morphAnimating = false
        hoverTask = nil
        dragStart = nil
        pointerInside = false
        model.geometry.edgeExpanded = false
        panel?.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func reposition() {
        guard let panel, panel.isVisible else { return }
        restorePosition()
        layout()
        syncInteraction()
    }

    /// The collapsed footprint changed (e.g. the sliver toggle) — recompute
    /// the window frame without touching the resting position.
    func relayout() {
        guard let panel, panel.isVisible else { return }
        layout()
        syncInteraction()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: EdgePanelLayout.window),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.title = "Hush side panel"
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = EdgeHostingView(rootView: EdgePanelView(model: model, geometry: model.geometry))
        hosting.sizingOptions = []
        hosting.onRightClick = { [weak self] event, view in
            self?.showContextMenu(with: event, in: view)
        }
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func restorePosition() {
        let size = collapsedSize
        if restingCentre == nil, !SnapshotRunner.requested,
           let saved = UserDefaults.standard.array(forKey: "sidePanelOrigin") as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            // Persisted as the collapsed rect's origin → recover the centre.
            restingCentre = NSPoint(x: saved[0] + size.width / 2,
                                    y: saved[1] + size.height / 2)
        }
        guard let screen = screen(for: restingCentre) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if restingCentre == nil {
            let fraction = SnapshotRunner.requested ? 0.5
                : UserDefaults.standard.object(forKey: "edgeTabFraction") as? Double ?? 0.5
            restingCentre = NSPoint(x: visible.maxX - size.width / 2,
                                    y: visible.minY + visible.height * fraction)
        }
        guard var centre = restingCentre else { return }
        centre.x = min(max(centre.x, visible.minX), visible.maxX)
        centre.y = min(max(centre.y, visible.minY + size.height / 2),
                       visible.maxY - size.height / 2)
        restingCentre = centre
        dockToNearestEdge(in: visible)
    }

    private func screen(for centre: NSPoint?) -> NSScreen? {
        guard let centre else { return nil }
        return NSScreen.screens.first { $0.visibleFrame.contains(centre) }
            ?? NSScreen.screens.max {
                $0.visibleFrame.distance(to: centre)
                    < $1.visibleFrame.distance(to: centre)
            }
    }

    private func dockToNearestEdge(in visible: NSRect) {
        guard var centre = restingCentre else { return }
        let width = collapsedSize.width
        let right = centre.x >= visible.midX
        model.geometry.edgeAttachment = right ? .right : .left
        centre.x = right ? visible.maxX - width / 2 : visible.minX + width / 2
        restingCentre = centre
    }

    /// Position the fixed-size window so the resting rail sits centred on
    /// `restingCentre` and the card's flush edge touches the docked edge.
    /// The card always centres vertically inside the window; when the rail
    /// sits near the top/bottom the window clamps to the screen and the rail
    /// keeps its screen position via `railCenterY`.
    private func layout(animated: Bool = false) {
        guard panel != nil, let centre = restingCentre,
              let screen = screen(for: centre) else { return }
        let win = EdgePanelLayout.window
        let m = EdgePanelLayout.margin
        let visible = screen.visibleFrame
        var origin = NSPoint(x: 0, y: centre.y - win.height / 2)
        switch model.geometry.edgeAttachment {
        case .right:
            // The shape's flush edge is `margin` inside the window.
            origin.x = visible.maxX - win.width + m
        case .left:
            origin.x = visible.minX - m
        case .floating:
            origin.x = centre.x - win.width / 2
            origin.x = min(max(origin.x, visible.minX - m),
                           visible.maxX + m - win.width)
        }
        origin.y = min(max(origin.y, visible.minY - m),
                       visible.maxY + m - win.height)
        let target = NSRect(origin: origin, size: win)
        // The rail's centre in window coordinates (y-down) — the card morphs
        // out of it, so the view needs it even when the window is clamped.
        model.geometry.railCenterY = (origin.y + win.height) - centre.y
        setPanelFrame(target, animated: animated)
    }

    /// Single funnel for every window frame write. Even instant moves go
    /// through a zero-duration `animator().setFrame`: a direct `setFrame`
    /// does NOT cancel an in-flight dock animation, and its stale ticks would
    /// slam the window back to the old target mid-drag.
    private func setPanelFrame(_ target: NSRect, animated: Bool = false) {
        guard let panel else { return }
        let animate = animated && !reducedMotion() && panel.isVisible
            && panel.frame != target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.25 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// View hitTest cannot pass events to a different app. WindowServer must
    /// ignore the entire window while the pointer is outside the visible
    /// shape — the window is fixed-size, so most of it is transparent area
    /// that must route clicks to the app beneath.
    func syncInteraction(at mouse: NSPoint = NSEvent.mouseLocation) {
        guard let panel, panel.isVisible else { return }
        if dragStart != nil { panel.ignoresMouseEvents = false; return }
        // Early-out for the global monitor: the pointer is far outside, wasn't
        // inside, and nothing is expanded or mid-morph — skip the path build.
        if !panel.frame.insetBy(dx: -24, dy: -24).contains(mouse),
           !pointerInside, !model.geometry.edgeExpanded, !morphAnimating {
            panel.ignoresMouseEvents = true
            return
        }
        let local = NSPoint(x: mouse.x - panel.frame.minX,
                            y: panel.frame.maxY - mouse.y)
        let railY = model.geometry.railCenterY ?? EdgePanelLayout.window.height / 2
        let expanded = model.geometry.edgeExpanded
        var inside = EdgePanelLayout.path(
            expanded: expanded, sliver: model.sidePanelSliver,
            attachment: model.geometry.edgeAttachment,
            railCenterY: railY, in: panel.frame.size).contains(local)
        if !inside, morphAnimating {
            inside = EdgePanelLayout.path(
                expanded: !expanded, sliver: model.sidePanelSliver,
                attachment: model.geometry.edgeAttachment,
                railCenterY: railY, in: panel.frame.size).contains(local)
        }
        panel.ignoresMouseEvents = !inside
        // Re-arm the hover timer whenever the committed state disagrees with
        // the pointer — e.g. after a drag that left the pointer inside a
        // collapsed rail, `inside` stays true across drags but the panel must
        // still expand.
        guard !morphAnimating,
              inside != pointerInside
                  || (model.geometry.edgeExpanded != inside && hoverTask == nil) else { return }
        pointerInside = inside
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 350 : 400))
            guard !Task.isCancelled, let self, self.dragStart == nil else { return }
            self.hoverTask = nil
            guard self.model.geometry.edgeExpanded != inside else { return }
            self.model.geometry.edgeExpanded = inside
            self.noteMorph()
        }
    }

    /// The morph spring runs ~0.35 s; accept both silhouettes in the hit-test
    /// until it settles.
    private func noteMorph() {
        morphAnimating = true
        morphTask?.cancel()
        morphTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.morphAnimating = false
        }
    }

    private func startMonitoring() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncInteraction() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.syncInteraction() }
            return event
        }
    }

    func drag(to mouse: NSPoint) {
        guard let panel, restingCentre != nil else { return }
        if dragStart == nil {
            hoverTask?.cancel()
            hoverTask = nil
            dragStart = (mouse, panel.frame)
        }
        guard let start = dragStart else { return }
        let win = EdgePanelLayout.window
        let m = EdgePanelLayout.margin
        let point = NSPoint(x: start.frame.minX + mouse.x - start.mouse.x,
                            y: start.frame.minY + mouse.y - start.mouse.y)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? screen(for: NSPoint(x: point.x + win.width / 2,
                                   y: point.y + win.height / 2))
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = min(max(point.x, visible.minX - m), visible.maxX + m - win.width)
        let y = min(max(point.y, visible.minY - m), visible.maxY + m - win.height)
        let frame = NSRect(x: x, y: y, width: win.width, height: win.height)
        // Live attachment: flush left/right once the window clamps to an edge.
        model.geometry.edgeAttachment = x == visible.maxX + m - win.width ? .right
            : x == visible.minX - m ? .left : .floating
        // The resting rail follows the (centred) window while dragging.
        restingCentre = NSPoint(x: frame.midX, y: frame.midY)
        if model.geometry.railCenterY != win.height / 2 {
            model.geometry.railCenterY = win.height / 2
        }
        setPanelFrame(frame)
        panel.ignoresMouseEvents = false
    }

    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        hoverTask?.cancel()
        hoverTask = nil
        model.geometry.edgeExpanded = false
        noteMorph()
        guard let centre = restingCentre, let screen = screen(for: centre) else { return }
        dockToNearestEdge(in: screen.visibleFrame)
        if let centre = restingCentre, !SnapshotRunner.requested {
            let size = collapsedSize
            UserDefaults.standard.set(
                [Double(centre.x - size.width / 2), Double(centre.y - size.height / 2)],
                forKey: "sidePanelOrigin")
        }
        layout(animated: true)
    }

    private func showContextMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = menuTarget
            menu.addItem(menuItem)
        }
        item(model.pipelineState == .recording ? "Stop dictation" : "Start dictation",
             #selector(MenuTarget.toggleDictation(_:)))

        // Microphone submenu (§4a): Automatic + every connected device.
        let micMenu = NSMenu()
        let auto = NSMenuItem(
            title: "Automatic",
            action: #selector(MenuTarget.pickMic(_:)),
            keyEquivalent: "")
        auto.target = menuTarget
        auto.state = model.micStore.pinnedUID == nil ? .on : .off
        micMenu.addItem(auto)
        micMenu.addItem(.separator())
        for device in model.inputDevices where device.isConnected {
            let menuItem = NSMenuItem(
                title: device.name,
                action: #selector(MenuTarget.pickMic(_:)),
                keyEquivalent: "")
            menuItem.target = menuTarget
            menuItem.representedObject = device.uid
            menuItem.state = model.micStore.pinnedUID == device.uid ? .on : .off
            micMenu.addItem(menuItem)
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())
        item("Open Hush", #selector(MenuTarget.openHush(_:)))
        item("Settings…", #selector(MenuTarget.openSettings(_:)))
        item("Hide side panel", #selector(MenuTarget.hidePanel(_:)))
        menu.addItem(.separator())
        item("Restart Hush", #selector(MenuTarget.restart(_:)))
        item("Quit", #selector(MenuTarget.quit(_:)))
        let location = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}

/// SwiftUI controls receive their own events; the grab handle owns dragging.
private final class EdgeHostingView: NSHostingView<EdgePanelView> {
    var onRightClick: (NSEvent, NSView) -> Void = { _, _ in }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event, self) }
}

private extension NSRect {
    /// Shortest distance from a point to this rect (0 when inside).
    func distance(to point: NSPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Selector target for the side panel's right-click NSMenu.
@MainActor
private final class MenuTarget: NSObject {
    weak var model: AppModel?

    @objc func toggleDictation(_ sender: Any?) { model?.toggleDictation() }
    @objc func openHush(_ sender: Any?) { model?.openMainWindow() }
    @objc func openSettings(_ sender: Any?) { model?.openMainWindow(page: .settings) }
    @objc func hidePanel(_ sender: Any?) { model?.showSidePanel = false }
    @objc func restart(_ sender: Any?) { model?.relaunch() }
    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
    /// Microphone submenu: nil representedObject = Automatic (release the pin).
    @objc func pickMic(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        model?.pinMic(item.representedObject as? String)
    }
}
