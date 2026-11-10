import AppKit
import Combine
import SwiftUI

/// Shows the app in the Dock while any Rim window is open, and the live touch feed runs only then.
enum WindowPresence {
    private static var open = 0

    static func opened() {
        open += 1
        TouchFeed.shared.retain()
        SettingsModel.shared.refreshStatus()
        NSApp.setActivationPolicy(.regular)
    }

    static func closed() {
        TouchFeed.shared.release()
        open = max(0, open - 1)
        if open == 0 { DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) } }
    }
}

/// Compact, fixed-size preferences window: icon tabs in the toolbar, the window animates to each
/// tab's size, no resizing and no full screen (classic macOS preferences).
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var tabs: TabsController?
    private var pageSink: AnyCancellable?

    func show(page: SettingsPage? = nil) {
        if window == nil { build() }
        if let page { select(page, animate: window?.isVisible == true) }
        if let w = window, w.isVisible == false {
            WindowPresence.opened()
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) { w.center() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = TabsController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for page in SettingsPage.allCases {
            let host = NSHostingController(rootView: SettingsPageView(page: page).environmentObject(SettingsModel.shared))
            host.sizingOptions = [.preferredContentSize]
            host.title = page.title   // the tab controller shows the selected page's title in the window
            let item = NSTabViewItem(viewController: host)
            item.label = page.title
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
            item.identifier = page.rawValue
            tabs.addTabViewItem(item)
        }

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.collectionBehavior = [.fullScreenNone, .managed]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        tabs.onSelect = { [weak self] page, animate in
            SettingsModel.shared.page = page
            self?.fit(page, animate: animate)
        }
        window = w
        self.tabs = tabs
        select(SettingsModel.shared.page ?? .zones, animate: false)
        fit(SettingsModel.shared.page ?? .zones, animate: false)
        w.center()

        // Pages can switch tabs too (e.g. "Customize Corners…" jumps to Zones).
        pageSink = SettingsModel.shared.$page.removeDuplicates().sink { [weak self] page in
            guard let page, let self, self.tabs?.current != page else { return }
            DispatchQueue.main.async { self.select(page, animate: true) }
        }
    }

    private func select(_ page: SettingsPage, animate: Bool) {
        guard let tabs, let i = SettingsPage.allCases.firstIndex(of: page) else { return }
        if tabs.selectedTabViewItemIndex != i { tabs.selectedTabViewItemIndex = i } else { fit(page, animate: animate) }
    }

    /// Resize around the top edge, like System Settings panes.
    private func fit(_ page: SettingsPage, animate: Bool) {
        guard let w = window else { return }
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: page.size))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        if let vf = w.screen?.visibleFrame, frame.minY < vf.minY { frame.origin.y = vf.minY }
        w.title = page.title
        w.setFrame(frame, display: true, animate: animate && w.isVisible)
    }

    func windowWillClose(_ notification: Notification) { WindowPresence.closed() }
}

private final class TabsController: NSTabViewController {
    var onSelect: ((SettingsPage, Bool) -> Void)?
    private(set) var current: SettingsPage?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let id = tabViewItem?.identifier as? String, let page = SettingsPage(rawValue: id) else { return }
        current = page
        onSelect?(page, view.window?.isVisible == true)
    }
}

/// Hosts a SwiftUI root in a fixed-size window (the welcome tour).
class HostedWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func makeRoot() -> AnyView { AnyView(EmptyView()) }
    var title: String { "Rim" }
    var size: NSSize { NSSize(width: 620, height: 560) }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeRoot().environmentObject(SettingsModel.shared))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = title
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.collectionBehavior = [.fullScreenNone, .managed]
            w.setContentSize(size)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        if window?.isVisible == false { WindowPresence.opened() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { WindowPresence.closed() }
}

final class OnboardingWindow: HostedWindow {
    static let shared = OnboardingWindow()
    override func makeRoot() -> AnyView { AnyView(OnboardingView()) }
    override var title: String { "Welcome to Rim" }
}
