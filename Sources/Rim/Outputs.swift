import AppKit
import Carbon.HIToolbox

/// Edge scrolling: turns finger travel along an edge into pixel scroll events for whatever is under the pointer.
/// Fractions of a pixel are carried over (sub-pixel accumulation) so slow, precise slides never lose motion.
enum ScrollOutput {
    /// Test hook: receives (dx, dy) pixels instead of posting real events.
    static var testSink: ((Int32, Int32) -> Void)?

    static let pixelsPerMM = 7.0
    private static var carry = (x: 0.0, y: 0.0)
    private static let lock = NSLock()

    /// macOS "Natural scrolling": content follows the finger.
    static var natural: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }

    static func reset() { lock.lock(); carry = (0, 0); lock.unlock() }

    /// `alongMM`: finger travel since the last frame (+ = up / right). `vertical`: left/right edges scroll vertically.
    static func scroll(alongMM: Double, vertical: Bool, gain: Double) {
        let sign: Double = natural ? 1 : -1
        // Natural: finger up → content up → negative wheel delta (reveals content below).
        let px = -alongMM * pixelsPerMM * gain * sign
        lock.lock()
        var dx = 0.0, dy = 0.0
        if vertical { carry.y += px; dy = carry.y.rounded(.towardZero); carry.y -= dy }
        else { carry.x += -px; dx = carry.x.rounded(.towardZero); carry.x -= dx }   // finger right → content right
        lock.unlock()
        guard dx != 0 || dy != 0 else { return }
        if let sink = testSink { sink(Int32(dx), Int32(dy)); return }
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }
}

/// ⌘-Tab app switcher driven by an edge: ⌘ is held only while the finger is down.
/// Every exit path calls `release()`; it is idempotent, so a stuck ⌘ is impossible from Rim's side.
enum SwitcherHold {
    /// Test hook: receives "cmdDown", "tab", "shiftTab", "cmdUp" instead of posting real keys.
    static var testSink: ((String) -> Void)?

    private static let lock = NSLock()
    private(set) static var holding = false

    static func step(forward: Bool) {
        lock.lock(); let first = !holding; holding = true; lock.unlock()
        if first { emit("cmdDown") { post(kVK_Command, down: true, flags: .maskCommand) } }
        if forward {
            emit("tab") { post(kVK_Tab, down: true, flags: .maskCommand); post(kVK_Tab, down: false, flags: .maskCommand) }
        } else {
            emit("shiftTab") {
                post(kVK_Shift, down: true, flags: [.maskCommand, .maskShift])
                post(kVK_Tab, down: true, flags: [.maskCommand, .maskShift])
                post(kVK_Tab, down: false, flags: [.maskCommand, .maskShift])
                post(kVK_Shift, down: false, flags: .maskCommand)
            }
        }
    }

    /// Lifts ⌘ (commits the selected app). Safe to call any time.
    static func release() {
        lock.lock(); let was = holding; holding = false; lock.unlock()
        if was { emit("cmdUp") { post(kVK_Command, down: false, flags: []) } }
    }

    private static func emit(_ name: String, _ real: () -> Void) {
        if let sink = testSink { sink(name) } else { real() }
    }

    private static func post(_ key: Int, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(key), keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}
