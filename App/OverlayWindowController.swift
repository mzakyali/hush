import AppKit
import HushCore
import SwiftUI

/// Non-activating bottom-of-screen panel hosting the recording pill. Fixed
/// 360 × 90 transparent frame with the pill centred at the bottom, so width
/// changes and the drop shadow are never clipped. It exists only during
/// dictation — the idle affordance is `EdgePanelController` — and accepts
/// mouse events only while recording (click-to-stop), only inside the capsule.
@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private let model: AppModel

    private static let size = NSSize(width: 360, height: 90)

    init(model: AppModel) {
        self.model = model
    }

    /// The pill sits on the screen containing the mouse when recording starts.
    func show() {
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
        syncInteraction()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Displays added/removed/changed — keep the pill bottom-centred on the
    /// dictation screen.
    func reposition() {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    /// Clickable only while recording (click-to-stop); every other state is
    /// click-through. The nonactivating panel never takes focus, so clicking
    /// can't steal the insertion target from the frontmost app.
    func syncInteraction() {
        panel?.ignoresMouseEvents = model.recording.overlayState != .recording
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the view draws its own shadow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = OverlayHostingView(rootView: OverlayPillView(feed: model.recording))
        hosting.hitArea = { [weak model] in model?.recording.pillHitRect ?? .zero }
        hosting.onLeftClick = { [weak model] in model?.toggleDictation() }
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Bottom-centre of the screen containing the mouse. The pill's bottom
    /// edge is `bottomInset` above the panel bottom and lands 20pt above the
    /// screen's visible-frame bottom.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 20 - OverlayPillView.bottomInset
        )
        panel.setFrameOrigin(origin)
    }
}

/// Hosts the pill; hit-tests only inside the capsule (tracked via the view's
/// `pillHitRect` preference) so the transparent margins of the panel click
/// through to apps underneath.
private final class OverlayHostingView: NSHostingView<OverlayPillView> {
    var hitArea: () -> CGRect = { .zero }
    var onLeftClick: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        var local = convert(point, from: superview)
        if !isFlipped { local.y = bounds.height - local.y }
        guard hitArea().contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) { onLeftClick() }
}
