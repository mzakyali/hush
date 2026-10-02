import AppKit
import AudioCapture
import HushCore
import SwiftUI

/// A small nonactivating window, sized to its visible summary or detail card.
@MainActor
final class EdgePanelController {
    private var panel: NSPanel?
    private let model: AppModel
    private let reducedMotion: @MainActor () -> Bool
    private let menuTarget = MenuTarget()
    private var restingOrigin: NSPoint?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameAnimating = false
    private var pointerInside = false
    private var dragStart: (mouse: NSPoint, frame: NSRect)?

    init(model: AppModel, reducedMotion: @escaping @MainActor () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.model = model
        self.reducedMotion = reducedMotion
        menuTarget.model = model
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
        frameTask?.cancel()
        frameAnimating = false
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

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: EdgePanelView.size(expanded: false)),
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
        let size = EdgePanelView.size(expanded: false)
        if restingOrigin == nil, !SnapshotRunner.requested,
           let saved = UserDefaults.standard.array(forKey: "sidePanelOrigin") as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            restingOrigin = NSPoint(x: saved[0], y: saved[1])
        }
        guard let screen = screen(for: restingOrigin) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if restingOrigin == nil {
            let fraction = SnapshotRunner.requested ? 0.5
                : UserDefaults.standard.object(forKey: "edgeTabFraction") as? Double ?? 0.5
            restingOrigin = NSPoint(x: visible.maxX - size.width,
                                    y: visible.minY + visible.height * fraction - size.height / 2)
        }
        restingOrigin = clamped(restingOrigin ?? .zero, size: size, in: visible)
        dockToNearestEdge(in: visible)
    }

    private func screen(for origin: NSPoint?) -> NSScreen? {
        guard let origin else { return nil }
        let size = EdgePanelView.size(expanded: false)
        let centre = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return NSScreen.screens.first { $0.visibleFrame.contains(centre) }
            ?? NSScreen.screens.max {
                $0.visibleFrame.intersection(NSRect(origin: origin, size: size)).area
                    < $1.visibleFrame.intersection(NSRect(origin: origin, size: size)).area
            }
    }

    private func clamped(_ origin: NSPoint, size: NSSize, in rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, rect.minX), max(rect.minX, rect.maxX - size.width)),
                y: min(max(origin.y, rect.minY), max(rect.minY, rect.maxY - size.height)))
    }

    private func dockToNearestEdge(in visible: NSRect) {
        guard var origin = restingOrigin else { return }
        let width = EdgePanelView.size(expanded: false).width
        let right = origin.x + width / 2 >= visible.midX
        model.geometry.edgeAttachment = right ? .right : .left
        origin.x = right ? visible.maxX - width : visible.minX
        restingOrigin = origin
    }

    private func layout(animated: Bool = false) {
        guard let panel, let origin = restingOrigin,
              let screen = screen(for: origin) else { return }
        let summary = EdgePanelView.size(expanded: false)
        let size = EdgePanelView.size(expanded: model.geometry.edgeExpanded)
        var point = NSPoint(x: origin.x, y: origin.y + (summary.height - size.height) / 2)
        if model.geometry.edgeAttachment == .right { point.x += summary.width - size.width }
        point = clamped(point, size: size, in: screen.visibleFrame)
        let target = NSRect(origin: point, size: size)
        frameTask?.cancel()
        frameAnimating = false
        let reduceMotion = reducedMotion()
        guard animated, !reduceMotion, panel.isVisible else {
            applyFrame(target)
            return
        }
        let start = panel.frame
        frameAnimating = true
        frameTask = Task { @MainActor [weak self] in
            for step in 1...26 {
                guard !Task.isCancelled, let self else { return }
                let t = CGFloat(step) / 26
                let eased = 1 - pow(1 - t, 4)
                let frame = NSRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased)
                self.applyFrame(frame)
                self.syncInteraction()
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, let self else { return }
            self.applyFrame(target)
            self.frameAnimating = false
            self.frameTask = nil
            self.syncInteraction()
        }
    }

    private func applyFrame(_ frame: NSRect) {
        guard let panel else { return }
        model.geometry.edgePanelSize = frame.size
        panel.setFrame(frame, display: true)
    }

    /// View hitTest cannot pass events to a different app. WindowServer must
    /// ignore the entire window while the pointer is outside the visible path.
    func syncInteraction(at mouse: NSPoint = NSEvent.mouseLocation) {
        guard let panel, panel.isVisible else { return }
        if dragStart != nil { panel.ignoresMouseEvents = false; return }
        let local = NSPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let shape = SidePanelShape(attachment: model.geometry.edgeAttachment)
        let inside = shape.path(in: NSRect(origin: .zero, size: panel.frame.size)).contains(local)
        panel.ignoresMouseEvents = !inside
        guard !frameAnimating,
              inside != pointerInside || (model.geometry.edgeExpanded != inside && hoverTask == nil) else { return }
        pointerInside = inside
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 350 : 400))
            guard !Task.isCancelled, let self, self.dragStart == nil else { return }
            self.hoverTask = nil
            guard self.model.geometry.edgeExpanded != inside else { return }
            self.model.geometry.edgeExpanded = inside
            self.layout(animated: true)
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
        guard let panel, restingOrigin != nil else { return }
        if dragStart == nil {
            hoverTask?.cancel()
            hoverTask = nil
            frameTask?.cancel()
            frameAnimating = false
            dragStart = (mouse, panel.frame)
        }
        guard let start = dragStart else { return }
        let point = NSPoint(x: start.frame.minX + mouse.x - start.mouse.x,
                            y: start.frame.minY + mouse.y - start.mouse.y)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? screen(for: point) ?? NSScreen.main
        guard let screen else { return }
        let frame = NSRect(origin: clamped(point, size: start.frame.size, in: screen.visibleFrame),
                           size: start.frame.size)
        model.geometry.edgeAttachment = frame.maxX == screen.visibleFrame.maxX ? .right
            : frame.minX == screen.visibleFrame.minX ? .left : .floating
        let summary = EdgePanelView.size(expanded: false)
        self.restingOrigin = NSPoint(x: frame.midX - summary.width / 2,
                                    y: frame.midY - summary.height / 2)
        applyFrame(frame)
        panel.ignoresMouseEvents = false
    }

    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        hoverTask?.cancel()
        hoverTask = nil
        model.geometry.edgeExpanded = false
        guard let screen = screen(for: restingOrigin) else { return }
        dockToNearestEdge(in: screen.visibleFrame)
        if let origin = restingOrigin, !SnapshotRunner.requested {
            UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: "sidePanelOrigin")
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
    var area: CGFloat { isNull ? 0 : width * height }
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
