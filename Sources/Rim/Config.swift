import Foundation

/// An action bound to a zone. `type` is an id from `ActionCatalog`; some types take a `value`
/// (app name, Shortcut name, key combo, URL, shell command).
struct Action: Codable, Equatable, Hashable {
    var type: String
    var value: String?
    init(_ type: String, _ value: String? = nil) { self.type = type; self.value = value }
    var isNone: Bool { type == "none" }
    static let none = Action("none")
}

/// What a corner does on a single tap and on a double tap.
/// With a double-tap action set, the single tap waits `doubleTapWindow` to see if a second tap follows.
struct CornerBinding: Codable, Equatable {
    var tap: Action
    var doubleTap: Action = .none
    var hold: Action = .none
    init(_ tap: Action, doubleTap: Action = .none, hold: Action = .none) { self.tap = tap; self.doubleTap = doubleTap; self.hold = hold }
    var isNone: Bool { tap.isNone && doubleTap.isNone && hold.isNone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tap = try c.decodeIfPresent(Action.self, forKey: .tap) ?? .none
        doubleTap = try c.decodeIfPresent(Action.self, forKey: .doubleTap) ?? .none
        hold = try c.decodeIfPresent(Action.self, forKey: .hold) ?? .none
    }
}

enum Edge: String, CaseIterable, Codable {
    case left, right, top, bottom
    var vertical: Bool { self == .left || self == .right }
    var title: String { rawValue.capitalized + " Edge" }
}

/// What an edge does. `slide`: "volume" | "brightness" | "keyboard" (levels) | "scroll" | "appSwitcher" |
/// "actions" (forward/backward) | "none".
/// Forward = slide up (left/right edges) or right (top/bottom edges).
struct EdgeBinding: Codable, Equatable {
    var slide = "none"
    var forward: Action = .none
    var backward: Action = .none
    var repeats = true           // actions mode: fire every `stepMM` while sliding, or once per swipe
    var stepMM = 12.0
    var tap: Action = .none
    var doubleTap: Action = .none
    var hold: Action = .none

    init(slide: String = "none", forward: Action = .none, backward: Action = .none, repeats: Bool = true,
         stepMM: Double = 12, tap: Action = .none, doubleTap: Action = .none, hold: Action = .none) {
        self.slide = slide; self.forward = forward; self.backward = backward
        self.repeats = repeats; self.stepMM = stepMM; self.tap = tap; self.doubleTap = doubleTap; self.hold = hold
    }

    /// Any tap-like gesture set (tap, double-tap, hold): clicks are captured from touch-down.
    var touches: Bool { !tap.isNone || !doubleTap.isNone || !hold.isNone }

    /// A level control (volume, brightness, keyboard light) driven by the slider.
    var continuous: Bool { slide == "volume" || slide == "brightness" || slide == "keyboard" }
    var isScroll: Bool { slide == "scroll" }
    var isSwitcher: Bool { slide == "appSwitcher" }
    var slides: Bool { continuous || isScroll || isSwitcher || (slide == "actions" && !(forward.isNone && backward.isNone)) }
    var isNone: Bool { !slides && !touches }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slide = try c.decodeIfPresent(String.self, forKey: .slide) ?? "none"
        forward = try c.decodeIfPresent(Action.self, forKey: .forward) ?? .none
        backward = try c.decodeIfPresent(Action.self, forKey: .backward) ?? .none
        repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? true
        stepMM = try c.decodeIfPresent(Double.self, forKey: .stepMM) ?? 12
        tap = try c.decodeIfPresent(Action.self, forKey: .tap) ?? .none
        doubleTap = try c.decodeIfPresent(Action.self, forKey: .doubleTap) ?? .none
        hold = try c.decodeIfPresent(Action.self, forKey: .hold) ?? .none
    }
}

enum Corner: String, CaseIterable, Codable { case topLeft, topRight, bottomLeft, bottomRight }

struct Config: Codable, Equatable {
    struct Edges: Codable, Equatable {
        var enabled = true
        var width: Float = 0.08          // left / right edge thickness, fraction of trackpad width
        var height: Float = 0.15         // top / bottom edge thickness, fraction of trackpad height (~11.5 mm)
        var speed = 1.0                  // multiplier on the volume / brightness transfer function
        var acceleration = 1.0           // 0 = linear, 1 = full speed-dependent acceleration
        var momentum = true              // repeating edge actions keep going after a flick, slowing with drag
        var repeatSpeedup = true         // quick consecutive slides in one direction go progressively further
        var left = EdgeBinding(slide: "brightness")
        var right = EdgeBinding(slide: "volume")
        var top = EdgeBinding()
        var bottom = EdgeBinding(slide: "actions", forward: Action("nextTrack"), backward: Action("previousTrack"),
                                 repeats: false, stepMM: 18, tap: Action("playPause"))

