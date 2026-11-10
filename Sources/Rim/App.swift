import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var configTimer: Timer?
    private var learnTimer: Timer?
    private var touchOK = false
    /// Rim sits in the input path: App Nap would delay every click and pointer move it filters.
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                      reason: "Rim filters trackpad input in real time")
        PointerFreeze.prepare()
        ConfigStore.shared.load()
        Learner.shared.load()
        AppContext.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let glyph = Bundle.main.image(forResource: "MenuIcon") ?? NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)
        glyph?.isTemplate = true                       // macOS tints it for light/dark menu bars
        glyph?.size = NSSize(width: 18, height: 18)
        glyph?.accessibilityDescription = "Rim"
        statusItem.button?.image = glyph
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        touchOK = TouchSource.shared.start()
        Haptics.setup()

        EventGate.shared.activate()
        // Show the tour on first run, after a permission relaunch, or when permission is missing (checked fresh).
        if !ConfigStore.shared.current.onboarded || UserDefaults.standard.bool(forKey: "resumeTourAfterPermission") {
            OnboardingWindow.shared.show()
        } else {
            Permission.checkFresh { trusted in if !trusted { OnboardingWindow.shared.show() } }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.touchOK = TouchSource.shared.start() }
        }
        configTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in ConfigStore.shared.reloadIfChanged() }
        configTimer?.tolerance = 1
        learnTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Learner.shared.saveIfNeeded() }
        learnTimer?.tolerance = 10
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwitcherHold.release()
        PointerFreeze.unfreeze()
        EventGate.shared.stop()
        Learner.shared.saveIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Automation.handle)
    }

    /// Reopening the app (e.g. double-clicking it in Finder) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.shared.show() }
        return true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = ConfigStore.shared.current

        let status: String
        if !touchOK { status = "Trackpad not detected" }
        else if !EventGate.shared.isRunning { status = "Needs Accessibility permission" }
        else if let err = ConfigStore.shared.lastError { status = "Config error: \(err)" }
        else if let id = AppContext.shared.bundleID, cfg.apps[id]?.disabled == true { status = "Off in \(cfg.apps[id]!.name)" }
        else { status = cfg.enabled ? "Active" : "Paused" }
        let header = NSMenuItem(title: "Rim: \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !EventGate.shared.isRunning {
            menu.addItem(Item("Grant Accessibility…") { OnboardingWindow.shared.show() })
        }
        menu.addItem(.separator())

        menu.addItem(Item("Enabled", on: cfg.enabled) { ConfigStore.shared.update { $0.enabled.toggle() } })
        if let id = AppContext.shared.bundleID, let name = AppContext.shared.name {
            let off = cfg.apps[id]?.disabled == true
            menu.addItem(Item(off ? "Turn On in \(name)" : "Turn Off in \(name)") {
                ConfigStore.shared.update { c in
                    if c.apps[id] == nil { c.apps[id] = Config.AppRule(name: name) }
                    c.apps[id]?.disabled = !off
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(Item("Edges", on: cfg.edges.enabled) { ConfigStore.shared.update { $0.edges.enabled.toggle() } })
        menu.addItem(Item("Corners", on: cfg.corners.enabled) { ConfigStore.shared.update { $0.corners.enabled.toggle() } })
        menu.addItem(Item("Gestures", on: cfg.gestures.enabled) { ConfigStore.shared.update { $0.gestures.enabled.toggle() } })
        menu.addItem(Item("Haptics", on: cfg.haptics) { ConfigStore.shared.update { $0.haptics.toggle() } })
        menu.addItem(.separator())

        menu.addItem(Item("Settings…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(Item("Restart Trackpad Input") { [weak self] in self?.touchOK = TouchSource.shared.start() })
        menu.addItem(.separator())
        menu.addItem(Item("Quit Rim", key: "q") { NSApp.terminate(nil) })
    }
}

/// NSMenuItem with a closure handler.
final class Item: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool? = nil, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
