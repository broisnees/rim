import AppKit
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio
import CMT

// MARK: - Volume (CoreAudio)

enum Volume {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    static func get() -> Float? {
        guard let dev = device() else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return isMuted(dev) ? 0 : v
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let dev = device() else { return false }
        var v = Float32(value)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return false }
        setMuted(dev, value <= 0.001)
        return true
    }

    private static func isMuted(_ dev: AudioDeviceID) -> Bool {
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    private static func setMuted(_ dev: AudioDeviceID, _ muted: Bool) {
        guard isMuted(dev) != muted else { return }
        var m = UInt32(muted ? 1 : 0)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}

// MARK: - Brightness

enum Brightness {
    static func get() -> Float? {
        var v: Float = 0
        return tf_brightness_get(&v) ? v : nil
    }
    @discardableResult
    static func set(_ v: Float) -> Bool { tf_brightness_set(v) }
}

// MARK: - Keyboard backlight (CoreBrightness, private)

enum KeyboardLight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: NSObject? = {
        guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static var keyboardID: UInt64? {
        guard let c = client,
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }

    private static var lastOn: Float = 0.6

    static func get() -> Float? {
        guard let c = client, let id = keyboardID else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard c.responds(to: sel) else { return nil }
        return unsafeBitCast(c.method(for: sel), to: GetFn.self)(c, sel, id)
    }

    @discardableResult
    static func set(_ v: Float) -> Bool {
        guard let c = client, let id = keyboardID else { return false }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard c.responds(to: sel) else { return false }
        if v > 0.01 { lastOn = v }
        return unsafeBitCast(c.method(for: sel), to: SetFn.self)(c, sel, min(1, max(0, v)), id)
    }

    static func toggle() {
        guard let v = get() else { return }
        set(v > 0.01 ? 0 : lastOn)
    }
}

// MARK: - Stepped controls (actions)

/// One-step changes for buttons, corners and edge actions: 1/16 like the system keys, with the level HUD.
enum StepControl {
    static func step(_ kind: SliderController.Kind, by delta: Float) {
        let current: Float? = kind == .volume ? Volume.get() : kind == .brightness ? Brightness.get() : KeyboardLight.get()
        guard let v = current else {
            if kind == .volume { postMediaKey(delta > 0 ? .soundUp : .soundDown) }
            return
        }
        let steps: Float = 16
        let next = min(1, max(0, ((v * steps).rounded() + (delta > 0 ? 1 : -1)) / steps))
        switch kind {
        case .volume: Volume.set(next)
        case .brightness: Brightness.set(next)
        case .keyboard: KeyboardLight.set(next)
        }
        HUD.shared.slider(kind, value: Double(next), overshoot: 0)
        HUD.shared.releaseSlider()
    }
}

// MARK: - Edge slider

/// Maps filtered finger travel to a 0…1 value through the acceleration curve, counts 16 detents
/// for haptics, and tracks overshoot past the ends for the rubber-band visual.
final class SliderController {
    static let shared = SliderController()
    enum Kind: String { case volume, brightness, keyboard }

    private let lock = NSLock()
    private var kind: Kind?
    private var value = 0.0
    private var overshoot = 0.0          // value units beyond 0 / 1
    private var applied = -1.0
    private var detents = Detents(count: 16)
    private var keyFallback = false

    func begin(_ k: Kind) {
        lock.lock(); defer { lock.unlock() }
        kind = k
        let current = k == .volume ? Volume.get() : k == .brightness ? Brightness.get() : KeyboardLight.get()
        keyFallback = (k == .volume && current == nil)
        value = Double(current ?? 0.5)
        applied = value
        overshoot = 0
        detents.reset(value)
        if !keyFallback { HUD.shared.slider(k, value: value, overshoot: 0) }
    }

    func drag(deltaMM: Double, speed: Double, time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let kind, deltaMM != 0 else { return }
        let e = ConfigStore.shared.current.edges
        let delta = deltaMM * Acceleration.gain(speed: speed, amount: e.acceleration) * e.speed

        let before = value
        let raw = value + overshoot + delta            // moving back in consumes overshoot first
        value = min(1, max(0, raw))
        overshoot = max(-0.5, min(0.5, raw - value))

        if !keyFallback, abs(value - applied) > 0.0005 || (value != applied && (value == 0 || value == 1)) {
            let ok: Bool
            switch kind {
            case .volume: ok = Volume.set(Float(value))
            case .brightness: ok = Brightness.set(Float(value))
            case .keyboard: ok = KeyboardLight.set(Float(value))
            }
            if ok { applied = value } else if kind == .volume { keyFallback = true }
        }

        let hitEnd = value != before && (value == 0 || value == 1)
        let tick = detents.update(value, time: time)
        if hitEnd {
            Haptics.play(.bump)                         // the end stop feels different from a step
        } else if tick {
            Haptics.play(.tick)
        }
        if keyFallback, tick || hitEnd { postMediaKey(delta > 0 ? .soundUp : .soundDown) }
        if !keyFallback { HUD.shared.slider(kind, value: value, overshoot: overshoot) }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard kind != nil else { return }
        kind = nil
        overshoot = 0
        HUD.shared.releaseSlider()
    }
}

// MARK: - Synthetic input

enum MediaKey: Int { case soundUp = 0, soundDown = 1, mute = 7, play = 16, next = 17, previous = 18 }

func postMediaKey(_ key: MediaKey) {
    for down in [true, false] {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (key.rawValue << 16) | ((down ? 0xa : 0xb) << 8)
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
            .cgEvent?.post(tap: .cghidEventTap)
    }
}

/// Posts a key combo like "cmd+shift+5" or "ctrl+up". Returns false if the key name is unknown.
@discardableResult
func postKeys(_ combo: String) -> Bool {
    var flags: CGEventFlags = []
    var key: Int?
    for raw in combo.lowercased().split(separator: "+") {
        let part = raw.trimmingCharacters(in: .whitespaces)
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: key = keyCodes[part]
        }
    }
    guard let key else { return false }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
    return true
}

let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
    ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
    "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "esc": kVK_Escape,
    "escape": kVK_Escape, "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
    "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]
