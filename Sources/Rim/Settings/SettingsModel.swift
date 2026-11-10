import AppKit
import ServiceManagement
import SwiftUI

enum ZoneID: Hashable { case edge(Edge), corner(Corner) }

enum SettingsPage: String, CaseIterable, Identifiable {
    case zones, gestures, haptics, apps, learning, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zones: return "Zones"
        case .gestures: return "Gestures"
        case .haptics: return "Haptics"
        case .apps: return "Per-App Rules"
        case .learning: return "Learning"
        case .general: return "General"
        }
    }
    var symbol: String {
        switch self {
        case .zones: return "rectangle.dashed"
        case .gestures: return "hand.raised.fingers.spread"
        case .haptics: return "waveform.path"
        case .apps: return "square.grid.2x2"
        case .learning: return "brain"
        case .general: return "gearshape"
        }
    }
}

enum TriState: String, CaseIterable, Identifiable {
    case inherit, on, off
    var id: String { rawValue }
    var title: String { self == .inherit ? "Default" : self == .on ? "On" : "Off" }
    init(_ b: Bool?) { self = b == nil ? .inherit : (b! ? .on : .off) }
    var value: Bool? { self == .inherit ? nil : self == .on }
}

/// Live finger positions for drawings; isolated so 60 Hz updates only redraw the trackpad.
final class TouchFeed: ObservableObject {
    static let shared = TouchFeed()
    @Published private(set) var contacts: [Contact] = []

    private let lock = NSLock()
    private var listeners = 0
    private var latest: [Contact] = []
    private var pending = false

    func retain() { lock.lock(); listeners += 1; lock.unlock() }
    func release() { lock.lock(); listeners = max(0, listeners - 1); lock.unlock() }

