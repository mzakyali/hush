import Foundation
import HushCore

/// Which physical key acts as hold-to-talk.
public enum HoldKey: Sendable, Equatable {
    case fn
    case rightOption
}

/// Modifier flags relevant to hotkey matching, normalized from CGEventFlags.
public struct HotkeyModifiers: Sendable, Equatable {
    public var fn = false
    public var control = false
    public var option = false
    public var shift = false
    public var command = false

    public init(fn: Bool = false, control: Bool = false, option: Bool = false,
                shift: Bool = false, command: Bool = false) {
        self.fn = fn
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }
}

/// Normalized input fed to `HotkeyStateMachine` by the CGEventTap adapter (or by tests).
public enum HotkeyInput: Sendable, Equatable {
    /// flagsChanged event: `keyCode` is the hardware key code, `down` is the new pressed state.
    case flags(keyCode: UInt16, down: Bool, modifiers: HotkeyModifiers, at: TimeInterval)
    /// keyDown / keyUp for a non-modifier key, with the modifiers held at the time.
    case key(keyCode: UInt16, down: Bool, modifiers: HotkeyModifiers, at: TimeInterval)
    /// Synthetic event: the adapter asks the machine to re-check a pending hold at this time.
    case tick(at: TimeInterval)
}

public struct HotkeyResult: Sendable, Equatable {
    public var events: [HotkeyEvent]
    /// Whether the adapter should suppress the underlying CGEvent.
    public var consume: Bool
    /// If set, the adapter must deliver a `.tick(at:)` input at this time.
    public var scheduleTickAt: TimeInterval?

    public init(events: [HotkeyEvent] = [], consume: Bool = false, scheduleTickAt: TimeInterval? = nil) {
        self.events = events
        self.consume = consume
        self.scheduleTickAt = scheduleTickAt
    }
}

/// Pure state machine for Hush's hotkeys. No I/O — fully unit-testable.
///
/// Rules (plan T1):
/// - Hold: `holdKey` pressed alone and held >= `holdDebounce`; `holdStart` fires once the
///   debounce elapses (delivered via `.tick`), `holdEnd` on release. Holds shorter than
///   the debounce emit nothing. Another key pressed while the hold is still pending
///   (e.g. Fn+F-key) cancels it — the combo is not a hold.
/// - Toggle: option pressed and released twice, second release within `doubleTapWindow`
///   of the first, with no other key in between.
/// - Cancel: Esc while recording (consumed). Esc while idle is ignored.
/// - Paste-raw: Ctrl+Option+Z (Command/Shift disqualify the chord).
public struct HotkeyStateMachine: Sendable {
    public var holdKey: HoldKey = .fn
    public var holdDebounce: TimeInterval = 0.150
    public var doubleTapWindow: TimeInterval = 0.350

    /// macOS key codes.
    public static let fnKeyCode: UInt16 = 63
    public static let leftOptionKeyCode: UInt16 = 58
    public static let rightOptionKeyCode: UInt16 = 61
    public static let escapeKeyCode: UInt16 = 53
    public static let zKeyCode: UInt16 = 6

    /// Set by the owner whenever the pipeline's recording state changes.
    public private(set) var isRecording = false

    // hold state
    private var holdDownAt: TimeInterval?
    private var holdPending = false
    private var holdActive = false
    private var modifiersHeld: Set<UInt16> = []
    private var keysHeld: Set<UInt16> = []

    // double-tap state
    private var firstTapReleaseAt: TimeInterval?
    private var firstTapSide: UInt16?
    private var secondTapStarted = false

