import Foundation

/// Recognises single-finger gestures that start in one of the four edges or four corners.
/// Everything else is left untouched so normal trackpad use keeps working.
///
/// Accidental-touch rejection (all must pass before a zone gesture can start):
///  - no real keystroke in the last `typingPause` seconds (palms while typing)
///  - exactly one finger, landing on an empty trackpad, not right after a multi-finger gesture
///  - contact is finger-sized (not a palm / thumb side)
/// and then per gesture:
///  - sliders must engage within `activationWindow`, moving mostly *along* the edge
///  - taps must be short, still and deliberate (not a graze, not a rest)
final class GestureEngine {
    enum Kind: Equatable { case edge(Edge), corner(Corner) }

    let widthMM: Double
    let heightMM: Double

    private struct Session {
        var kind: Kind
        let id: Int32
        let sx: Double, sy: Double        // start, mm
        let t0: Double
        var maxDist = 0.0                 // mm
        var maxSize: Float = 0
        var activated = false             // slide engaged
        var steps = 0                     // slide actions fired
        var holdFired = false
        var lastAlong = 0.0               // filtered position along the edge, mm
        var stepAnchor = 0.0              // along-position where sliding engaged (one-shot swipes)
        var stepAccum = 0.0               // accelerated travel since the last repeating step, mm
        var filter = OneEuroFilter()
        var velocity = VelocityTracker()
    }

    // Thresholds in millimetres (physical, so they feel the same on every trackpad).
    private let engageDistance = 1.8      // travel along an edge before the slider engages
    private let edgeAngle = 1.7           // along/perp ratio required to engage (~60° cone)
    private let leaveEdge = 3.5           // travel away from the edge that means "normal pointer use"
    private let cornerSlop = 3.0          // travel that ends a corner tap
    private let holdSlop = 2.5            // travel allowed during press & hold
    private let liftSwipe = 6.0           // mm of sideways travel that counts as a swipe when the finger lifts
    private let maxStepsPerFrame = 3

    private let lock = NSLock()
    private var session: Session?
    private var ignoreUntilLift = false
    private var prevCount = 0
    private var multiFingerEndedAt = -100.0
    private var lastFrameTime = 0.0

    // Resting fingers: contacts that stayed down a while. A resting thumb or palm "bouncing" makes lifts and
    // re-landings that look like taps, so taps near a recent rest are ignored for a moment.
    private var contactStart: [Int32: (t: Double, x: Double, y: Double)] = [:]
    private var recentRests: [(x: Double, y: Double, end: Double)] = []
    private var recentTouches: [(x: Double, y: Double, end: Double)] = []
    static let restDuration = 0.45, restRadius = 15.0, restWindow = 0.8
    /// A deliberate tap is isolated: nothing touched the same spot just before. A hand drumming or a thumb
    /// bouncing on an edge repeats every ~0.6 s (measured), so it always has an earlier touch there.
    static let isolationWindow = 0.8, isolationRadius = 15.0
    /// Corners aren't rested on: only reject true bounces there, so quick deliberate repeat taps still count.
    static let cornerIsolationWindow = 0.25
    /// Fingertip taps measured 0.74–1.03; thumb / palm-heel contacts 1.0–1.7.
    static let tapMaxSize: Float = 1.25
    static let doubleTapMinGap = 0.05   // a bouncing finger re-lands faster than a deliberate second tap
    private var multi = MultiFingerRecognizer()

    // Momentum (inertia) for repeating edge actions, and speed-up for consecutive slides.
    private struct Momentum { let edge: Edge; var velocity: Double; var accum: Double; let token: Int; var scroll = false }
    private var momentum: Momentum?
    private var momentumToken = 0
    private var lastSlide: (edge: Edge, dir: Double, end: Double)?
    private var consecutive = 0
    private let momentumQueue = DispatchQueue(label: "Rim.momentum", qos: .userInteractive)

    /// Physical drag, like Mac Mouse Fix's DragCurve: dv/dt = -k·|v|^p, stopping below `stopSpeed`.
    static let momentumStart = 120.0, momentumStop = 25.0, dragK = 4.5, dragP = 1.0
    /// Scrolling glides longer, like trackpad inertia.
    static let scrollMomentumStart = 60.0, scrollDragK = 2.6
    private let gate = EventGate.shared