        func binding(_ e: Edge) -> EdgeBinding {
            switch e { case .left: return left; case .right: return right; case .top: return top; case .bottom: return bottom }
        }
        mutating func setBinding(_ b: EdgeBinding, for e: Edge) {
            switch e { case .left: left = b; case .right: right = b; case .top: top = b; case .bottom: bottom = b }
        }
    }
    struct Corners: Codable, Equatable {
        var enabled = true
        var width: Float = 0.12
        var height: Float = 0.17
        var doubleTapWindow = 0.3        // s between the first lift and the second touch
        var holdTime = 0.5               // s a still finger needs for press & hold
        var topLeft = CornerBinding(Action("missionControl"))
        var topRight = CornerBinding(Action("showDesktop"))
        var bottomLeft = CornerBinding(Action("screenshot"))
        var bottomRight = CornerBinding(Action("spotlight"), doubleTap: Action("toggleSidebar"))
    }
    /// Accidental-touch rejection. With `adaptive`, learned values replace these once enough data exists.
    struct Guard: Codable, Equatable {
        var adaptive = true
        var typingPause = 0.5            // s after a keystroke during which no zone gesture can start
        var palmSize: Float = 1.6        // contacts larger than this (MT size units) are palms / thumbs
        var multiFingerCooldown = 0.4    // s after a multi-finger touch (a resting hand) ends
        var activationWindow = 0.6       // s after touch-down within which a slider must engage
        var minTap = 0.03                // s; shorter contacts are grazes
        var maxTap = 0.28                // s; longer contacts are rests, not taps
        var tapSlop = 2.0                // mm a tap may move
    }
    /// Multi-finger and two-hand gestures (taps only, so they never collide with system swipes).
    struct Gestures: Codable, Equatable {
        var enabled = true
        var threeFingerTap = Action("middleClick")
        var fourFingerTap = Action("previousApp")
        var fiveFingerTap = Action.none
        var tipTapLeft = Action.none
        var tipTapRight = Action.none
        var twoHandTap = Action("missionControl")
        var tipSwipeLeft = Action.none
        var tipSwipeRight = Action.none
        var tipSwipeUp = Action.none
        var tipSwipeDown = Action.none
        var tipSwipeStepMM = 10.0
        var twoFingerSwipeLeft = Action.none
        var twoFingerSwipeRight = Action.none

        static let names = ["threeFingerTap", "fourFingerTap", "fiveFingerTap", "tipTapLeft", "tipTapRight", "twoHandTap",
                            "tipSwipeLeft", "tipSwipeRight", "tipSwipeUp", "tipSwipeDown",
                            "twoFingerSwipeLeft", "twoFingerSwipeRight"]

        func action(_ name: String) -> Action {
            switch name {
            case "threeFingerTap": return threeFingerTap
            case "fourFingerTap": return fourFingerTap
            case "fiveFingerTap": return fiveFingerTap
            case "tipTapLeft": return tipTapLeft
            case "tipTapRight": return tipTapRight
            case "twoHandTap": return twoHandTap
            case "tipSwipeLeft": return tipSwipeLeft
            case "tipSwipeRight": return tipSwipeRight
            case "tipSwipeUp": return tipSwipeUp
            case "tipSwipeDown": return tipSwipeDown
            case "twoFingerSwipeLeft": return twoFingerSwipeLeft
            case "twoFingerSwipeRight": return twoFingerSwipeRight
            default: return .none
            }
        }