    public init(holdKey: HoldKey = .fn, holdDebounce: TimeInterval = 0.150, doubleTapWindow: TimeInterval = 0.350) {
        self.holdKey = holdKey
        self.holdDebounce = holdDebounce
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func setRecording(_ recording: Bool) {
        isRecording = recording
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult {
        switch input {
        case let .flags(keyCode, down, modifiers, at):
            return handleFlags(keyCode: keyCode, down: down, modifiers: modifiers, at: at)
        case let .key(keyCode, down, modifiers, at):
            return handleKey(keyCode: keyCode, down: down, modifiers: modifiers, at: at)
        case let .tick(at):
            return handleTick(at: at)
        }
    }

    // MARK: - flagsChanged

    private mutating func handleFlags(keyCode: UInt16, down: Bool, modifiers: HotkeyModifiers, at: TimeInterval) -> HotkeyResult {
        // Decide before updating modifiersHeld so "pressed alone" sees only *other* held keys.
        let result: HotkeyResult
        if keyCode == Self.fnKeyCode {
            result = handleFn(down: down, at: at)
        } else if keyCode == Self.leftOptionKeyCode || keyCode == Self.rightOptionKeyCode {
            result = handleOption(keyCode: keyCode, down: down, at: at)
        } else {
            // Any other modifier (cmd/ctrl/shift) between taps breaks the double-tap.
            resetTap()
            result = HotkeyResult()
        }
        if down {
            modifiersHeld.insert(keyCode)
        } else {
            modifiersHeld.remove(keyCode)
        }
        return result
    }

    private mutating func handleFn(down: Bool, at: TimeInterval) -> HotkeyResult {
        guard holdKey == .fn else { return HotkeyResult() }
        if down {
            // "Pressed alone": no other modifier or key may be held right now.
            if modifiersHeld.isEmpty && keysHeld.isEmpty {
                holdDownAt = at
                holdPending = true
                return HotkeyResult(consume: true, scheduleTickAt: at + holdDebounce)
            }
            return HotkeyResult(consume: true)
        }
        // Fn released.
        if holdActive {
            holdActive = false
            holdPending = false
            holdDownAt = nil
            return HotkeyResult(events: [.holdEnd], consume: true)
        }
        holdPending = false
        holdDownAt = nil
        return HotkeyResult(consume: true)
    }

    private mutating func handleOption(keyCode: UInt16, down: Bool, at: TimeInterval) -> HotkeyResult {
        // Right-Option as the hold key (fallback when Fn is unreliable).
        if holdKey == .rightOption && keyCode == Self.rightOptionKeyCode {
            if down {
                if modifiersHeld.isEmpty && keysHeld.isEmpty {
                    holdDownAt = at
                    holdPending = true
                    return HotkeyResult(scheduleTickAt: at + holdDebounce)
                }
                return HotkeyResult()
            }
            if holdActive {
                holdActive = false
                holdPending = false
                holdDownAt = nil
                return HotkeyResult(events: [.holdEnd])
            }
            holdPending = false
            holdDownAt = nil
            return HotkeyResult()
        }

        if down {
            // A press of the other option side breaks a tap sequence in progress.
            if let firstSide = firstTapSide, firstSide != keyCode {
                resetTap()
            } else if firstTapReleaseAt != nil {
                secondTapStarted = true
            }
            return HotkeyResult()
        }
        // Option released: completes a tap.
        // Epsilon absorbs Float error at the window edge (e.g. 0.40-0.05 = 0.35000000000000003).
        if secondTapStarted, let first = firstTapReleaseAt,
           at - first <= doubleTapWindow + 1e-9 {
            resetTap()
            return HotkeyResult(events: [.toggle])
        }
        firstTapReleaseAt = at
        firstTapSide = keyCode
        secondTapStarted = false
        return HotkeyResult()
    }

    // MARK: - keyDown / keyUp

    private mutating func handleKey(keyCode: UInt16, down: Bool, modifiers: HotkeyModifiers, at: TimeInterval) -> HotkeyResult {
        if down {
            keysHeld.insert(keyCode)
        } else {
            keysHeld.remove(keyCode)
        }
        guard down else { return HotkeyResult() }

        if keyCode == Self.escapeKeyCode {
            if isRecording {
                return HotkeyResult(events: [.cancel], consume: true)
            }
            return HotkeyResult()  // Esc ignored when idle — passes through
        }

        if keyCode == Self.zKeyCode,
           modifiers.control, modifiers.option,
           !modifiers.command, !modifiers.shift {
            return HotkeyResult(events: [.pasteRaw], consume: true)
        }

        // Any other key between taps breaks the double-tap; a key pressed while a
        // hold is still pending (before the debounce) means the combo is not a hold.
        resetTap()
        if holdPending && !holdActive {
            holdPending = false
            holdDownAt = nil
        }
        return HotkeyResult()
    }

    // MARK: - tick

    private mutating func handleTick(at: TimeInterval) -> HotkeyResult {
        if holdPending, !holdActive, let down = holdDownAt, at - down >= holdDebounce {
            holdPending = false
            holdActive = true
            return HotkeyResult(events: [.holdStart])
        }
        return HotkeyResult()
    }

    private mutating func resetTap() {
        firstTapReleaseAt = nil
        firstTapSide = nil
        secondTapStarted = false
    }
}