    /// Test hooks: a fixed config, and a sink that records actions instead of running them.
    static var testConfig: Config?
    static var testSink: ((String, Action) -> Void)?

    init(widthMM: Double, heightMM: Double) {
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    func process(_ contacts: [Contact], time: Double) {
        lock.lock(); defer { lock.unlock() }

        lastFrameTime = time
        let touching = contacts.filter { $0.touching }
        trackRests(touching, time: time)
        let prev = prevCount
        prevCount = touching.count
        if prev > 1 && touching.count <= 1 { multiFingerEndedAt = time }
        if prev == 0 && !touching.isEmpty && momentum != nil { momentum = nil }   // a new touch stops momentum

        var cfg = Self.testConfig ?? AppContext.shared.effectiveConfig
        cfg.guardrails = Learner.shared.guardrails(cfg.guardrails)

        // Multi-finger taps run on every frame, independent of zone sessions.
        multi.tipSwipeStep = max(5, cfg.gestures.tipSwipeStepMM)
        let events = multi.process(touching, time: time, typing: gate.secondsSinceKey < cfg.guardrails.typingPause,
                                   palmSize: cfg.guardrails.palmSize)
        if cfg.enabled && cfg.gestures.enabled {
            for e in events {
                let action = cfg.gestures.action(e.rawValue)
                guard !action.isNone else { continue }
                gate.dropClicks(for: 0.45)   // swallow the click/right-click macOS makes for the same tap
                let tip = e == .tipTapLeft || e == .tipTapRight
                let swipeStep = e.rawValue.hasPrefix("tipSwipe")
                if e == .twoFingerSwipeLeft || e == .twoFingerSwipeRight { gate.dropScroll(for: 0.5) }   // cut the flick's momentum
                fire(action, haptic: swipeStep ? .tick : tip ? .tipTap : .gesture, gesture: e.rawValue, how: e.rawValue)
            }
        }
        // While a tip-swipe slides, the moving finger would also scroll the page: hold scrolling back.
        if multi.tipSwipeActive && cfg.gestures.enabled { gate.dropScroll(for: 0.6) }

        if ignoreUntilLift {
            if touching.isEmpty { ignoreUntilLift = false }
            return
        }

        guard var s = session else {
            if prev == 0, touching.count == 1, let c = touching.first, cfg.enabled, gate.isRunning || Self.testConfig != nil,
               let kind = zone(c.x, c.y, cfg) {
                if let reason = rejectStart(c, time: time, cfg: cfg) {
                    debugLog("reject \(kind): \(reason)")
                    ignoreUntilLift = true
                } else {
                    begin(kind, c, time, cfg)
                }
            }
            return
        }

        gate.heartbeat()
        if touching.count > 1 { abort("second finger"); return }
        guard let c = touching.first else { finish(s, time: time, cfg: cfg); return }
        guard c.id == s.id else { abort("finger changed"); return }

        s.maxDist = max(s.maxDist, hypot(c.xmm - s.sx, c.ymm - s.sy))
        s.maxSize = max(s.maxSize, c.size)
        if c.size > cfg.guardrails.palmSize { abort("contact grew to palm size (\(c.size))"); return }

        let alive: Bool
        switch s.kind {
        case .edge(let e): alive = updateEdge(&s, e, c, time, cfg)
        case .corner(let corner): alive = updateCorner(&s, c, time, cfg, corner)
        }
        if alive { session = s }
    }

    private func trackRests(_ touching: [Contact], time: Double) {
        let live = Set(touching.map(\.id))
        for (id, c) in contactStart where !live.contains(id) {
            contactStart[id] = nil
            if time - c.t >= Self.restDuration { recentRests.append((c.x, c.y, time)) }
            recentTouches.append((c.x, c.y, time))
        }
        for c in touching where contactStart[c.id] == nil { contactStart[c.id] = (time, c.xmm, c.ymm) }
        recentRests.removeAll { time - $0.end > Self.restWindow }
        recentTouches.removeAll { time - $0.end > Self.isolationWindow + 0.5 }
    }

    /// Nothing else touched this spot in the moments before this touch began.
    private func isIsolated(_ s: Session) -> Bool {
        let window: Double
        if case .corner = s.kind { window = Self.cornerIsolationWindow } else { window = Self.isolationWindow }
        return !recentTouches.contains { $0.end < s.t0 && s.t0 - $0.end <= window
            && hypot(s.sx - $0.x, s.sy - $0.y) <= Self.isolationRadius }
    }

    /// A tap here right after a finger rested on the same spot is the rest bouncing, not a deliberate tap.
    private func isRestBounce(_ s: Session) -> Bool {
        recentRests.contains { s.t0 - $0.end <= Self.restWindow && hypot(s.sx - $0.x, s.sy - $0.y) <= Self.restRadius }
    }

    /// Called by the event gate when a real (physical) click happens during a session.
    func physicalPress() {
        lock.lock(); defer { lock.unlock() }
        guard session != nil else { return }
        debugLog("physical press -> cancel session")
        session = nil
        ignoreUntilLift = true
        SliderController.shared.end()
        SwitcherHold.release()
    }

    // MARK: - Guards

    private func rejectStart(_ c: Contact, time: Double, cfg: Config) -> String? {
        let g = cfg.guardrails
        if gate.secondsSinceKey < g.typingPause { return "typing" }
        if time - multiFingerEndedAt < g.multiFingerCooldown { return "multi-finger cooldown" }
        if c.size > g.palmSize { return "palm-sized contact (\(c.size))" }
        return nil
    }

    // MARK: - Zones

    private func zone(_ x: Float, _ y: Float, _ cfg: Config) -> Kind? {
        let c = cfg.corners
        if c.enabled {
            let l = x < c.width, r = x > 1 - c.width, b = y < c.height, t = y > 1 - c.height
            var corner: Corner?
            if t && l { corner = .topLeft } else if t && r { corner = .topRight }
            else if b && l { corner = .bottomLeft } else if b && r { corner = .bottomRight }
            if let corner, !c.binding(corner).isNone { return .corner(corner) }
        }
        let e = cfg.edges
        guard e.enabled else { return nil }
        if x < e.width, !e.left.isNone { return .edge(.left) }
        if x > 1 - e.width, !e.right.isNone { return .edge(.right) }
        if y < e.height, !e.bottom.isNone { return .edge(.bottom) }
        if y > 1 - e.height, !e.top.isNone { return .edge(.top) }
        return nil
    }

    // MARK: - Lifecycle

    private func begin(_ kind: Kind, _ c: Contact, _ time: Double, _ cfg: Config) {
        var s = Session(kind: kind, id: c.id, sx: c.xmm, sy: c.ymm, t0: time)
        s.maxSize = c.size
        session = s
        // The pointer is frozen from touch-down in every zone. If the touch turns out to be normal pointer
        // use, the held-back motion is given back on abort, so nothing is lost.
        gate.begin(owner: self, captureAll: true)
        debugLog("begin \(kind) at (\(c.x), \(c.y)) size \(c.size)")
    }

    private func abort(_ why: String) {
        debugLog("abort: \(why)")
        // Not a gesture after all (nothing ran yet): hand the held-back pointer motion back.
        let giveBack = session.map { !$0.activated && $0.steps == 0 && !$0.holdFired } ?? false
        session = nil
        ignoreUntilLift = true
        gate.end(dropClicksFor: 0, giveBack: giveBack)
        SliderController.shared.end()
        SwitcherHold.release()
    }

    private func finish(_ s: Session, time: Double, cfg: Config) {
        session = nil
        let g = cfg.guardrails
        let duration = time - s.t0
        let bounce = isRestBounce(s)
        // Fingertip-size limit is for edges (where thumbs and palms rest); a fingertip pressed into a corner
        // against the frame measures larger (up to ~1.55), so corners only reject palm-sized contacts.
        let sizeLimit: Float
        if case .corner = s.kind { sizeLimit = g.palmSize } else { sizeLimit = min(Self.tapMaxSize, g.palmSize) }
        let bigContact = s.maxSize > sizeLimit
        if bounce { debugLog("tap ignored: resting finger bouncing") }
        if bigContact { debugLog("tap ignored: thumb / palm-sized contact (\(s.maxSize))") }
        // Learned limits can get tight; zone taps always get at least 2 mm of wiggle and 0.25 s.
        let isTap = !s.activated && s.steps == 0 && !s.holdFired && s.maxDist < max(g.tapSlop, 2.0) && !bounce && !bigContact
            && duration >= g.minTap && duration <= max(g.maxTap, 0.25)
        debugLog("finish \(s.kind) tap=\(isTap) dur=\(String(format: "%.3f", duration)) dist=\(String(format: "%.1f", s.maxDist))mm size=\(s.maxSize)")

        switch s.kind {
        case .corner(let corner):
            gate.end(dropClicksFor: isTap ? 0.45 : 0, giveBack: !isTap && !s.holdFired)
            if isTap {
                let b = cfg.corners.binding(corner)
                zoneTap(s.kind, s, tap: b.tap, doubleTap: b.doubleTap, window: cfg.corners.doubleTapWindow,
                        haptic: .confirm, gesture: "cornerTap")
            }
        case .edge(let e):
            let b = cfg.edges.binding(e)
            // A one-shot swipe that ended short of the threshold still counts if it clearly moved sideways.
            let travelled = s.lastAlong - s.stepAnchor
            if s.activated && b.slide == "actions" && !b.repeats && s.steps == 0 && abs(travelled) >= liftSwipe {
                gate.end(dropClicksFor: 0.3)
                fire(travelled > 0 ? b.forward : b.backward, haptic: .media, gesture: "edgeSwipe", zone: s.kind,
                     how: Self.slideWords(e, forward: travelled > 0))
                return
            }
            if isTap && (!b.tap.isNone || !b.doubleTap.isNone) {
                gate.end(dropClicksFor: 0.45)
                zoneTap(s.kind, s, tap: b.tap, doubleTap: b.doubleTap, window: cfg.corners.doubleTapWindow,
                        haptic: .media, gesture: "edgeTap")
            } else {
                gate.end(dropClicksFor: s.activated ? 0.3 : 0, giveBack: !s.activated && s.steps == 0 && !s.holdFired)
            }
            if s.activated && b.continuous { SliderController.shared.end() }
            if b.isSwitcher { SwitcherHold.release() }
            if s.activated && b.isScroll && cfg.edges.momentum && abs(s.velocity.velocity) >= Self.scrollMomentumStart {
                startMomentum(e, velocity: s.velocity.velocity, accum: 0, scroll: true)
            }
            if s.activated && b.slide == "actions" && b.repeats {
                let v = s.velocity.velocity
                lastSlide = (e, s.lastAlong >= s.stepAnchor ? 1 : -1, time)
                if cfg.edges.momentum && abs(v) >= Self.momentumStart {
                    startMomentum(e, velocity: v * (1 + 0.25 * Double(consecutive)), accum: s.stepAccum)
                }
            }
        }
    }

    /// Runs an action and tells the UI what happened. `how` is the gesture in words ("Slide right").
    private func fire(_ action: Action, haptic: Haptic = .confirm, gesture: String = "", zone: Kind? = nil, how: String = "") {
        guard !action.isNone else { return }
        if let sink = Self.testSink { sink(gesture, action); return }
        let where_ = zone.map(Self.zoneName) ?? ""
        guard action.isComplete else {
            // Detected, but the action needs a value (an app, keys, …): say so instead of doing nothing.
            debugLog("incomplete action \(action.type) on \(where_) \(how)")
            Haptics.play(.tick)
            KeyCast.shared.message("exclamationmark.circle", "Finish setting up \(where_.isEmpty ? "this gesture" : where_)")
            announce(gesture, zone: zone, text: "\(how) → not set up yet")
            return
        }
        debugLog("fire \(action.type) \(action.value ?? "") on \(where_) \(how)")
        Haptics.play(haptic)
        Actions.perform(action)
        announce(gesture, zone: zone, text: "\(how) → \(ActionCatalog.label(action))")
    }

    private func announce(_ gesture: String, zone: Kind? = nil, text: String = "") {
        guard !gesture.isEmpty else { return }
        var info: [String: Any] = ["text": text]
        if let zone { info["zone"] = Self.zoneID(zone) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .gesturePerformed, object: gesture, userInfo: info) }
    }

