import AppKit
import ApplicationServices

/// Accessibility trust that is actually current.
///
/// On recent macOS a running process keeps the trust state it saw at launch: granting (or revoking)
/// Accessibility in System Settings is not reflected by `AXIsProcessTrusted()` until a restart.
/// A short-lived child process (this same binary with `--ax-check`) is attributed to Rim by TCC and
/// gets a fresh answer, so Rim can react immediately in both directions.
enum Permission {
    /// The value this process saw (may be stale).
    static var cachedTrusted: Bool { AXIsProcessTrusted() }

    /// Asks a fresh child process. Calls back on the main queue. Coalesces concurrent requests.
    static func checkFresh(_ done: @escaping (Bool) -> Void) {
        queue.async {
            if checking { waiters.append(done); return }
            checking = true
            waiters.append(done)
            let result = runCheck()
            let callbacks = waiters
            waiters.removeAll()
            checking = false
            DispatchQueue.main.async { callbacks.forEach { $0(result) } }
        }
    }

    private static let queue = DispatchQueue(label: "Rim.permission")
    private static var checking = false
    private static var waiters: [(Bool) -> Void] = []

    private static func runCheck() -> Bool {
        guard let exe = Bundle.main.executableURL else { return cachedTrusted }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--ax-check"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return cachedTrusted }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Restarts Rim so it picks up a permission macOS granted while it was running.
    static func relaunch(resumeTour: Bool) {
        // Never loop: at most one permission relaunch per minute.
        let last = UserDefaults.standard.double(forKey: "lastPermissionRelaunch")
        let now = Date().timeIntervalSince1970
        guard now - last > 60 else { NSLog("Rim: permission granted but event tap unavailable; not relaunching again"); return }
        UserDefaults.standard.set(now, forKey: "lastPermissionRelaunch")
        if resumeTour { UserDefaults.standard.set(true, forKey: "resumeTourAfterPermission") }
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSLog("Rim: relaunching to pick up Accessibility permission")
        NSApp.terminate(nil)
    }
}