    func feed(_ c: [Contact]) {
        lock.lock()
        guard listeners > 0 else { lock.unlock(); return }
        latest = c
        let schedule = !pending
        pending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.lock.lock(); let c = self.latest; self.pending = false; self.lock.unlock()
            self.contacts = c
        }
    }
}

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published var config: Config = ConfigStore.shared.current {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }
    @Published var page: SettingsPage? = .zones
    @Published var scope: String?                       // nil = all apps, else bundle id
    @Published var selection: ZoneID = .corner(.topLeft)
    @Published var editingZone: ZoneID?
    @Published var accessibilityGranted = EventGate.shared.trustedNow
    @Published var shortcuts: [String] = []
    @Published var learning: Learner.Snapshot?
    @Published var lastGesture: String?
    /// The most recent zone gesture Rim detected, for live feedback in the editor.
    @Published var lastEvent: (zone: ZoneID, text: String, at: Date)?

    private var applyingExternal = false
    private var saveWork: DispatchWorkItem?
    private var loadingShortcuts = false

    private init() {
        NotificationCenter.default.addObserver(forName: .configChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let c = ConfigStore.shared.current
            if c != self.config { self.applyingExternal = true; self.config = c; self.applyingExternal = false }
        }
        NotificationCenter.default.addObserver(forName: .gesturePerformed, object: nil, queue: .main) { [weak self] n in
            self?.lastGesture = n.object as? String
            if let zone = n.userInfo?["zone"] as? ZoneID, let text = n.userInfo?["text"] as? String {
                self?.lastEvent = (zone, text, Date())
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let c = config
        let work = DispatchWorkItem { ConfigStore.shared.save(c) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func refreshStatus() {
        accessibilityGranted = EventGate.shared.trustedNow
        learning = Learner.shared.snapshot(base: config.guardrails)
    }

    func loadShortcuts() {
        guard shortcuts.isEmpty, !loadingShortcuts else { return }
        loadingShortcuts = true
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
            DispatchQueue.main.async { self.shortcuts = names; self.loadingShortcuts = false }
        }
    }

    // MARK: - Scope-aware bindings

    var scopeName: String { scope.flatMap { config.apps[$0]?.name } ?? "All Apps" }

    /// What the drawing shows: global config, or the selected app's effective config.
    var displayConfig: Config {
        guard let s = scope, var rule = config.apps[s] else { return config }
        rule.disabled = false
        var c = config
        c.apps[s] = rule
        return c.resolved(for: s)
    }

    func cornerBinding(_ corner: Corner) -> Binding<CornerBinding> {
        Binding(
            get: { [unowned self] in
                if let s = scope, let o = config.apps[s]?.cornerOverrides[corner.rawValue] { return o }
                return config.corners.binding(corner)
            },
            set: { [unowned self] v in
                if let s = scope {
                    if config.apps[s]?.cornerOverrides[corner.rawValue] != nil { config.apps[s]!.cornerOverrides[corner.rawValue] = v }
                } else {
                    config.corners.setBinding(v, for: corner)
                }
            })
    }

    func edgeBinding(_ e: Edge) -> Binding<EdgeBinding> {
        Binding(
            get: { [unowned self] in
                if let s = scope, let o = config.apps[s]?.edgeOverrides[e.rawValue] { return o }
                return config.edges.binding(e)
            },
            set: { [unowned self] v in
                if let s = scope {
                    if config.apps[s]?.edgeOverrides[e.rawValue] != nil { config.apps[s]!.edgeOverrides[e.rawValue] = v }
                } else {
                    config.edges.setBinding(v, for: e)
                }
            })
    }

    func edgeOverridden(_ e: Edge) -> Binding<Bool> {
        Binding(
            get: { [unowned self] in scope.map { config.apps[$0]?.edgeOverrides[e.rawValue] != nil } ?? true },
            set: { [unowned self] on in
                guard let s = scope else { return }
                config.apps[s]?.edgeOverrides[e.rawValue] = on ? config.edges.binding(e) : nil
            })
    }

    func gestureBinding(_ name: String) -> Binding<Action> {
        Binding(
            get: { [unowned self] in
                if let s = scope, let o = config.apps[s]?.gestureOverrides[name] { return o }
                return config.gestures.action(name)
            },
            set: { [unowned self] v in
                if let s = scope {
                    if config.apps[s]?.gestureOverrides[name] != nil { config.apps[s]!.gestureOverrides[name] = v }
                } else {
                    config.gestures.set(name, v)
                }
            })
    }

    func gestureOverridden(_ name: String) -> Binding<Bool> {
        Binding(
            get: { [unowned self] in scope.map { config.apps[$0]?.gestureOverrides[name] != nil } ?? true },
            set: { [unowned self] on in
                guard let s = scope else { return }
                config.apps[s]?.gestureOverrides[name] = on ? config.gestures.action(name) : nil
            })
    }

    func cornerOverridden(_ corner: Corner) -> Binding<Bool> {
        Binding(
            get: { [unowned self] in scope.map { config.apps[$0]?.cornerOverrides[corner.rawValue] != nil } ?? true },
            set: { [unowned self] on in
                guard let s = scope else { return }
                config.apps[s]?.cornerOverrides[corner.rawValue] = on ? config.corners.binding(corner) : nil
            })
    }

    func ruleState(_ id: String, _ kp: WritableKeyPath<Config.AppRule, Bool?>) -> Binding<TriState> {
        Binding(
            get: { [unowned self] in TriState(config.apps[id]?[keyPath: kp] ?? nil) },
            set: { [unowned self] v in config.apps[id]?[keyPath: kp] = v.value })
    }

    func smartKey(_ id: String, _ type: String) -> Binding<String> {
        Binding(
            get: { [unowned self] in config.smartKeys[id]?[type] ?? "" },
            set: { [unowned self] v in
                var m = config.smartKeys[id] ?? [:]
                m[type] = v.isEmpty ? nil : v
                config.smartKeys[id] = m.isEmpty ? nil : m
            })
    }

    // MARK: - App rules

    func addRule(bundleID: String, name: String, disabled: Bool = false) {
        guard config.apps[bundleID] == nil else { return }
        var r = Config.AppRule(name: name)
        r.disabled = disabled
        config.apps[bundleID] = r
    }

    func addRule(fromAppAt url: URL) {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
        addRule(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }

    func removeRule(_ id: String) {
        config.apps[id] = nil
        if scope == id { scope = nil }
    }

    static let creativePresets: [String: String] = [
        "com.figma.Desktop": "Figma", "com.adobe.Photoshop": "Photoshop", "com.adobe.illustrator": "Illustrator",
        "com.seriflabs.affinitydesigner2": "Affinity Designer 2", "com.seriflabs.affinityphoto2": "Affinity Photo 2",
        "com.pixelmatorteam.pixelmator.x": "Pixelmator Pro", "com.bohemiancoding.sketch3": "Sketch",
        "org.blenderfoundation.blender": "Blender", "com.apple.FinalCut": "Final Cut Pro", "com.apple.logic10": "Logic Pro",
        "com.apple.freeform": "Freeform", "com.linearity.vn": "Linearity Curve", "com.valvesoftware.steam": "Steam",
        "com.apple.iMovieApp": "iMovie", "com.blackmagic-design.DaVinciResolve": "DaVinci Resolve",
    ]

    /// Browsers and video players: where the bottom edge should scrub video instead of skipping tracks.
    static let videoApps: [String: String] = [
        "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia", "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave", "app.zen-browser.zen": "Zen", "com.operasoftware.Opera": "Opera",
        "com.kagi.kagimacOS": "Orion", "com.colliderli.iina": "IINA", "org.videolan.vlc": "VLC",
        "com.apple.QuickTimePlayerX": "QuickTime Player", "com.apple.TV": "TV",
    ]

    static let videoScrubber = EdgeBinding(slide: "actions", forward: Action("seekForward"), backward: Action("seekBackward"),
                                           repeats: true, stepMM: 8, tap: Action("playPause"), doubleTap: Action("videoFullscreen"))

    /// Bottom edge = Video Scrubber in every installed browser / player (other apps keep their bottom edge).
    @discardableResult
    func addVideoScrubber(edge: Edge = .bottom) -> Int {
        var n = 0
        for (id, name) in Self.videoApps where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            if config.apps[id] == nil { config.apps[id] = Config.AppRule(name: name) }
            config.apps[id]?.edgeOverrides[edge.rawValue] = Self.videoScrubber
            n += 1
        }
        return n
    }

    /// Adds every installed drawing / design / game app with Rim turned off. Returns how many were added.
    @discardableResult
    func addCreativePresets() -> Int {
        var n = 0
        for (id, name) in Self.creativePresets where config.apps[id] == nil
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            addRule(bundleID: id, name: name, disabled: true)
            n += 1
        }
        return n
    }

    var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { NSLog("Rim: login item: \(error)") }
                self.objectWillChange.send()
            })
    }
}

func appIcon(_ bundleID: String) -> NSImage {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
}
