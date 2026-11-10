import AppKit

/// A HID-level event tap that swallows cursor movement and clicks while a zone gesture
/// owns the finger, so a corner tap doesn't also click and an edge slide doesn't move the cursor.
///
/// Safety rules (input must never get stuck):
///  1. The tap exists only while Rim is trusted for Accessibility. Revocation is detected
///     immediately (distributed notification) and by a 1 s watchdog, and the tap is torn down.
///     A disabled tap is only re-enabled while still trusted.
///  2. Swallowing requires a live heartbeat from the gesture engine (< 250 ms old) and a session
///     shorter than 8 s. If touch frames stop for any reason, everything passes through again.
///  3. Any reset of the touch pipeline (wake, restart, device loss) clears all gate state.
///  4. When in doubt, pass the event.
final class EventGate {
    static let shared = EventGate()

    private static let heartbeatTimeout: TimeInterval = 0.25
    private static let maxSession: TimeInterval = 8

    private let lock = NSLock()
    private var captureAll = false
    private var fingerDown = false
    private weak var owner: GestureEngine?
    private var dropClicksUntil: TimeInterval = 0
    private var dropUp: Set<Int64> = []
    private var pinnedCursor: CGPoint?
    private var held = CGVector(dx: 0, dy: 0)     // pointer motion swallowed during this session

