import AppKit

enum Actions {
    static func perform(_ a: Action) {
        DispatchQueue.main.async { run(a) }
    }

    /// Built-in actions that are just a standard shortcut.
    static let keyActions: [String: String] = [
        "copy": "cmd+c", "paste": "cmd+v", "cut": "cmd+x", "pasteAndMatch": "cmd+alt+shift+v",
        "undo": "cmd+z", "redo": "cmd+shift+z", "selectAll": "cmd+a", "find": "cmd+f", "save": "cmd+s",
        "pageUp": "pageup", "pageDown": "pagedown", "scrollTop": "home", "scrollBottom": "end",
        "newWindow": "cmd+n", "closeWindow": "cmd+w", "emojiPicker": "ctrl+cmd+space",
        "forceQuit": "cmd+alt+escape", "zoomIn": "cmd+=", "zoomOut": "cmd+-", "actualSize": "cmd+0",
    ]

    private static let missionControl = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"

    private static func run(_ a: Action) {
        let v = a.value ?? ""
        switch a.type {
        case let t where SmartActions.types.contains(t): SmartActions.perform(t)
        case let t where WindowActions.types.contains(t): WindowActions.perform(t)
        case "middleClick": postMiddleClick()
        case let t where keyActions[t] != nil: postKeys(keyActions[t]!)
        case "volumeUp": StepControl.step(.volume, by: 1)
        case "volumeDown": StepControl.step(.volume, by: -1)
        case "brightnessUp": StepControl.step(.brightness, by: 1)
        case "brightnessDown": StepControl.step(.brightness, by: -1)
        case "keyboardLightUp": StepControl.step(.keyboard, by: 1)
        case "keyboardLightDown": StepControl.step(.keyboard, by: -1)
        case "keyboardLightToggle": KeyboardLight.toggle()
        case "previousApp": AppContext.shared.activatePrevious()
        case "playPause": postMediaKey(.play)
        case "nextTrack": postMediaKey(.next)
        case "previousTrack": postMediaKey(.previous)
        case "mute": postMediaKey(.mute)
        case "missionControl": launch(missionControl, [])
        case "appWindows": launch(missionControl, ["2"])
        case "showDesktop": launch(missionControl, ["1"])
        case "lockScreen": postKeys("ctrl+cmd+q")
        case "sleepDisplay": launch("/usr/bin/pmset", ["displaysleepnow"])
        case "screenshot": postKeys("ctrl+cmd+shift+4") // area selection → clipboard
        case "spotlight": postKeys("cmd+space")
        case "keys": if !postKeys(v) { NSLog("Rim: unknown key combo '\(v)'") }
        case "app": launch("/usr/bin/open", ["-a", v])
        case "shortcut": launch("/usr/bin/shortcuts", ["run", v])
        case "url": if let u = URL(string: v) { NSWorkspace.shared.open(u) }
        case "shell": launch("/bin/zsh", ["-lc", v])
        default: NSLog("Rim: unknown action type '\(a.type)'")
        }
        if ConfigStore.shared.current.hud, let (symbol, text) = hudInfo(a) {
            KeyCast.shared.show(keys: shortcut(for: a), symbol: symbol, title: text)
        }
    }

    /// The keyboard shortcut an action sends in the front app, if it is one (shown as ⌘C etc.).
    static func shortcut(for a: Action) -> String? {
        if a.type == "keys" { return a.value }
        if let k = keyActions[a.type] { return k }
        if SmartActions.types.contains(a.type) {
            return SmartActions.resolvedKeys(a.type, bundle: AppContext.shared.bundleID ?? "")
        }
        return nil
    }

    /// Every action shows what ran, except ones whose result is already obvious on screen.
    private static func hudInfo(_ a: Action) -> (String, String)? {
        // Video actions report for themselves (they may decline when no video is in front).
        if SmartActions.videoTypes.contains(a.type) && SmartActions.browsers.contains(AppContext.shared.bundleID ?? "") { return nil }
        let visual: Set<String> = ["missionControl", "appWindows", "showDesktop", "spotlight", "screenshot",
                                   "lockScreen", "sleepDisplay", "fullScreen", "middleClick", "emojiPicker", "forceQuit",
                                   "volumeUp", "volumeDown", "brightnessUp", "brightnessDown",   // these show the level HUD
                                   "keyboardLightUp", "keyboardLightDown"]
        guard !visual.contains(a.type) else { return nil }
        let info = ActionCatalog.info(a.type)
        let text = a.type == "app" ? "Open \(ActionCatalog.label(a))" : ActionCatalog.label(a)
        return (info.symbol, text)
    }

    private static func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("Rim: failed to run \(path): \(error)") }
    }
}
