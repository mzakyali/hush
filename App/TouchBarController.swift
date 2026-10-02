import AppKit
import Combine
import IOKit
import os

/// Touch Bar support via the private DFR/AppKit system-modal API — Hush is
/// never frontmost while dictating, so the responder-chain `NSTouchBar`
/// never shows. The Control Strip tray item + system-modal bars let the bar
/// appear from any context. Everything resolves at runtime and degrades to a
/// no-op when the hardware or the selectors are missing.
///
/// Plain AppKit only — no SwiftUI in Touch Bar views, no symbol effects
/// (the Fn-stall lesson): the recording wave is an NSView redrawn by a
/// 30 Hz timer that runs only while the bar is presented.
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private static let log = Logger(subsystem: "com.local.hush", category: "touchbar")

    // MARK: - item identifiers

    private enum ID {
        static let tray = NSTouchBarItem.Identifier("com.local.hush.tray")
        static let dictate = NSTouchBarItem.Identifier("com.local.hush.dictate")
        static let mic = NSTouchBarItem.Identifier("com.local.hush.mic")
        static let micAuto = NSTouchBarItem.Identifier("com.local.hush.mic.auto")
        static let micDevicePrefix = "com.local.hush.mic.d."
        static let pasteRaw = NSTouchBarItem.Identifier("com.local.hush.pasteraw")
        static let open = NSTouchBarItem.Identifier("com.local.hush.open")
        static let cancel = NSTouchBarItem.Identifier("com.local.hush.cancel")
        static let wave = NSTouchBarItem.Identifier("com.local.hush.wave")
        static let stop = NSTouchBarItem.Identifier("com.local.hush.stop")
        static let processing = NSTouchBarItem.Identifier("com.local.hush.processing")
    }

    // MARK: - availability

    /// Touch Bar hardware: the DFR display device (`dispdfr`) exists in
    /// IORegistry only on Touch Bar Macs — a stronger signal than the mere
    /// presence of the NSTouchBar class.
    static let hardwarePresent: Bool = {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching("dispdfr"),
            &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        let dev = IOIteratorNext(iter)
        guard dev != IO_OBJECT_NULL else { return false }
        IOObjectRelease(dev)
        return true
    }()

    /// dlopen'd DFRFoundation entry points — nil when the framework or the
    /// symbol is gone (never linked).
    private typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void
    private typealias ShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private static let setPresence: SetPresenceFn? = {
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
               RTLD_NOW)
            .flatMap { dlsym($0, "DFRElementSetControlStripPresenceForIdentifier") }
            .map { unsafeBitCast($0, to: SetPresenceFn.self) }
    }()
    private static let showsCloseBox: ShowsCloseBoxFn? = {
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
               RTLD_NOW)
            .flatMap { dlsym($0, "DFRSystemModalShowsCloseBoxWhenFrontMost") }
            .map { unsafeBitCast($0, to: ShowsCloseBoxFn.self) }
    }()

    /// Every private selector we call, checked once up front.
    static var apiAvailable: Bool {
        NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:"))
            && NSTouchBarItem.responds(to: NSSelectorFromString("removeSystemTrayItem:"))
            && (NSTouchBar.responds(to: NSSelectorFromString(
                    "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"))
                || NSTouchBar.responds(to: NSSelectorFromString(
                    "presentSystemModalTouchBar:systemTrayItemIdentifier:")))
            && NSTouchBar.responds(to: NSSelectorFromString("dismissSystemModalTouchBar:"))
            && setPresence != nil
    }

    static var supported: Bool { hardwarePresent && apiAvailable }

    // MARK: - state

    private weak var model: AppModel?
    private var trayItem: NSCustomTouchBarItem?
    private var trayButton: NSButton?
    private var idleBar: NSTouchBar?
    private var recordingBar: NSTouchBar?
    private var presented: NSTouchBar?
    private var waveView: TouchBarWaveView?
    private var waveTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var installed = false
    private var enabled = true

    private static let signalOrange = NSColor(srgbRed: 1, green: 0x5B / 255,
                                              blue: 0x2E / 255, alpha: 1)

    // MARK: - lifecycle

    /// Install the Control Strip tray item and subscribe to the recording
    /// feed. Idempotent; a silent no-op without hardware or the private API.
    func install(model: AppModel) {
        guard !installed else { return }
        installed = true
        self.model = model
        enabled = model.touchBarEnabled
        guard Self.supported else {
            Self.log.info("touch bar unavailable — hardware=\(Self.hardwarePresent) api=\(Self.apiAvailable)")
            return
        }

        let button = NSButton(image: NSImage(named: "MenuBarIcon") ?? NSImage(),
                              target: self, action: #selector(trayTapped))
        button.bezelStyle = .regularSquare
        let item = NSCustomTouchBarItem(identifier: ID.tray)
        item.view = button
        trayButton = button
        trayItem = item
        if NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:")) {
            NSTouchBarItem.addSystemTrayItem(item)
        }
        // Keep the tray item resident in the Control Strip regardless of the
        // frontmost app.
        Self.setPresence?(ID.tray.rawValue as NSString, true)

        model.recording.$overlayState
            .sink { [weak self] state in
                Task { @MainActor in self?.overlayStateChanged(state) }
            }
            .store(in: &cancellables)
        Self.log.info("touch bar tray item installed")
    }

    /// Settings toggle — off removes everything and dismisses any modal bar.
    func setEnabled(_ on: Bool) {
        enabled = on
        if on { reinstallTray() } else { teardown() }
    }

    private func reinstallTray() {
        guard installed, Self.supported, trayItem == nil else { return }
        let button = NSButton(image: NSImage(named: "MenuBarIcon") ?? NSImage(),
                              target: self, action: #selector(trayTapped))
        button.bezelStyle = .regularSquare
        let item = NSCustomTouchBarItem(identifier: ID.tray)
        item.view = button
        trayButton = button
        trayItem = item
        NSTouchBarItem.addSystemTrayItem(item)
        Self.setPresence?(ID.tray.rawValue as NSString, true)
    }

    /// Detach everything — tray item, Control Strip presence, modal bar.
    /// Called on quit and when the setting turns off.
    func teardown() {
        dismissModal()
        if let trayItem,
           NSTouchBarItem.responds(to: NSSelectorFromString("removeSystemTrayItem:")) {
            NSTouchBarItem.removeSystemTrayItem(trayItem)
        }
        Self.setPresence?(ID.tray.rawValue as NSString, false)
        trayItem = nil
        trayButton = nil
    }

    // MARK: - modal presentation

    /// Present a bar system-modally, preferring the 3-arg variant. The
    /// `showsCloseBox` DFR flag decides whether the system draws its own
    /// close box on the left — hidden for the recording bar so the physical
    /// Esc region (and our own Cancel) owns the space.
    private func presentModal(_ bar: NSTouchBar, systemCloseBox: Bool) {
        Self.showsCloseBox?(systemCloseBox)
        if NSTouchBar.responds(to: NSSelectorFromString(
            "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")) {
            NSTouchBar.presentSystemModalTouchBar(
                bar, placement: 0, systemTrayItemIdentifier: ID.tray)
        } else if NSTouchBar.responds(to: NSSelectorFromString(
            "presentSystemModalTouchBar:systemTrayItemIdentifier:")) {
            NSTouchBar.presentSystemModalTouchBar(
                bar, systemTrayItemIdentifier: ID.tray)
        } else {
            return
        }
        presented = bar
    }

    private func dismissModal() {
        waveTimer?.invalidate()
        waveTimer = nil
        guard let presented else { return }
        self.presented = nil
        if NSTouchBar.responds(to: NSSelectorFromString("dismissSystemModalTouchBar:")) {
            NSTouchBar.dismissSystemModalTouchBar(presented)
        }
    }

    // MARK: - state → UI

    private func overlayStateChanged(_ state: RecordingFeed.OverlayState) {
        guard enabled else { return }
        switch state {
        case .recording:
            trayButton?.contentTintColor = Self.signalOrange
            showRecordingBar(processing: false)
        case .processing:
            trayButton?.contentTintColor = Self.signalOrange
            // Same bar, processing mode: constant-amplitude wave + label,
            // Cancel hidden.
            showRecordingBar(processing: true)
        case .done, .copied, .error(_), .cancelled, .hidden:
            trayButton?.contentTintColor = nil
            dismissModal()
        }
    }

    private func showRecordingBar(processing: Bool) {
        let bar = recordingBar ?? makeRecordingBar()
        recordingBar = bar
        waveView?.processing = processing
        bar.defaultItemIdentifiers = processing
            ? [ID.wave, .flexibleSpace, ID.processing]
            : [ID.cancel, ID.wave, .flexibleSpace, ID.stop]
        if presented !== bar {
            // Recording overrides whatever is up (including our idle bar).
            presentModal(bar, systemCloseBox: false)
        }
        if waveTimer == nil {
            waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30,
                                           repeats: true) { [weak self] _ in
                Task { @MainActor in self?.waveTimerFired() }
            }
        }
    }

    private func waveTimerFired() {
        guard let model, let waveView else { return }
        let level = Double(model.recording.levelHistory.first ?? 0)
        waveView.amplitude = max(0.04, level * 3)
        waveView.hotCenter = level > 0.15
        waveView.needsDisplay = true
    }

    // MARK: - bars

    /// Idle bar behind the Control Strip button: Dictate / mic picker /
    /// Paste raw / Open Hush, plus the system close box on the left.
    private func makeIdleBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers =
            [ID.dictate, ID.mic, ID.pasteRaw, .flexibleSpace, ID.open]
        return bar
    }

    /// Recording bar: [✕ Cancel] [wave] [■ Stop] — items rebuilt for the
    /// processing variant (no Cancel; PROCESSING label instead).
    private func makeRecordingBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [ID.cancel, ID.wave, .flexibleSpace, ID.stop]
        return bar
    }

    /// Popover bar inside the mic picker — Automatic + connected devices.
    private func makeMicBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        var ids: [NSTouchBarItem.Identifier] = [ID.micAuto]
        for device in model?.inputDevices ?? [] where device.isConnected {
            ids.append(NSTouchBarItem.Identifier(ID.micDevicePrefix + device.uid))
        }
        bar.defaultItemIdentifiers = ids
        return bar
    }

    // MARK: - NSTouchBarDelegate

    nonisolated func touchBar(_ touchBar: NSTouchBar,
                              makeItemForIdentifier identifier: NSTouchBarItem.Identifier)
        -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            switch identifier {
            case ID.dictate:
                return buttonItem(identifier, title: "● Dictate",
                                  bezel: Self.signalOrange,
                                  action: #selector(dictateTapped))
            case ID.mic:
                let name = model?.currentMicName ?? "Automatic"
                let popover = NSPopoverTouchBarItem(identifier: identifier)
                popover.collapsedRepresentationLabel = "mic: \(name) ▾"
                popover.popoverTouchBar = makeMicBar()
                micPopover = popover
                return popover
            case ID.micAuto:
                return buttonItem(identifier, title: "Automatic",
                                  action: #selector(micAutoTapped))
            case ID.pasteRaw:
                return buttonItem(identifier, title: "Paste raw",
                                  action: #selector(pasteRawTapped))
            case ID.open:
                return buttonItem(identifier, title: "Open Hush",
                                  action: #selector(openTapped))
            case ID.cancel:
                return buttonItem(identifier, title: "✕ Cancel",
                                  action: #selector(cancelTapped))
            case ID.stop:
                return buttonItem(identifier, title: "■ Stop",
                                  bezel: Self.signalOrange,
                                  action: #selector(stopTapped))
            case ID.wave:
                let view = TouchBarWaveView(
                    frame: NSRect(x: 0, y: 0, width: 300, height: 30))
                waveView = view
                let item = NSCustomTouchBarItem(identifier: identifier)
                item.view = view
                return item
            case ID.processing:
                let label = NSTextField(labelWithString: "PROCESSING")
                label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
                label.textColor = NSColor.white.withAlphaComponent(0.55)
                let item = NSCustomTouchBarItem(identifier: identifier)
                item.view = label
                return item
            default:
                break
            }
            // "com.local.hush.mic.d.<uid>" — one item per connected device.
            let raw = identifier.rawValue
            if raw.hasPrefix(ID.micDevicePrefix) {
                let uid = String(raw.dropFirst(ID.micDevicePrefix.count))
                let name = model?.inputDevices
                    .first(where: { $0.uid == uid })?.name ?? uid
                return deviceItem(identifier, title: name, uid: uid)
            }
            return nil
        }
    }

    private func buttonItem(_ identifier: NSTouchBarItem.Identifier,
                            title: String,
                            bezel: NSColor? = nil,
                            action: Selector) -> NSCustomTouchBarItem {
        let button = NSButton(title: title, target: self, action: action)
        if let bezel { button.bezelColor = bezel }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = button
        return item
    }

    /// Device rows carry their UID in the button's identifier so a single
    /// action can dispatch.
    private weak var micPopover: NSPopoverTouchBarItem?

    private func deviceItem(_ identifier: NSTouchBarItem.Identifier,
                            title: String,
                            uid: String) -> NSCustomTouchBarItem {
        let button = NSButton(title: title, target: self,
                              action: #selector(micDeviceTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(uid)
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = button
        return item
    }

    // MARK: - actions

    @objc private func trayTapped() {
        let bar = makeIdleBar()
        idleBar = bar
        presentModal(bar, systemCloseBox: true)
    }

    @objc private func dictateTapped() { model?.toggleDictation() }
    @objc private func stopTapped() { model?.toggleDictation() }
    @objc private func cancelTapped() { model?.cancelDictation() }
    @objc private func pasteRawTapped() { model?.pasteRaw() }

    @objc private func openTapped() {
        dismissModal()
        model?.openMainWindow()
    }

    @objc private func micAutoTapped() {
        model?.pinMic(nil)
        micPopover?.dismissPopover(nil)
    }

    @objc private func micDeviceTapped(_ sender: NSButton) {
        model?.pinMic(sender.identifier?.rawValue)
        micPopover?.dismissPopover(nil)
    }
}

// MARK: - wave view

/// AppKit twin of the overlay pill's dot wave (OverlayPillView): lit dots
/// only, travelling sine, orange hot centre. Drawn via `draw(_:)` on a 30 Hz
/// `needsDisplay` timer owned by the controller while the bar is presented —
/// no TimelineView, no Core Animation, no symbol effects.
final class TouchBarWaveView: NSView {
    var amplitude: Double = 0.04
    var hotCenter = false
    /// Processing mode: constant amplitude, faster period, dimmer tint.
    var processing = false

    private static let columns = 60
    private static let dot: CGFloat = 3
    private static let hPitch: CGFloat = 5
    private static let vPitch: CGFloat = 3.5
    private static let signalOrange = NSColor(srgbRed: 1, green: 0x5B / 255,
                                              blue: 0x2E / 255, alpha: 1)

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.columns) * Self.hPitch, height: 30)
    }

    override func draw(_ rect: NSRect) {
        let now = Date().timeIntervalSince1970
        let amp = processing ? 1.0 : amplitude
        let period = processing ? 0.6 : 0.9
        let tint = processing
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.white.withAlphaComponent(0.85)
        let midY = bounds.midY
        let ox = (bounds.width - CGFloat(Self.columns) * Self.hPitch) / 2
        for c in 0..<Self.columns {
            let x = Double(c) / Double(Self.columns - 1)
            let env = sin(.pi * x)
            let phase = 2 * .pi * 1.6 * x - 2 * .pi * now / period
            let row = (amp * env * sin(phase)).rounded()
            let hot = !processing && hotCenter && abs(c - Self.columns / 2) <= 1
            (hot ? Self.signalOrange : tint).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: ox + CGFloat(c) * Self.hPitch,
                y: midY - row * Self.vPitch - Self.dot / 2,
                width: Self.dot, height: Self.dot)).fill()
            // Echo strand: opposite phase at 0.6× amplitude.
            let echoRow = (-0.6 * amp * env * sin(phase)).rounded()
            tint.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: ox + CGFloat(c) * Self.hPitch,
                y: midY - echoRow * Self.vPitch - Self.dot / 2,
                width: Self.dot, height: Self.dot)).fill()
        }
    }
}