        mutating func set(_ name: String, _ a: Action) {
            switch name {
            case "threeFingerTap": threeFingerTap = a
            case "fourFingerTap": fourFingerTap = a
            case "fiveFingerTap": fiveFingerTap = a
            case "tipTapLeft": tipTapLeft = a
            case "tipTapRight": tipTapRight = a
            case "twoHandTap": twoHandTap = a
            case "tipSwipeLeft": tipSwipeLeft = a
            case "tipSwipeRight": tipSwipeRight = a
            case "tipSwipeUp": tipSwipeUp = a
            case "tipSwipeDown": tipSwipeDown = a
            case "twoFingerSwipeLeft": twoFingerSwipeLeft = a
            case "twoFingerSwipeRight": twoFingerSwipeRight = a
            default: break
            }
        }
    }
    /// Force Touch feedback: three strength levels (actuator ids) and a pattern per event.
    struct HapticSettings: Codable, Equatable {
        /// "apple": macOS's own system haptics with Apple's rules (default). "custom": the patterns below.
        var style = "apple"
        var light: Int32 = 3
        var medium: Int32 = 4
        var strong: Int32 = 6
        var sliderStep = "tick"
        var sliderEnd = "strong"
        var cornerTap = "medium"
        var cornerDoubleTap = "double"
        var media = "medium"
        var gesture = "success"
        var tipTap = "light"
    }
    /// Per-app overrides, keyed by bundle identifier. `nil` toggles inherit the global setting.
    struct AppRule: Codable, Equatable {
        var name = ""
        var disabled = false
        var edges: Bool?
        var corners: Bool?
        var cornerOverrides: [String: CornerBinding] = [:]   // Corner.rawValue -> binding
        var gestureOverrides: [String: Action] = [:]         // Gestures.names -> action
        var edgeOverrides: [String: EdgeBinding] = [:]       // Edge.rawValue -> binding

        init(name: String) { self.name = name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            edges = try c.decodeIfPresent(Bool.self, forKey: .edges)
            corners = try c.decodeIfPresent(Bool.self, forKey: .corners)
            cornerOverrides = try c.decodeIfPresent([String: CornerBinding].self, forKey: .cornerOverrides) ?? [:]
            gestureOverrides = try c.decodeIfPresent([String: Action].self, forKey: .gestureOverrides) ?? [:]
            edgeOverrides = try c.decodeIfPresent([String: EdgeBinding].self, forKey: .edgeOverrides) ?? [:]
        }
    }

    var enabled = true
    var onboarded = false
    var haptics = true
    var hud = true
    var debug = false
    var invertY = false
    var edges = Edges()
    var corners = Corners()
    var hapticSettings = HapticSettings()
    var gestures = Gestures()
    var guardrails = Guard()
    var apps: [String: AppRule] = [:]
    /// Per-app key overrides for smart actions: bundle id -> action type -> key combo.
    var smartKeys: [String: [String: String]] = [:]
    /// Set once the user moves the top/bottom height slider themselves; until then Rim may raise the default.
    var edgeHeightCustomized = false
}

extension Config.Corners {
    func binding(_ c: Corner) -> CornerBinding {
        switch c {
        case .topLeft: return topLeft
        case .topRight: return topRight
        case .bottomLeft: return bottomLeft
        case .bottomRight: return bottomRight
        }
    }

    mutating func setBinding(_ b: CornerBinding, for c: Corner) {
        switch c {
        case .topLeft: topLeft = b
        case .topRight: topRight = b
        case .bottomLeft: bottomLeft = b
        case .bottomRight: bottomRight = b
        }
    }
}

extension Config {
    /// Smallest zones a fingertip can reliably start in (~8.5 mm on a 125 × 77 mm trackpad).
    static let minEdgeWidth: Float = 0.07, minEdgeHeight: Float = 0.12
    static let minCornerWidth: Float = 0.07, minCornerHeight: Float = 0.11

    func normalized() -> Config {
        var c = self
        c.edges.width = max(c.edges.width, Self.minEdgeWidth)
        c.edges.height = max(c.edges.height, Self.minEdgeHeight)
        // Swipes measured on real hands start up to ~11 mm from the frame.
        if c.edges.height < 0.15 && !c.edgeHeightCustomized { c.edges.height = 0.15 }
        c.corners.width = max(c.corners.width, Self.minCornerWidth)
        c.corners.height = max(c.corners.height, Self.minCornerHeight)
        c.guardrails.multiFingerCooldown = max(c.guardrails.multiFingerCooldown, 0.4)
        return c
    }

    /// The configuration that applies while `bundleID` is frontmost.
    func resolved(for bundleID: String?) -> Config {
        guard let id = bundleID, let rule = apps[id] else { return self }
        var c = self
        if rule.disabled { c.enabled = false; return c }
        if let v = rule.edges { c.edges.enabled = v }
        if let v = rule.corners { c.corners.enabled = v }
        for (key, binding) in rule.cornerOverrides {
            if let corner = Corner(rawValue: key) { c.corners.setBinding(binding, for: corner) }
        }
        for (name, action) in rule.gestureOverrides { c.gestures.set(name, action) }
        for (key, binding) in rule.edgeOverrides {
            if let e = Edge(rawValue: key) { c.edges.setBinding(binding, for: e) }
        }
        return c
    }
}

