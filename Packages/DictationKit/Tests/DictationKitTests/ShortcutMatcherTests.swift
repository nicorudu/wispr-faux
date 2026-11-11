import CoreGraphics
import Testing
import HotkeyKit

private let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
private let rightOptionFlags = CGEventFlags.maskAlternate.rawValue | 0x40
private let leftOptionFlags = CGEventFlags.maskAlternate.rawValue | 0x20

private func fn(_ down: Bool) -> KeyInput {
    KeyInput(kind: .flagsChanged, keyCode: KeyCode.function, flags: down ? fnFlag : 0)
}

private func keyDown(_ code: CGKeyCode, repeat: Bool = false) -> KeyInput {
    KeyInput(kind: .keyDown, keyCode: code, isAutorepeat: `repeat`)
}

private func keyUp(_ code: CGKeyCode) -> KeyInput {
    KeyInput(kind: .keyUp, keyCode: code)
}

private let controlFlag = CGEventFlags.maskControl.rawValue

/// Left Control, the only Control key on MacBook keyboards.
private func control(_ down: Bool) -> KeyInput {
    KeyInput(kind: .flagsChanged, keyCode: KeyCode.leftControl, flags: down ? controlFlag | 0x1 : 0)
}

private let mouseDown = KeyInput(kind: .mouseDown, keyCode: 0)

private let letterA: CGKeyCode = 0
private let letterC: CGKeyCode = 8
private let delete: CGKeyCode = 51

