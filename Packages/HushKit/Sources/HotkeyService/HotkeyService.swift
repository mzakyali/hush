import CoreGraphics
import Foundation
import HushCore
import OSLog

private let hotkeyLog = Logger(subsystem: "com.local.hush", category: "hotkeys")

/// CGEventTap adapter around `HotkeyStateMachine`.
///
/// Requires macOS Input Monitoring permission (and Accessibility for taps into other
/// apps' secure contexts). The tap runs on a dedicated run-loop thread so event
/// delivery never depends on the main thread.
public final class HotkeyService: @unchecked Sendable {
    public enum Error: Swift.Error {
        case tapCreationFailed
    }

    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private let box = MachineBox()

    /// Callback for logging raw hotkey events (console verification during onboarding).
    public var onInput: (@Sendable (String) -> Void)? {
        get { box.onInput }
        set { box.onInput = newValue }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var scheduledTick = TickGuard()

    public init(holdKey: HoldKey = .fn) {
        box.machine.holdKey = holdKey
        var continuation: AsyncStream<HotkeyEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Current Input Monitoring permission state, without prompting.
    public static func hasInputMonitoring() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts the system permission dialog for Input Monitoring.
    public static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    /// Whether the event tap was created and its run loop thread started.
    public var isRunning: Bool {
        tap != nil
    }

    public func setRecording(_ recording: Bool) {
        box.withLock { $0.setRecording(recording) }
    }

    public func start() throws {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        box.tickGuard = scheduledTick
        box.continuation = continuation

        let opaqueBox = Unmanaged.passUnretained(box).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let box = Unmanaged<MachineBox>.fromOpaque(refcon).takeUnretainedValue()
                return box.handleTapEvent(type: type, event: event)
            },
            userInfo: opaqueBox
        ) else {
            throw Error.tapCreationFailed
        }
        self.tap = tap
        box.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        let thread = Thread { [weak self] in
            guard let source = self?.runLoopSource else { return }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "dev.hush.hotkey-tap"
        thread.start()
        self.tapThread = thread
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFMachPortInvalidate(tap)
                CFRunLoopSourceInvalidate(source)
            }
        }
        tap = nil
        runLoopSource = nil
        tapThread = nil
        scheduledTick.cancelAll()
    }

    deinit {
        stop()
    }
}

/// Guards scheduled hold-debounce ticks so a stale tick can't fire after a new sequence.
final class TickGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func next() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    func isCurrent(_ token: Int) -> Bool {
        lock.withLock { generation == token }
    }

    func cancelAll() {
        lock.withLock { generation += 1 }
    }
}

/// Lock-protected box for the value-type state machine plus tap plumbing.
final class MachineBox: @unchecked Sendable {
    var machine = HotkeyStateMachine()
    var tap: CFMachPort?
    var tickGuard: TickGuard?
    var continuation: AsyncStream<HotkeyEvent>.Continuation?
    var onInput: (@Sendable (String) -> Void)?

    private let lock = NSLock()

    func withLock<T>(_ body: (inout HotkeyStateMachine) -> T) -> T {
        lock.withLock { body(&machine) }
    }

    /// Convert a CGEvent into the machine's normalized input. Returns nil for events we ignore.
    func normalize(type: CGEventType, event: CGEvent) -> HotkeyInput? {
        let at = ProcessInfo.processInfo.systemUptime
        let flags = event.flags
        let modifiers = HotkeyModifiers(
            fn: flags.contains(.maskSecondaryFn),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift),
            command: flags.contains(.maskCommand)
        )
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            // For flag keys, down = the flag became set.
            let down = keyCode == HotkeyStateMachine.fnKeyCode
                ? modifiers.fn
                : flagIsDown(keyCode: keyCode, modifiers: modifiers)
            if keyCode == HotkeyStateMachine.fnKeyCode {
                hotkeyLog.debug("Fn flags: down=\(down, privacy: .public) HIDFn=\(CGEventSource.keyState(.hidSystemState, key: keyCode), privacy: .public)")
            }
            onInput?("flagsChanged keyCode=\(keyCode) down=\(down)")
            return .flags(keyCode: keyCode, down: down, modifiers: modifiers, at: at)
        case .keyDown:
            if keyCode == HotkeyStateMachine.fnKeyCode {
                hotkeyLog.debug("Fn keyDown: flag=\(modifiers.fn, privacy: .public)")
            }
            onInput?("keyDown keyCode=\(keyCode)")
            return .key(keyCode: keyCode, down: true, modifiers: modifiers, at: at)
        case .keyUp:
            if keyCode == HotkeyStateMachine.fnKeyCode {
                hotkeyLog.debug("Fn keyUp: flag=\(modifiers.fn, privacy: .public)")
            }
            return .key(keyCode: keyCode, down: false, modifiers: modifiers, at: at)
        default:
            return nil
        }
    }

    private func flagIsDown(keyCode: UInt16, modifiers: HotkeyModifiers) -> Bool {
        switch keyCode {
        case HotkeyStateMachine.leftOptionKeyCode, HotkeyStateMachine.rightOptionKeyCode:
            return modifiers.option
        case 55, 54: return modifiers.command
        case 56, 60: return modifiers.shift
        case 59, 62: return modifiers.control
        default: return false
        }
    }

    func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hotkeyLog.warning("event tap disabled: \(type.rawValue, privacy: .public); re-enabling")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        guard let input = normalize(type: type, event: event) else {
            return Unmanaged.passRetained(event)
        }
        let result = withLock { $0.handle(input) }
        if let tickAt = result.scheduleTickAt {
            scheduleTick(tickAt: tickAt, guard: tickGuard, continuation: continuation)
        }
        for event in result.events {
            hotkeyLog.debug("emit \(String(describing: event), privacy: .public)")
            continuation?.yield(event)
        }
        return result.consume ? nil : Unmanaged.passRetained(event)
    }

    /// Deliver a `.tick` after the hold debounce unless superseded by a newer tick.
    func scheduleTick(tickAt: TimeInterval, guard tickGuard: TickGuard?, continuation: AsyncStream<HotkeyEvent>.Continuation?) {
        guard let tickGuard else { return }
        let token = tickGuard.next()
        let delay = max(0, tickAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard tickGuard.isCurrent(token) else { return }
            guard let result = self?.withLock({ $0.handle(.tick(at: tickAt)) }) else { return }
            for event in result.events {
                hotkeyLog.debug("emit \(String(describing: event), privacy: .public)")
                continuation?.yield(event)
            }
        }
    }
}