/// Thread-safe config holder backed by ~/Library/Application Support/Rim/config.json.
/// Missing keys in the user's file fall back to defaults (deep merge).
final class ConfigStore {
    static let shared = ConfigStore()

    let url: URL
    private let lock = NSLock()
    private var _current = Config()
    private var mtime: Date?
    private(set) var lastError: String?

    var current: Config { lock.lock(); defer { lock.unlock() }; return _current }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rim", isDirectory: true)
        url = dir.appendingPathComponent("config.json")
    }

    func load() {
        Self.migrateFromTrackFix(to: url.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: url.path) else { save(Config()); return }
        do {
            let data = try Data(contentsOf: url)
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))
            var user = try JSONSerialization.jsonObject(with: data)
            let migrated = Self.migrate(&user)
            let merged = try JSONSerialization.data(withJSONObject: Self.merge(defaults, user))
            let decoded = try JSONDecoder().decode(Config.self, from: merged)
            let cfg = decoded.normalized()
            lock.lock(); _current = cfg; lock.unlock()
            lastError = nil
            if migrated || cfg != decoded { save(cfg) }
            NotificationCenter.default.post(name: .configChanged, object: nil)
        } catch {
            lastError = "config.json: \(error.localizedDescription)"
            NSLog("Rim: \(lastError!)")
        }
        mtime = modDate()
    }

    func save(_ cfg: Config) {
        lock.lock(); _current = cfg; lock.unlock()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: url, options: .atomic) }
        mtime = modDate()
    }

    /// Tests: swap the in-memory config without touching the file on disk.
    func setForTesting(_ cfg: Config) { lock.lock(); _current = cfg; lock.unlock() }

    func update(_ change: (inout Config) -> Void) {
        var c = current
        change(&c)
        save(c)
    }

    @discardableResult
    func reloadIfChanged() -> Bool {
        let m = modDate()
        guard m != mtime else { return false }
        load()
        return true
    }

    private func modDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The app used to be called TrackFix: carry its settings and learned data over once.
    private static func migrateFromTrackFix(to dir: URL) {
        let fm = FileManager.default
        let old = dir.deletingLastPathComponent().appendingPathComponent("TrackFix", isDirectory: true)
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.copyItem(at: old, to: dir)
    }

    /// Upgrades older config files in place. Returns true if anything changed.
    static func migrate(_ json: inout Any) -> Bool {
        guard var j = json as? [String: Any] else { return false }
        var changed = false
        var edges = j["edges"] as? [String: Any] ?? [:]
        for k in ["left", "right"] {
            if let kind = edges[k] as? String { edges[k] = ["slide": kind]; changed = true }   // v0.1: "volume"
        }
        if let m = j["media"] as? [String: Any] {                                         // v0.2: media strip
            var b: [String: Any] = ["slide": "actions", "repeats": false]
            if let v = m["tap"] { b["tap"] = v }
            if let v = m["swipeRight"] { b["forward"] = v }
            if let v = m["swipeLeft"] { b["backward"] = v }
            if let d = m["swipeDistance"] as? Double { b["stepMM"] = d * 125 }
            if m["enabled"] as? Bool == false { b = ["slide": "none", "tap": ["type": "none"]] }
            edges["bottom"] = b
            if let h = m["height"] { edges["height"] = h }
            j["media"] = nil
            changed = true
        }
        if changed {
            j["edges"] = edges
            json = j
        }
        return changed
    }

    private static func merge(_ base: Any, _ over: Any) -> Any {
        guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
        var r = b
        for (k, v) in o { r[k] = r[k].map { merge($0, v) } ?? v }
        return r
    }
}

extension Notification.Name {
    static let configChanged = Notification.Name("Rim.configChanged")
    static let gesturePerformed = Notification.Name("Rim.gesturePerformed")
}

private let logQueue = DispatchQueue(label: "Rim.log")
private let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/Rim.log")

/// Debug log (only when `debug: true`), written to ~/Library/Logs/Rim.log.
func debugLog(_ message: @autoclosure () -> String) {
    guard ConfigStore.shared.current.debug else { return }
    let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + message() + "\n"
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }
}
