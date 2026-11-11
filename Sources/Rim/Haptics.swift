import AppKit
import CMT

/// What happened, so each event can have its own feel.
enum Haptic { case tick, bump, confirm, doubleTap, media, gesture, tipTap }

/// Named feedback patterns: timed sequences of actuator pulses at light / medium / strong strength.
enum HapticPattern: String, CaseIterable, Identifiable {
    case none, tick, light, medium, strong, double, triple, ramp, success, warning, error, heartbeat
    var id: String { rawValue }

    enum Level { case light, medium, strong }

    var title: String {
        switch self {
        case .none: return "None"
        case .tick: return "Tick"
        case .light: return "Light tap"
        case .medium: return "Medium tap"
        case .strong: return "Strong tap"
        case .double: return "Double"
        case .triple: return "Triple"
        case .ramp: return "Ramp up"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        case .heartbeat: return "Heartbeat"
        }
    }

    /// (delay in seconds, strength)
    var steps: [(Double, Level)] {
        switch self {
        case .none: return []
        case .tick, .light: return [(0, .light)]
        case .medium: return [(0, .medium)]
        case .strong: return [(0, .strong)]
        case .double: return [(0, .medium), (0.085, .medium)]
        case .triple: return [(0, .light), (0.07, .light), (0.14, .light)]
        case .ramp: return [(0, .light), (0.06, .medium), (0.12, .strong)]
        case .success: return [(0, .light), (0.09, .strong)]
        case .warning: return [(0, .strong), (0.16, .strong)]
        case .error: return [(0, .strong), (0.07, .strong), (0.14, .strong), (0.21, .strong)]
        case .heartbeat: return [(0, .medium), (0.13, .light), (0.62, .medium), (0.75, .light)]
        }
    }
}

enum Haptics {
    private(set) static var forceTouchAvailable = false
    private static let queue = DispatchQueue(label: "Rim.haptics", qos: .userInteractive)

    static func setup() { forceTouchAvailable = tf_haptic_open() }

    /// Test hook: receives the system pattern name ("alignment", "levelChange", "generic") instead of playing.
    static var testSink: ((String) -> Void)?

    private static let tickLock = NSLock()
    private static var lastTick = 0.0
    /// Fast slides and momentum would otherwise buzz: at most one tick per 25 ms.
    static let minTickInterval = 0.025

    /// Event feedback. Apple style uses macOS's system haptics the way Apple apps do:
    /// light "alignment" ticks for steps, one firmer "level change" for ends and holds, one "generic" click to
    /// confirm an action; never multi-pulse for frequent events. Custom style plays the chosen patterns.
    static func play(_ h: Haptic) {
        let cfg = ConfigStore.shared.current
        guard cfg.haptics else { return }
        let s = cfg.hapticSettings
        if s.style == "apple" {
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch h {
            case .tick, .tipTap: pattern = .alignment
            case .bump, .doubleTap: pattern = .levelChange
            case .confirm, .media, .gesture: pattern = .generic
            }
            if pattern == .alignment {
                let now = ProcessInfo.processInfo.systemUptime
                tickLock.lock()
                let ok = now - lastTick >= minTickInterval
                if ok { lastTick = now }
                tickLock.unlock()
                guard ok else { return }
            }
            system(pattern)
            return
        }
        let name: String
        switch h {
        case .tick: name = s.sliderStep
        case .bump: name = s.sliderEnd
        case .confirm: name = s.cornerTap
        case .doubleTap: name = s.cornerDoubleTap
        case .media: name = s.media   // edge taps and one-shot edge swipes
        case .gesture: name = s.gesture
        case .tipTap: name = s.tipTap
        }
        play(HapticPattern(rawValue: name) ?? .medium, settings: s)
    }

    /// Plays a pattern regardless of the global toggle (tests, alerts from scripts).
    static func play(_ p: HapticPattern, settings: Config.HapticSettings = ConfigStore.shared.current.hapticSettings) {
        for (delay, level) in p.steps {
            let id: Int32 = level == .light ? settings.light : level == .medium ? settings.medium : settings.strong
            if delay == 0 { pulse(id, level) } else { queue.asyncAfter(deadline: .now() + delay) { pulse(id, level) } }
        }
    }

    static func system(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        if let sink = testSink {
            sink(pattern == .alignment ? "alignment" : pattern == .levelChange ? "levelChange" : "generic")
            return
        }
        DispatchQueue.main.async { NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now) }
    }

    static func pulse(_ id: Int32, _ level: HapticPattern.Level = .medium) {
        if forceTouchAvailable, tf_haptic_actuate(id) { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(level == .light ? .alignment : .levelChange, performanceTime: .now)
        }
    }

    /// Raw actuator ids worth trying (strength differs per Mac).
    static let actuatorIDs: [Int32] = [1, 2, 3, 4, 5, 6, 15, 16]
}