    /// Moves the pointer (replaceable in tests so they never move the real cursor).
    var warp: (CGPoint) -> Void = { p in
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)   // cancels the post-warp event suppression, so motion resumes instantly
    }
    private var sessionStart: TimeInterval = 0
    private var heartbeatAt: TimeInterval = 0
    private var lastKeyTime: TimeInterval = -100

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    private var trustTimer: Timer?
    private var trustObserver: NSObjectProtocol?

    /// Seconds since the last real keystroke (typing guard).
    var secondsSinceKey: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return now - lastKeyTime
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Lifecycle (main thread)

    /// Starts the gate when trusted and keeps it in sync with the Accessibility permission from then on.
    func activate() {
        if trustObserver == nil {
            trustObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
            ) { [weak self] _ in
                // Permission changed somewhere: get a fresh answer (TCC settles shortly after the notification).
                self?.syncWithTrust(fresh: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.syncWithTrust(fresh: true) }
            }
        }
        if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.syncWithTrust() }
            trustTimer?.tolerance = 0.2
        }
        syncWithTrust()
    }

    /// Keeps the tap in sync with the *current* permission. `fresh` forces a child-process check;
    /// while the gate isn't running, every tick uses a fresh check (the cached value may be stale).
    private func syncWithTrust(fresh: Bool = false) {
        let running = isRunning
        if running && !Permission.cachedTrusted {
            NSLog("Rim: Accessibility revoked, removing event gate")
            stop()
            return
        }
        if running && !fresh { return }
        if !running && Permission.cachedTrusted {
            if start() { NSLog("Rim: event gate started"); return }
        }
        Permission.checkFresh { [weak self] trusted in
            guard let self else { return }
            if !trusted {
                if self.isRunning { NSLog("Rim: Accessibility revoked (fresh check), removing event gate"); self.stop() }
                return
            }
            guard !self.isRunning else { return }
            if self.start() { NSLog("Rim: event gate started"); return }
            // Granted, but this process can't use it until it restarts.
            Permission.relaunch(resumeTour: !ConfigStore.shared.current.onboarded)
        }
    }

    /// Accessibility is usable by this process right now.
    var trustedNow: Bool { isRunning }

    @discardableResult
    private func start() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: gateCallback, userInfo: nil)
               ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: gateCallback, userInfo: nil)
        else { return false }

        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Rim.EventGate"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        lock.lock()
        tap = port
        source = src
        tapRunLoop = loop
        resetLocked()
        lock.unlock()
        return true
    }

    /// Removes the tap completely: disabled, invalidated, run loop stopped. Input flows untouched.
    func stop() {
        lock.lock()
        let port = tap, src = source, loop = tapRunLoop
        tap = nil; source = nil; tapRunLoop = nil
        resetLocked()
        lock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop {
            if let src { CFRunLoopRemoveSource(loop, src, .commonModes) }
            CFRunLoopStop(loop)
        }
    }

    /// Clears every capture/drop state (touch pipeline restarted, device lost, wake).
    func reset() {
        lock.lock(); resetLocked(); lock.unlock()
    }

    private func resetLocked() {
        owner = nil
        fingerDown = false
        if pinnedCursor != nil { PointerFreeze.unfreeze() }   // any reset shows the real pointer again
        captureAll = false
        pinnedCursor = nil
        held = CGVector(dx: 0, dy: 0)
        dropUp.removeAll()
        dropClicksUntil = 0
    }

    // MARK: - Engine API

    func begin(owner: GestureEngine, captureAll: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.owner = owner
        fingerDown = true
        self.captureAll = captureAll
        sessionStart = now
        heartbeatAt = now
        pinnedCursor = captureAll ? CGEvent(source: nil)?.location : nil
        held = CGVector(dx: 0, dy: 0)
        if let pin = pinnedCursor { PointerFreeze.freeze(at: pin) }
    }

    /// Called on every multitouch frame while a session is active.
    func heartbeat() {
        lock.lock(); heartbeatAt = now; lock.unlock()
    }

    func setCaptureAll() {
        lock.lock(); defer { lock.unlock() }
        captureAll = true
        heartbeatAt = now
        if pinnedCursor == nil, let pin = CGEvent(source: nil)?.location {
            pinnedCursor = pin
            PointerFreeze.freeze(at: pin)
        }
    }

    /// Swallow clicks for a moment without touching session state (multi-finger taps).
    func dropClicks(for seconds: TimeInterval) {
        lock.lock(); dropClicksUntil = max(dropClicksUntil, now + seconds); lock.unlock()
    }

    /// Ends a session. `giveBack`: the touch turned out to be normal pointer use, so the motion held back
    /// while deciding is applied now and the pointer lands where it would have been.
    func end(dropClicksFor seconds: TimeInterval, giveBack: Bool = false) {
        lock.lock()
        let target: CGPoint? = giveBack && (held.dx != 0 || held.dy != 0)
            ? pinnedCursor.map { CGPoint(x: $0.x + held.dx, y: $0.y + held.dy) } : nil
        let pin = pinnedCursor
        owner = nil
        fingerDown = false
        captureAll = false
        pinnedCursor = nil
        held = CGVector(dx: 0, dy: 0)
        if seconds > 0 { dropClicksUntil = now + seconds }
        lock.unlock()
        if let target {
            warp(Self.clampToScreens(target))          // not a gesture: pointer lands where it would have been
            PointerFreeze.unfreeze()
        } else if let pin {
            PointerFreeze.unfreeze(at: pin)           // gesture: pointer reappears exactly where it was
        }
    }

    private static func clampToScreens(_ p: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let rects = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) || rects.isEmpty { return p }
        let r = rects.min { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) }!
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    /// Motion held back so far (tests).
    var heldMotion: CGVector { lock.lock(); defer { lock.unlock() }; return held }

    // MARK: - Tap (tap thread)

    /// True while a session may legitimately swallow input. Expired sessions are released here.
    private func sessionAliveLocked(_ t: TimeInterval) -> Bool {
        guard fingerDown || captureAll else { return false }
        if t - heartbeatAt > Self.heartbeatTimeout || t - sessionStart > Self.maxSession {
            let o = owner
            resetLocked()
            debugLog("gate watchdog: released stale capture")
            DispatchQueue.global().async { o?.physicalPress() }   // let the engine drop its session too
            return false
        }
        return true
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Resume only after a fresh check confirms permission; otherwise tear down so input can never stall.
            lock.lock(); resetLocked(); lock.unlock()
            Permission.checkFresh { [weak self] trusted in
                guard let self else { return }
                if trusted {
                    self.lock.lock(); let port = self.tap; self.lock.unlock()
                    if let port { CGEvent.tapEnable(tap: port, enable: true) }
                } else {
                    self.stop()
                }
            }
            return pass
        }

        let t = now
        lock.lock()
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel:
            // Rim's own edge-scroll events always pass.
            if type == .scrollWheel && event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                lock.unlock(); return pass
            }
            let drop = captureAll && sessionAliveLocked(t)
            let pin = pinnedCursor
            if drop && type != .scrollWheel {
                held.dx += event.getDoubleValueField(.mouseEventDeltaX)
                held.dy += event.getDoubleValueField(.mouseEventDeltaY)
            }
            lock.unlock()
            if drop, let pin, let cur = CGEvent(source: nil)?.location, hypot(cur.x - pin.x, cur.y - pin.y) > 0.5 {
                CGWarpMouseCursorPosition(pin)
            }
            return drop ? nil : pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Our own synthetic clicks (e.g. middle click) always pass.
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { lock.unlock(); return pass }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let alive = sessionAliveLocked(t)
            if alive && fingerDown {
                // A press while the finger is still down is a physical click: let it through, give up the gesture.
                let o = owner
                resetLocked()
                lock.unlock()
                o?.physicalPress()
                return pass
            }
            if (alive && captureAll) || t < dropClicksUntil {
                dropUp.insert(button)
                lock.unlock()
                debugLog("dropped click (button \(button))")
                return nil
            }
            lock.unlock()
            if type == .leftMouseDown { Learner.shared.didClick() }
            return pass

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { lock.unlock(); return pass }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let drop = dropUp.remove(button) != nil
            lock.unlock()
            return drop ? nil : pass

        case .keyDown:
            // Ignore our own synthetic keys (corner actions) so they don't trip the typing guard.
            if event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                lastKeyTime = t
            }
            lock.unlock()
            return pass

        default:
            lock.unlock()
            return pass
        }
    }
}

private let gateCallback: CGEventTapCallBack = { _, type, event, _ in
    EventGate.shared.handle(type, event)
}
