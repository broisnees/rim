import AppKit
import ApplicationServices

/// Actions whose key combo depends on the frontmost app (sidebar, tabs, history).
/// Resolution order: user override → known-app table → the app's own menu item (Accessibility) → common default.
enum SmartActions {
    static let types: Set<String> = ["toggleSidebar", "closeTab", "newTab", "reopenTab", "nextTab", "previousTab",
                                     "back", "forward", "hideApp",
                                     "seekForward", "seekBackward", "playbackFaster", "playbackSlower",
                                     "frameForward", "frameBackward", "videoFullscreen"]

    /// Video and audio players: per-app keys, with the web-player conventions (YouTube, Netflix, Vimeo…) as default.
    private static let mediaKeys: [String: [String: String]] = [
        "seekForward": ["org.videolan.vlc": "cmd+alt+right", "com.spotify.client": "shift+right"],
        "seekBackward": ["org.videolan.vlc": "cmd+alt+left", "com.spotify.client": "shift+left"],
        "playbackFaster": ["com.colliderli.iina": "]", "org.videolan.vlc": "cmd+="],
        "playbackSlower": ["com.colliderli.iina": "[", "org.videolan.vlc": "cmd+-"],
        "frameForward": ["com.apple.QuickTimePlayerX": "right", "org.videolan.vlc": "e"],
        "frameBackward": ["com.apple.QuickTimePlayerX": "left"],
        "videoFullscreen": ["com.apple.QuickTimePlayerX": "ctrl+cmd+f", "org.videolan.vlc": "cmd+f",
                            "com.colliderli.iina": "cmd+f", "com.apple.TV": "ctrl+cmd+f"],
    ]

    /// Default keys that work in nearly every app and browser.
    private static let defaults: [String: String] = [
        "closeTab": "cmd+w", "newTab": "cmd+t", "reopenTab": "cmd+shift+t",
        "nextTab": "ctrl+tab", "previousTab": "ctrl+shift+tab",
        "back": "cmd+[", "forward": "cmd+]", "hideApp": "cmd+h",
        "toggleSidebar": "ctrl+cmd+s",   // AppKit's standard Show/Hide Sidebar
        // Web video players (YouTube, Netflix, Vimeo, Prime…), IINA and most players:
        "seekForward": "right", "seekBackward": "left",
        "playbackFaster": "shift+.", "playbackSlower": "shift+,",
        "frameForward": ".", "frameBackward": ",",
        "videoFullscreen": "f",
    ]

    /// Apps whose sidebar has no standard menu item (or a different shortcut).
    private static let sidebarKeys: [String: String] = [
        "company.thebrowser.Browser": "cmd+s",          // Arc
        "com.microsoft.VSCode": "cmd+b",
        "com.todesktop.230313mzl4w4u92": "cmd+b",       // Cursor
        "dev.zed.Zed": "cmd+b",
        "com.tinyspeck.slackmacgap": "cmd+shift+d",
        "notion.id": "cmd+\\",
        "com.apple.dt.Xcode": "cmd+0",
        "com.apple.Safari": "cmd+shift+l",
    ]

    /// Menu titles to look for, scored (higher wins).
    private static func menuScore(_ type: String, _ title: String, inViewMenu: Bool) -> Int? {
        let t = title.lowercased()
        let bonus = inViewMenu ? 1 : 0
        switch type {
        case "toggleSidebar":
            guard t.contains("sidebar") || t.contains("side bar") else { return nil }
            for bad in ["position", "location", "setting", "customize", "move", " in sidebar", " to sidebar", "from sidebar", "right"] where t.contains(bad) { return nil }
            if t.hasPrefix("show ") || t.hasPrefix("hide ") || t.hasPrefix("toggle ") { return 3 + bonus }
            if t == "sidebar" || t == "side bar" || t == "primary side bar" { return 2 + bonus }
            return nil
        default:
            return nil
        }
    }

    static func perform(_ type: String) {
        let ctx = AppContext.shared
        let bundle = ctx.bundleID ?? ""
        let pid = ctx.pid
        DispatchQueue.global(qos: .userInitiated).async {
            if let combo = ConfigStore.shared.current.smartKeys[bundle]?[type], !combo.isEmpty {
                debugLog("smart \(type): override \(combo)")
                postKeys(combo); return
            }
            if let combo = mediaKeys[type]?[bundle] { debugLog("smart \(type): player \(combo)"); postKeys(combo); return }
            if type == "toggleSidebar" {
                if let combo = sidebarKeys[bundle] { debugLog("smart sidebar: table \(combo)"); postKeys(combo); return }
                if pid > 0, pressMenuItem(pid: pid, type: type) { return }
            }
            if let combo = defaults[type] { debugLog("smart \(type): default \(combo)"); postKeys(combo) }
        }
    }

    // MARK: - Menu bar via Accessibility

    private static func pressMenuItem(pid: pid_t, type: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return false }

        var best: (score: Int, element: AXUIElement, title: String)?
        let topItems: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        for (index, top) in topItems.enumerated() where index > 0 {        // skip the Apple menu
            let topTitle: String = attribute(top, kAXTitleAttribute) ?? ""
            if topTitle == "Help" { continue }
            walk(top, depth: 0) { el, title in
                guard let s = menuScore(type, title, inViewMenu: topTitle == "View"), s > (best?.score ?? 0) else { return }
                let enabled: Bool = attribute(el, kAXEnabledAttribute) ?? true
                if enabled { best = (s, el, title) }
            }
        }
        guard let best else { return false }
        debugLog("smart \(type): menu item '\(best.title)'")
        return AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success
    }

    private static func walk(_ el: AXUIElement, depth: Int, _ visit: (AXUIElement, String) -> Void) {
        guard depth < 4 else { return }
        let children: [AXUIElement] = attribute(el, kAXChildrenAttribute) ?? []
        for child in children {
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuItemRole as String, let title: String = attribute(child, kAXTitleAttribute), !title.isEmpty {
                visit(child, title)
            }
            walk(child, depth: depth + 1, visit)
        }
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}
