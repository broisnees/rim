import AppKit

/// Tracks the frontmost app so gestures can use per-app rules. Readable from any thread.
final class AppContext {
    static let shared = AppContext()

    private let lock = NSLock()
    private var _bundleID: String?
    private var _pid: pid_t = 0
    private var _name: String?
    private var _previousPID: pid_t = 0

    var bundleID: String? { lock.lock(); defer { lock.unlock() }; return _bundleID }
    var pid: pid_t { lock.lock(); defer { lock.unlock() }; return _pid }
    var name: String? { lock.lock(); defer { lock.unlock() }; return _name }

    func start() {
        set(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            self?.set(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func set(_ app: NSRunningApplication?) {
        // Our own settings window shouldn't change which rule applies.
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lock.lock()
        if app.processIdentifier != _pid, _pid != 0 { _previousPID = _pid }
        _bundleID = app.bundleIdentifier
        _pid = app.processIdentifier
        _name = app.localizedName
        lock.unlock()
    }

    /// Switches back to the app that was in front before the current one.
    func activatePrevious() {
        lock.lock(); let pid = _previousPID; lock.unlock()
        guard pid != 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        app.activate()
    }

    /// Config with the frontmost app's rule applied.
    var effectiveConfig: Config { ConfigStore.shared.current.resolved(for: bundleID) }
}
