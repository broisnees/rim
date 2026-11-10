import Foundation

/// Every action Rim can run, with UI metadata.
extension Action {
    /// Runnable as configured: actions that need a value (app, keys, URL…) have one.
    var isComplete: Bool {
        !isNone && (ActionCatalog.info(type).input == .none || !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

struct ActionInfo: Identifiable, Hashable {
    enum Input { case none, app, shortcut, keys, url, shell }
    let id: String
    let title: String
    let symbol: String
    let input: Input
}

enum ActionCatalog {
    static let groups: [(title: String, items: [ActionInfo])] = [
        ("", [ActionInfo(id: "none", title: "Nothing", symbol: "circle.dashed", input: .none)]),
        ("Media", [
            .init(id: "playPause", title: "Play / Pause", symbol: "playpause.fill", input: .none),
            .init(id: "nextTrack", title: "Next Track", symbol: "forward.fill", input: .none),
            .init(id: "previousTrack", title: "Previous Track", symbol: "backward.fill", input: .none),
            .init(id: "mute", title: "Mute", symbol: "speaker.slash.fill", input: .none),
        ]),
        ("Editing", [
            .init(id: "copy", title: "Copy", symbol: "doc.on.doc", input: .none),
            .init(id: "paste", title: "Paste", symbol: "doc.on.clipboard", input: .none),
            .init(id: "cut", title: "Cut", symbol: "scissors", input: .none),
            .init(id: "pasteAndMatch", title: "Paste and Match Style", symbol: "doc.on.clipboard.fill", input: .none),
            .init(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", input: .none),
            .init(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", input: .none),
            .init(id: "selectAll", title: "Select All", symbol: "selection.pin.in.out", input: .none),
            .init(id: "find", title: "Find", symbol: "text.magnifyingglass", input: .none),
            .init(id: "save", title: "Save", symbol: "square.and.arrow.down", input: .none),
        ]),
        ("Scrolling & Zoom", [
            .init(id: "pageUp", title: "Page Up", symbol: "arrow.up.doc", input: .none),
            .init(id: "pageDown", title: "Page Down", symbol: "arrow.down.doc", input: .none),
            .init(id: "scrollTop", title: "Scroll to Top", symbol: "arrow.up.to.line", input: .none),
            .init(id: "scrollBottom", title: "Scroll to Bottom", symbol: "arrow.down.to.line", input: .none),
            .init(id: "zoomIn", title: "Zoom In", symbol: "plus.magnifyingglass", input: .none),
            .init(id: "zoomOut", title: "Zoom Out", symbol: "minus.magnifyingglass", input: .none),
            .init(id: "actualSize", title: "Actual Size", symbol: "1.magnifyingglass", input: .none),
        ]),
        ("Controls", [
            .init(id: "volumeUp", title: "Volume Up", symbol: "speaker.wave.3.fill", input: .none),
            .init(id: "volumeDown", title: "Volume Down", symbol: "speaker.wave.1.fill", input: .none),
            .init(id: "brightnessUp", title: "Brightness Up", symbol: "sun.max.fill", input: .none),
            .init(id: "brightnessDown", title: "Brightness Down", symbol: "sun.min.fill", input: .none),
            .init(id: "keyboardLightUp", title: "Keyboard Light Up", symbol: "light.max", input: .none),
            .init(id: "keyboardLightDown", title: "Keyboard Light Down", symbol: "light.min", input: .none),
            .init(id: "keyboardLightToggle", title: "Keyboard Light On / Off", symbol: "keyboard", input: .none),
        ]),
        ("App & Browser (adapts to the front app)", [
            .init(id: "toggleSidebar", title: "Toggle Sidebar", symbol: "sidebar.left", input: .none),
            .init(id: "closeTab", title: "Close Tab", symbol: "xmark.square", input: .none),
            .init(id: "newTab", title: "New Tab", symbol: "plus.square", input: .none),
            .init(id: "reopenTab", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward.square", input: .none),
            .init(id: "nextTab", title: "Next Tab", symbol: "arrow.right.square", input: .none),
            .init(id: "previousTab", title: "Previous Tab", symbol: "arrow.left.square", input: .none),
            .init(id: "back", title: "Back", symbol: "chevron.backward", input: .none),
            .init(id: "forward", title: "Forward", symbol: "chevron.forward", input: .none),
            .init(id: "hideApp", title: "Hide App", symbol: "eye.slash", input: .none),
        ]),
        ("Windows", [
            .init(id: "windowLeft", title: "Window: Left Half", symbol: "rectangle.lefthalf.filled", input: .none),
            .init(id: "windowRight", title: "Window: Right Half", symbol: "rectangle.righthalf.filled", input: .none),
            .init(id: "windowTop", title: "Window: Top Half", symbol: "rectangle.tophalf.filled", input: .none),
            .init(id: "windowBottom", title: "Window: Bottom Half", symbol: "rectangle.bottomhalf.filled", input: .none),
            .init(id: "windowMaximize", title: "Window: Fill Screen", symbol: "rectangle.inset.filled", input: .none),
            .init(id: "windowCenter", title: "Window: Center", symbol: "rectangle.center.inset.filled", input: .none),
            .init(id: "windowNextDisplay", title: "Window: Next Display", symbol: "rectangle.on.rectangle", input: .none),
            .init(id: "windowMinimize", title: "Window: Minimize", symbol: "minus.rectangle", input: .none),
            .init(id: "fullScreen", title: "Window: Full Screen", symbol: "arrow.up.left.and.arrow.down.right", input: .none),
        ]),
        ("Pointer & Apps", [
            .init(id: "middleClick", title: "Middle Click", symbol: "computermouse", input: .none),
            .init(id: "previousApp", title: "Previous App", symbol: "arrow.uturn.backward.circle", input: .none),
            .init(id: "newWindow", title: "New Window", symbol: "macwindow.badge.plus", input: .none),
            .init(id: "closeWindow", title: "Close Window", symbol: "xmark.rectangle", input: .none),
            .init(id: "emojiPicker", title: "Emoji & Symbols", symbol: "face.smiling", input: .none),
            .init(id: "forceQuit", title: "Force Quit…", symbol: "exclamationmark.octagon", input: .none),
        ]),
        ("System", [
            .init(id: "missionControl", title: "Mission Control", symbol: "rectangle.3.group", input: .none),
            .init(id: "appWindows", title: "App Windows", symbol: "macwindow.on.rectangle", input: .none),
            .init(id: "showDesktop", title: "Show Desktop", symbol: "menubar.dock.rectangle", input: .none),
            .init(id: "spotlight", title: "Spotlight", symbol: "magnifyingglass", input: .none),
            .init(id: "screenshot", title: "Screenshot to clipboard", symbol: "camera.viewfinder", input: .none),
            .init(id: "lockScreen", title: "Lock Screen", symbol: "lock.fill", input: .none),
            .init(id: "sleepDisplay", title: "Sleep Display", symbol: "moon.fill", input: .none),
        ]),
        ("Custom", [
            .init(id: "app", title: "Open App…", symbol: "app.badge", input: .app),
            .init(id: "shortcut", title: "Run Shortcut…", symbol: "square.2.layers.3d", input: .shortcut),
            .init(id: "keys", title: "Press Keys…", symbol: "command", input: .keys),
            .init(id: "url", title: "Open URL…", symbol: "link", input: .url),
            .init(id: "shell", title: "Run Command…", symbol: "terminal", input: .shell),
        ]),
    ]

    static let all: [ActionInfo] = groups.flatMap(\.items)
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func info(_ id: String) -> ActionInfo {
        byID[id] ?? ActionInfo(id: id, title: id, symbol: "questionmark.circle", input: .none)
    }

    static func sliderTitle(_ slide: String) -> String {
        ["volume": "Volume", "brightness": "Brightness", "keyboard": "Keyboard Light"][slide] ?? slide.capitalized
    }

    /// Arrows for an edge's slide directions.
    static func arrows(_ e: Edge) -> (forward: String, backward: String) { e.vertical ? ("↑", "↓") : ("→", "←") }

    /// One-line description of an edge: "Volume", "↑ Next Tab  ↓ Previous Tab", "Tap Play / Pause".
    static func edgeSummary(_ b: EdgeBinding, _ e: Edge) -> String {
        var parts: [String] = []
        if b.continuous { parts.append(sliderTitle(b.slide)) }
        else if b.slides {
            let a = arrows(e)
            if !b.forward.isNone { parts.append("\(a.forward) \(label(b.forward))") }
            if !b.backward.isNone { parts.append("\(a.backward) \(label(b.backward))") }
        }
        if !b.tap.isNone { parts.append("Tap \(label(b.tap))") }
        if !b.doubleTap.isNone { parts.append("×2 \(label(b.doubleTap))") }
        if !b.hold.isNone { parts.append("Hold \(label(b.hold))") }
        return parts.isEmpty ? "Not set" : parts.joined(separator: "  ")
    }

    /// Short label for drawings: "Spotlight", "Safari", "⌘⇧4".
    static func label(_ a: Action) -> String {
        let info = info(a.type)
        guard info.input != .none, let v = a.value, !v.isEmpty else { return info.title.replacingOccurrences(of: "…", with: "") }
        return a.type == "keys" ? prettyCombo(v) : v
    }
}