    static func zoneID(_ k: Kind) -> ZoneID {
        switch k { case .edge(let e): return .edge(e); case .corner(let c): return .corner(c) }
    }

    static func zoneName(_ k: Kind) -> String {
        switch k {
        case .edge(let e): return e.title.lowercased()
        case .corner(let c):
            return ["topLeft": "top-left", "topRight": "top-right", "bottomLeft": "bottom-left", "bottomRight": "bottom-right"][c.rawValue]! + " corner"
        }
    }

    /// Speed boost for edge actions: 1× when slow (≤ 40 mm/s) up to 2.5× when fast (≥ 220 mm/s).
    /// Eased and capped, like Mac Mouse Fix's capped acceleration curves: 1× at ≤ 40 mm/s, 2.5× at ≥ 220 mm/s.
    static func swipeBoost(_ speed: Double) -> Double {
        1 + 1.5 * Acceleration.smoothstep((speed - 40) / 180)
    }

    // MARK: - Momentum

    private func startMomentum(_ e: Edge, velocity: Double, accum: Double, scroll: Bool = false) {
        momentumToken += 1
        momentum = Momentum(edge: e, velocity: velocity, accum: accum, token: momentumToken, scroll: scroll)
        let token = momentumToken
        momentumQueue.asyncAfter(deadline: .now() + 1.0 / 90) { [weak self] in self?.momentumTick(token, last: Date()) }
    }

