import AppKit
import CMT

/// `rim://` URLs and the `--haptic` command line, so scripts can buzz you or run actions:
///   open -g "rim://haptic/success"         (pattern names: HapticPattern)
///   open -g "rim://run/playPause"          (any action that takes no input)
///   open "rim://settings"
///   /Applications/Rim.app/Contents/MacOS/Rim --haptic success
enum Automation {
    static func handle(_ url: URL) {
        guard url.scheme == "rim" else { return }
        let arg = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "haptic":
            Haptics.play(HapticPattern(rawValue: arg) ?? .success)
        case "run":
            // Only input-free actions: a web page must never be able to run commands, keys or apps.
            guard isAllowedFromURL(arg) else { NSLog("Rim: refused URL action '\(arg)'"); return }
            Actions.perform(Action(arg))
        case "settings":
            if let page = SettingsPage(rawValue: arg) { SettingsWindow.shared.show(page: page) } else { SettingsWindow.shared.show() }
            // rim://settings/zones/<top|left|topLeft|…> opens that zone's editor.
            let comps = url.pathComponents.dropFirst()
            if comps.count > 1, let z = comps.last {
                let zone: ZoneID? = Edge(rawValue: z).map { .edge($0) } ?? Corner(rawValue: z).map { .corner($0) }
                if let zone {
                    SettingsModel.shared.editingZone = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        SettingsModel.shared.selection = zone
                        SettingsModel.shared.editingZone = zone
                    }
                }
            }
        default:
            break
        }
    }

    /// Only known, input-free actions: a web page must never run commands, type keys or open apps.
    static func isAllowedFromURL(_ type: String) -> Bool {
        // Editing, closing and quitting act on whatever app is in front, so a web page must never trigger them.
        let unsafe: Set<String> = ["copy", "paste", "cut", "pasteAndMatch", "undo", "redo", "selectAll", "find", "save",
                                   "closeTab", "closeWindow", "newWindow", "newTab", "reopenTab", "forceQuit", "hideApp",
                                   "lockScreen", "sleepDisplay"]
        return type != "none" && !unsafe.contains(type) && ActionCatalog.all.contains { $0.id == type && $0.input == .none }
    }

    /// Runs without the app: talks to the actuator directly, then exits.
    static func hapticCLI(_ name: String) -> Never {
        guard let p = HapticPattern(rawValue: name) else {
            print("unknown pattern '\(name)'. Choose: " + HapticPattern.allCases.map(\.rawValue).joined(separator: ", "))
            exit(2)
        }
        _ = tf_mt_device_count()
        Haptics.setup()
        ConfigStore.shared.load()
        Haptics.play(p)
        let length = p.steps.map(\.0).max() ?? 0
        Thread.sleep(forTimeInterval: length + 0.1)
        exit(0)
    }
}

/// macOS's own trackpad gesture settings, to warn about clashes.
enum SystemGestures {
    private static func value(_ key: String) -> Int? {
        CFPreferencesCopyAppValue(key as CFString, "com.apple.AppleMultitouchTrackpad" as CFString) as? Int
    }

    static var threeFingerDrag: Bool { value("TrackpadThreeFingerDrag") == 1 }
    static var tapToClick: Bool { value("Clicking") == 1 }

    /// A warning when macOS already does something with this gesture.
    static func conflict(_ gesture: String) -> String? {
        switch gesture {
        case "threeFingerTap" where value("TrackpadThreeFingerTapGesture") == 2:
            return "macOS also uses this for Look Up & Data Detectors. Turn that off in System Settings → Trackpad, or both will run."
        case let g where (g == "tipTapLeft" || g == "tipTapRight") && tapToClick:
            return "Tapping a second finger while pointing normally clicks; with a tip-tap set, that click is replaced."
        default:
            return nil
        }
    }
}