@Suite("ShortcutMatcher")
struct ShortcutMatcherTests {
    @Test func holdAndReleaseFn() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        #expect(matcher.handle(fn(true)) == .init(swallow: true, events: [.pushToTalkPressed]))
        #expect(matcher.phase == .holding)
        #expect(matcher.handle(fn(false)) == .init(swallow: true, events: [.pushToTalkReleased]))
        #expect(matcher.phase == .idle)
    }

    @Test func ordinaryTypingPassesThroughWhenIdle() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        for input in [keyDown(letterA), keyUp(letterA), keyDown(KeyCode.space), keyUp(KeyCode.space),
                      keyDown(KeyCode.escape), keyUp(KeyCode.escape)] {
            #expect(matcher.handle(input) == .pass)
        }
    }

    @Test func fnIsIgnoredWhenNotATrigger() {
        var matcher = ShortcutMatcher(triggers: [.rightOption])
        #expect(matcher.handle(fn(true)) == .pass)
        #expect(matcher.phase == .idle)
    }

    @Test func handsFreeLockAndStop() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        _ = matcher.handle(fn(true))
        #expect(matcher.handle(keyDown(KeyCode.space)) == .init(swallow: true, events: [.handsFreeToggled]))
        #expect(matcher.handle(keyDown(KeyCode.space, repeat: true)) == .init(swallow: true))
        #expect(matcher.handle(keyUp(KeyCode.space)) == .init(swallow: true))

        // Releasing the trigger keeps recording.
        #expect(matcher.handle(fn(false)) == .init(swallow: true))
        #expect(matcher.phase == .handsFree)

        // Typing during hands-free is left alone.
        #expect(matcher.handle(keyDown(letterA)) == .pass)

        // The next press stops; its release does nothing.
        #expect(matcher.handle(fn(true)) == .init(swallow: true, events: [.pushToTalkReleased]))
        #expect(matcher.handle(fn(false)) == .init(swallow: true))
        #expect(matcher.phase == .idle)
    }

    @Test func escapeCancelsAndIsSwallowed() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        _ = matcher.handle(fn(true))
        #expect(matcher.handle(keyDown(KeyCode.escape)) == .init(swallow: true, events: [.cancel]))
        #expect(matcher.handle(keyUp(KeyCode.escape)) == .init(swallow: true))
        // The release after a cancel is not a second event.
        #expect(matcher.handle(fn(false)) == .init(swallow: true))
        #expect(matcher.phase == .idle)
    }

    @Test func escapeCancelsHandsFree() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        _ = matcher.handle(fn(true))
        _ = matcher.handle(keyDown(KeyCode.space))
        _ = matcher.handle(fn(false))
        #expect(matcher.handle(keyDown(KeyCode.escape)) == .init(swallow: true, events: [.cancel]))
        #expect(matcher.phase == .idle)
    }

    @Test func triggerUsedAsModifierCancels() {
        var matcher = ShortcutMatcher(triggers: [.fn])

        _ = matcher.handle(fn(true))
        // Fn+Delete is forward delete: the key must still reach the app.
        #expect(matcher.handle(keyDown(delete)) == .init(swallow: false, events: [.cancel]))
        #expect(matcher.handle(keyUp(delete)) == .pass)
        #expect(matcher.handle(fn(false)) == .init(swallow: true))
    }

    @Test func rightOptionPassesThroughAndIgnoresLeftOption() {
        var matcher = ShortcutMatcher(triggers: [.rightOption])
        let rightDown = KeyInput(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: rightOptionFlags)
        let rightUp = KeyInput(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: 0)
        let leftDown = KeyInput(kind: .flagsChanged, keyCode: 58, flags: leftOptionFlags)

        #expect(matcher.handle(leftDown) == .pass)
        #expect(matcher.phase == .idle)

        #expect(matcher.handle(rightDown) == .init(swallow: false, events: [.pushToTalkPressed]))
        #expect(matcher.handle(rightUp) == .init(swallow: false, events: [.pushToTalkReleased]))
    }

    @Test func secondTriggerWhileHoldingIsIgnored() {
        var matcher = ShortcutMatcher(triggers: [.fn, .rightOption])
        let rightDown = KeyInput(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: rightOptionFlags | fnFlag)
        let rightUp = KeyInput(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: fnFlag)

        _ = matcher.handle(fn(true))
        #expect(matcher.handle(rightDown) == .init(swallow: false))
        #expect(matcher.handle(rightUp) == .init(swallow: false))
        #expect(matcher.phase == .holding)
        #expect(matcher.handle(fn(false)).events == [.pushToTalkReleased])
    }

    @Test func globeKeyCodeIsSwallowedOnlyForFn() {
        var fnMatcher = ShortcutMatcher(triggers: [.fn])
        _ = fnMatcher.handle(fn(true))
        #expect(fnMatcher.handle(keyDown(KeyCode.globe)) == .init(swallow: true))
        #expect(fnMatcher.handle(keyUp(KeyCode.globe)) == .init(swallow: true))
        #expect(fnMatcher.phase == .holding)

        var optionMatcher = ShortcutMatcher(triggers: [.rightOption])
        #expect(optionMatcher.handle(keyDown(KeyCode.globe)) == .pass)
    }

    @Test func resyncReleasesAMissedKeyUp() {
        var matcher = ShortcutMatcher(triggers: [.fn])
        _ = matcher.handle(fn(true))

        #expect(matcher.resync(currentFlags: fnFlag).isEmpty)
        #expect(matcher.phase == .holding)

        #expect(matcher.resync(currentFlags: 0) == [.pushToTalkReleased])
        #expect(matcher.phase == .idle)
        #expect(matcher.heldTrigger == nil)
    }

    @Test func resyncKeepsHandsFreeRunning() {
        var matcher = ShortcutMatcher(triggers: [.fn])
        _ = matcher.handle(fn(true))
        _ = matcher.handle(keyDown(KeyCode.space))

        #expect(matcher.resync(currentFlags: 0).isEmpty)
        #expect(matcher.phase == .handsFree)
    }

    @Test func removingTheHeldTriggerCancels() {
        var matcher = ShortcutMatcher(triggers: [.fn, .rightOption])
        _ = matcher.handle(fn(true))

        #expect(matcher.setTriggers([.rightOption]) == [.cancel])
        #expect(matcher.phase == .idle)
        #expect(matcher.setTriggers([.fn]).isEmpty)
    }

    // MARK: Control (the default)

    @Test func defaultIsEitherControlKey() {
        #expect(HotkeyTrigger.defaultTriggers == [.leftControl, .rightControl])
    }

    @Test func controlHoldIsNotSwallowed() {
        var matcher = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)

        #expect(matcher.handle(control(true)) == .init(swallow: false, events: [.pushToTalkPressed]))
        #expect(matcher.handle(control(false)) == .init(swallow: false, events: [.pushToTalkReleased]))
    }

    @Test func rightControlIsToldApartFromLeft() {
        var leftOnly = ShortcutMatcher(triggers: [.leftControl])
        let rightDown = KeyInput(kind: .flagsChanged, keyCode: KeyCode.rightControl, flags: controlFlag | 0x2000)
        #expect(leftOnly.handle(rightDown) == .pass)

        var both = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)
        #expect(both.handle(rightDown).events == [.pushToTalkPressed])
    }

    @Test func controlShortcutCancelsAndPassesThrough() {
        var matcher = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)

        _ = matcher.handle(control(true))
        #expect(matcher.handle(keyDown(letterC)) == .init(swallow: false, events: [.cancel]))
        #expect(matcher.handle(keyUp(letterC)) == .pass)
        #expect(matcher.handle(control(false)) == .init(swallow: false))
    }

    @Test func controlSpaceLocksHandsFree() {
        var matcher = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)

        _ = matcher.handle(control(true))
        #expect(matcher.handle(keyDown(KeyCode.space)) == .init(swallow: true, events: [.handsFreeToggled]))
        _ = matcher.handle(control(false))
        #expect(matcher.phase == .handsFree)
    }

    @Test func ctrlClickCancels() {
        var matcher = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)

        _ = matcher.handle(control(true))
        #expect(matcher.handle(mouseDown) == .init(swallow: false, events: [.cancel]))
        #expect(matcher.handle(control(false)) == .init(swallow: false))
        #expect(matcher.phase == .idle)
    }

    @Test func clicksOutsideAHoldAreIgnored() {
        var matcher = ShortcutMatcher(triggers: HotkeyTrigger.defaultTriggers)
        #expect(matcher.handle(mouseDown) == .pass)

        _ = matcher.handle(control(true))
        _ = matcher.handle(keyDown(KeyCode.space))
        _ = matcher.handle(control(false))
        // Clicking into a field during hands-free keeps listening.
        #expect(matcher.handle(mouseDown) == .pass)
        #expect(matcher.phase == .handsFree)
    }

    @Test func staleSwallowedKeyIsForgotten() {
        var matcher = ShortcutMatcher(triggers: [.fn])
        _ = matcher.handle(fn(true))
        _ = matcher.handle(keyDown(KeyCode.space)) // key-up never arrives
        _ = matcher.handle(fn(false))
        _ = matcher.handle(fn(true))               // ends hands-free
        _ = matcher.handle(fn(false))

        // A fresh Space press and its key-up belong to the app.
        #expect(matcher.handle(keyDown(KeyCode.space)) == .pass)
        #expect(matcher.handle(keyUp(KeyCode.space)) == .pass)
    }
}