    private func momentumTick(_ token: Int, last: Date) {
        lock.lock(); defer { lock.unlock() }
        guard var m = momentum, m.token == token else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(last), 1.0 / 30)
        let cfg = Self.testConfig ?? AppContext.shared.effectiveConfig
        let b = cfg.edges.binding(m.edge)
        guard cfg.enabled, (b.slide == "actions" && b.repeats) || b.isScroll else { momentum = nil; return }

        // Integrate drag, then convert travelled distance into steps (or scroll pixels).
        let speed = abs(m.velocity)
        let drag = m.scroll ? Self.scrollDragK : Self.dragK
        let newSpeed = max(0, speed - drag * pow(speed, Self.dragP) * dt)
        m.velocity = m.velocity < 0 ? -newSpeed : newSpeed
        if m.scroll {
            ScrollOutput.scroll(alongMM: m.velocity * dt, vertical: m.edge.vertical, gain: 1.6)
            if newSpeed < Self.momentumStop { momentum = nil; return }
            momentum = m
            momentumQueue.asyncAfter(deadline: .now() + 1.0 / 90) { [weak self] in self?.momentumTick(token, last: now) }
            return
        }
        m.accum += m.velocity * dt          // glide covers ≈ (v₀ − stop) / k mm: 3–4 steps after a fast flick
        let step = max(4, b.stepMM)
        while abs(m.accum) >= step {
            let dir: Double = m.accum > 0 ? 1 : -1
            fire(dir > 0 ? b.forward : b.backward, haptic: .tick, gesture: "edgeMomentum", zone: .edge(m.edge),
                 how: Self.slideWords(m.edge, forward: dir > 0) + " (momentum)")
            m.accum -= dir * step
        }
        if newSpeed < Self.momentumStop { momentum = nil; return }
        momentum = m
        momentumQueue.asyncAfter(deadline: .now() + 1.0 / 90) { [weak self] in self?.momentumTick(token, last: now) }
    }

    private static func slideWords(_ e: Edge, forward: Bool) -> String {
        e.vertical ? (forward ? "Slide up" : "Slide down") : (forward ? "Slide right" : "Slide left")
    }

    // MARK: - Double tap (corners and edges)

    private struct PendingTap { let kind: Kind; let endedAt: Double; let x: Double; let y: Double; let work: DispatchWorkItem }
    private var pendingTap: PendingTap?

    /// A tap fires at once unless the zone also has a double-tap action; then it waits `window` for a second tap.
    private func zoneTap(_ kind: Kind, _ s: Session, tap: Action, doubleTap: Action, window: Double,
                         haptic: Haptic, gesture: String) {
        // The second tap of a double-tap naturally follows the first; every other tap must be isolated.
        let secondTap = pendingTap.map { $0.kind == kind && s.t0 - $0.endedAt <= window } ?? false
        if !secondTap && !isIsolated(s) {
            debugLog("tap ignored: not isolated (repeated touches at this spot)")
            return
        }
        if doubleTap.isNone {
            fire(tap, haptic: haptic, gesture: gesture, zone: kind, how: "Tap")
            return
        }
        if let p = pendingTap, p.kind == kind, s.t0 - p.endedAt <= window, s.t0 - p.endedAt >= Self.doubleTapMinGap,
           hypot(s.sx - p.x, s.sy - p.y) < 8 {
            p.work.cancel()
            pendingTap = nil
            fire(doubleTap, haptic: .doubleTap, gesture: gesture.replacingOccurrences(of: "Tap", with: "DoubleTap"),
                 zone: kind, how: "Double-tap")
            return
        }
        pendingTap?.work.cancel()
        let work = DispatchWorkItem { [weak self] in self?.firePendingTap(kind, haptic: haptic, gesture: gesture) }
        pendingTap = PendingTap(kind: kind, endedAt: lastFrameTime, x: s.sx, y: s.sy, work: work)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + window, execute: work)
    }

    private func firePendingTap(_ kind: Kind, haptic: Haptic, gesture: String) {
        lock.lock(); defer { lock.unlock() }
        guard let p = pendingTap, p.kind == kind else { return }
        // A second touch is already down in this zone: let its finish decide.
        if let s = session, s.kind == kind {
            let work = DispatchWorkItem { [weak self] in self?.firePendingTap(kind, haptic: haptic, gesture: gesture) }
            pendingTap = PendingTap(kind: p.kind, endedAt: p.endedAt, x: p.x, y: p.y, work: work)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05, execute: work)
            return
        }
        pendingTap = nil
        let cfg = Self.testConfig ?? AppContext.shared.effectiveConfig
        let tap: Action
        switch kind {
        case .corner(let c): tap = cfg.corners.binding(c).tap
        case .edge(let e): tap = cfg.edges.binding(e).tap
        }
        fire(tap, haptic: haptic, gesture: gesture, zone: kind, how: "Tap")
    }

    // MARK: - Per-zone updates (return false if the session ended)

    /// Position along the edge's axis (y for left/right, x for top/bottom), mm.
    private func along(_ e: Edge, _ x: Double, _ y: Double) -> Double { e.vertical ? y : x }

    private func updateEdge(_ s: inout Session, _ e: Edge, _ c: Contact, _ time: Double, _ cfg: Config) -> Bool {
        let b = cfg.edges.binding(e)
        let pos = along(e, c.xmm, c.ymm)

        // Press & hold: still finger for `holdTime`, before any sliding.
        if !s.activated, !s.holdFired, !b.hold.isNone, s.maxDist < holdSlop, time - s.t0 >= cfg.corners.holdTime {
            s.holdFired = true
            fire(b.hold, haptic: .doubleTap, gesture: "edgeHold", zone: s.kind, how: "Press & hold")
        }
        if s.holdFired { return true }

        if !s.activated {
            let d = pos - along(e, s.sx, s.sy)
            let perp = e.vertical ? abs(c.xmm - s.sx) : abs(c.ymm - s.sy)
            if perp > leaveEdge && perp > abs(d) { abort("left the edge"); return false }
            guard abs(d) > engageDistance else {
                if time - s.t0 > cfg.guardrails.activationWindow && s.maxDist < engageDistance && !b.touches {
                    abort("resting on edge")   // a resting palm/thumb never becomes a slider
                    return false
                }
                return true
            }
            if abs(d) < perp * edgeAngle { abort("diagonal, not along the edge"); return false }
            if time - s.t0 > cfg.guardrails.activationWindow { abort("slow drift"); return false }
            guard b.slides else { abort("edge has no slide action"); return false }

            s.activated = true
            Haptics.play(.tick)          // the drag has caught: one light tick, like grabbing a slider in macOS
            if b.slide == "actions" && b.repeats {
                let dir: Double = d > 0 ? 1 : -1
                if cfg.edges.repeatSpeedup, let l = lastSlide, l.edge == e, l.dir == dir, time - l.end < 0.6 {
                    consecutive = min(consecutive + 1, 4)
                } else {
                    consecutive = 0
                }
            }
            s.filter.reset()
            s.velocity.reset()
            // Start from the touch-down point so the engage distance isn't lost.
            s.lastAlong = s.filter.filter(along(e, s.sx, s.sy), time: time - 0.008)
            s.stepAnchor = s.lastAlong
            gate.setCaptureAll()
            if b.continuous, let kind = SliderController.Kind(rawValue: b.slide) {
                SliderController.shared.begin(kind)
                announce("slider")
            }
            if b.isScroll { ScrollOutput.reset(); announce("edgeScroll", zone: s.kind, text: "Scrolling") }
        }

        let a = s.filter.filter(pos, time: time)
        s.velocity.add(a, time)
        defer { s.lastAlong = a }

        if b.continuous {
            SliderController.shared.drag(deltaMM: a - s.lastAlong, speed: abs(s.velocity.velocity), time: time)
            return true
        }

        // Edge scrolling: accelerated like the pointer, fractions of a pixel carried over.
        if b.isScroll {
            let gain = Self.swipeBoost(abs(s.velocity.velocity)) * cfg.edges.speed
            ScrollOutput.scroll(alongMM: a - s.lastAlong, vertical: e.vertical, gain: gain)
            return true
        }

        // App switcher: every step moves the Cmd-Tab selection; Cmd is released when the finger lifts.
        if b.isSwitcher {
            s.stepAccum += a - s.lastAlong
            let step = max(6, b.stepMM)
            while abs(s.stepAccum) >= step {
                let forward = s.stepAccum > 0
                SwitcherHold.step(forward: e.vertical ? !forward : forward)   // down / right = next app
                Haptics.play(.tick)
                s.stepAccum -= forward ? step : -step
                s.steps += 1
            }
            return true
        }

        // Actions mode: forward = up / right, backward = down / left.
        // Speed counts like pointer acceleration: a fast short swipe goes as far as a slow long one.
        let step = max(4, b.stepMM)
        let boost = Self.swipeBoost(abs(s.velocity.velocity))
        if b.repeats {
            s.stepAccum += (a - s.lastAlong) * boost * (1 + 0.25 * Double(consecutive))
            var n = 0
            while abs(s.stepAccum) >= step && n < maxStepsPerFrame {
                let dir: Double = s.stepAccum > 0 ? 1 : -1
                fire(dir > 0 ? b.forward : b.backward, haptic: .tick, gesture: "edgeSlide", zone: s.kind,
                     how: Self.slideWords(e, forward: dir > 0))
                s.stepAccum -= dir * step
                s.steps += 1
                n += 1
            }
            if n == maxStepsPerFrame { s.stepAccum = 0 }   // don't queue up a backlog
        } else if s.steps == 0 {
            let travelled = a - s.stepAnchor
            if abs(travelled) * boost >= step {
                s.steps = 1
                fire(travelled > 0 ? b.forward : b.backward, haptic: .media, gesture: "edgeSwipe", zone: s.kind,
                     how: Self.slideWords(e, forward: travelled > 0))
            }
        }
        return true
    }

    private func updateCorner(_ s: inout Session, _ c: Contact, _ time: Double, _ cfg: Config, _ corner: Corner) -> Bool {
        let b = cfg.corners.binding(corner)
        let dx = c.xmm - s.sx, dy = c.ymm - s.sy

        // Press & hold: still finger for `holdTime`.
        if !s.holdFired, !b.hold.isNone, s.maxDist < holdSlop, time - s.t0 >= cfg.corners.holdTime {
            s.holdFired = true
            fire(b.hold, haptic: .doubleTap, gesture: "cornerHold", zone: s.kind, how: "Press & hold")
        }
        guard hypot(dx, dy) > cornerSlop, !s.holdFired else { return true }

        // A corner touch that slides along an edge becomes that edge's gesture.
        let isLeft = corner == .topLeft || corner == .bottomLeft
        let isBottom = corner == .bottomLeft || corner == .bottomRight
        if cfg.edges.enabled {
            if abs(dy) > abs(dx) * edgeAngle, cfg.edges.binding(isLeft ? .left : .right).slides {
                s.kind = .edge(isLeft ? .left : .right)
                return true
            }
            if abs(dx) > abs(dy) * edgeAngle, cfg.edges.binding(isBottom ? .bottom : .top).slides {
                s.kind = .edge(isBottom ? .bottom : .top)
                return true
            }
        }
        abort("moved out of corner")
        return false
    }
}
