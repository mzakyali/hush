import Foundation
import Testing
@testable import HotkeyService
import HushCore

private let fn = HotkeyStateMachine.fnKeyCode          // 63
private let lOpt = HotkeyStateMachine.leftOptionKeyCode  // 58
private let rOpt = HotkeyStateMachine.rightOptionKeyCode // 61
private let esc = HotkeyStateMachine.escapeKeyCode     // 53
private let zKey = HotkeyStateMachine.zKeyCode         // 6

private func flags(_ keyCode: UInt16, _ down: Bool, at t: TimeInterval, modifiers: HotkeyModifiers = .init()) -> HotkeyInput {
    .flags(keyCode: keyCode, down: down, modifiers: modifiers, at: t)
}

private func key(_ keyCode: UInt16, _ down: Bool, at t: TimeInterval, modifiers: HotkeyModifiers = .init()) -> HotkeyInput {
    .key(keyCode: keyCode, down: down, modifiers: modifiers, at: t)
}

@Test func fnHoldEmitsStartThenEnd() {
    var m = HotkeyStateMachine()
    let down = m.handle(flags(fn, true, at: 0))
    #expect(down.events == [])
    #expect(down.scheduleTickAt == 0.150)

    let tick = m.handle(.tick(at: 0.150))
    #expect(tick.events == [.holdStart])

    let up = m.handle(flags(fn, false, at: 1.0))
    #expect(up.events == [.holdEnd])
}

@Test func fnShortHoldIsIgnored() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(fn, true, at: 0))
    let up = m.handle(flags(fn, false, at: 0.149))
    #expect(up.events == [])
    // A stale tick after the release emits nothing.
    #expect(m.handle(.tick(at: 0.150)).events == [])
}

@Test func fnPlusOtherKeyIsNotAHold() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(fn, true, at: 0))
    _ = m.handle(key(123, true, at: 0.05))  // Fn + right-arrow
    #expect(m.handle(.tick(at: 0.150)).events == [])
    let up = m.handle(flags(fn, false, at: 0.3))
    #expect(up.events == [])
}

@Test func fnWithModifierHeldIsNotAHold() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(55, true, at: 0, modifiers: .init(command: true)))  // cmd down
    let down = m.handle(flags(fn, true, at: 0.05, modifiers: .init(fn: true, command: true)))
    #expect(down.events == [])
    #expect(down.scheduleTickAt == nil)
    #expect(m.handle(.tick(at: 0.2)).events == [])
}

@Test func optionDoubleTapEmitsToggle() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(lOpt, true, at: 0))
    _ = m.handle(flags(lOpt, false, at: 0.08))
    _ = m.handle(flags(lOpt, true, at: 0.20))
    let secondUp = m.handle(flags(lOpt, false, at: 0.28))
    #expect(secondUp.events == [.toggle])
}

@Test func optionDoubleTapAtWindowBoundary() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(lOpt, true, at: 0))
    _ = m.handle(flags(lOpt, false, at: 0.05))
    _ = m.handle(flags(lOpt, true, at: 0.35))
    // Second release exactly 350 ms after the first — inside the window.
    #expect(m.handle(flags(lOpt, false, at: 0.40)).events == [.toggle])

    var m2 = HotkeyStateMachine()
    _ = m2.handle(flags(lOpt, true, at: 0))
    _ = m2.handle(flags(lOpt, false, at: 0.05))
    _ = m2.handle(flags(lOpt, true, at: 0.42))
    // 370 ms after the first release — outside.
    #expect(m2.handle(flags(lOpt, false, at: 0.42)).events == [])
}

@Test func optionSingleTapThenOtherKeyDoesNotToggle() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(lOpt, true, at: 0))
    _ = m.handle(flags(lOpt, false, at: 0.08))
    _ = m.handle(key(8, true, at: 0.15))  // 'c'
    _ = m.handle(key(8, false, at: 0.20))
    _ = m.handle(flags(lOpt, true, at: 0.25))
    let up = m.handle(flags(lOpt, false, at: 0.30))
    #expect(up.events == [])
}

@Test func optionTapsOnDifferentSidesDoNotToggle() {
    var m = HotkeyStateMachine()
    _ = m.handle(flags(lOpt, true, at: 0))
    _ = m.handle(flags(lOpt, false, at: 0.08))
    _ = m.handle(flags(rOpt, true, at: 0.15))
    #expect(m.handle(flags(rOpt, false, at: 0.22)).events == [])
}

@Test func escIgnoredWhenIdleConsumedWhenRecording() {
    var m = HotkeyStateMachine()
    let idle = m.handle(key(esc, true, at: 0))
    #expect(idle.events == [])
    #expect(idle.consume == false)

    m.setRecording(true)
    let active = m.handle(key(esc, true, at: 0.1))
    #expect(active.events == [.cancel])
    #expect(active.consume == true)
}

@Test func ctrlOptionZIsPasteRaw() {
    var m = HotkeyStateMachine()
    let r = m.handle(key(zKey, true, at: 0, modifiers: .init(control: true, option: true)))
    #expect(r.events == [.pasteRaw])
    #expect(r.consume == true)
}

@Test func ctrlOptionShiftZIsNotPasteRaw() {
    var m = HotkeyStateMachine()
    let r = m.handle(key(zKey, true, at: 0, modifiers: .init(control: true, option: true, shift: true)))
    #expect(r.events == [])
    #expect(r.consume == false)
}

@Test func rightOptionHoldFallback() {
    var m = HotkeyStateMachine(holdKey: .rightOption)
    let down = m.handle(flags(rOpt, true, at: 0))
    #expect(down.scheduleTickAt == 0.150)
    #expect(m.handle(.tick(at: 0.150)).events == [.holdStart])
    #expect(m.handle(flags(rOpt, false, at: 0.6)).events == [.holdEnd])

    // Fn is inert in this mode.
    _ = m.handle(flags(fn, true, at: 1.0))
    #expect(m.handle(.tick(at: 1.15)).events == [])
    #expect(m.handle(flags(fn, false, at: 1.2)).events == [])
}

@Test func leftOptionStillTogglesWhenRightOptionIsHold() {
    var m = HotkeyStateMachine(holdKey: .rightOption)
    _ = m.handle(flags(lOpt, true, at: 0))
    _ = m.handle(flags(lOpt, false, at: 0.08))
    _ = m.handle(flags(lOpt, true, at: 0.20))
    #expect(m.handle(flags(lOpt, false, at: 0.28)).events == [.toggle])
}

@Test func tickWithoutPendingHoldIsNoop() {
    var m = HotkeyStateMachine()
    #expect(m.handle(.tick(at: 10)).events == [])
}
