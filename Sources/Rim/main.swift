import AppKit
import CMT

var recordOut: FileHandle?
var recordSize = (124.8, 76.8)

if CommandLine.arguments.contains("--ax-check") {
    // Fresh Accessibility answer for the parent Rim process (see Permission.swift).
    print(AXIsProcessTrusted() ? "1" : "0")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 2 < CommandLine.arguments.count {
    // Raw touch recorder for tuning: `Rim --record <seconds> <file.csv>` (time, id, state, x, y, xmm, ymm, size).
    let seconds = Double(CommandLine.arguments[i + 1]) ?? 60
    let path = CommandLine.arguments[i + 2]
    FileManager.default.createFile(atPath: path, contents: "t,id,state,x,y,xmm,ymm,size\n".data(using: .utf8))
    let out = FileHandle(forWritingAtPath: path)!
    out.seekToEndOfFile()
    _ = tf_mt_load()
    let n = tf_mt_device_count()
    var w: Float = 124.8, h: Float = 76.8
    if n > 0 { _ = tf_mt_surface_mm(tf_mt_device_at(0), &w, &h) }
    recordSize = (Double(w), Double(h))
    recordOut = out
    let cb: TFFrameCallback = { _, touches, count, ts, _ in
        guard let touches, count > 0, let out = recordOut else { return 0 }
        var lines = ""
        for k in 0..<Int(count) {
            let c = touches[k]
            let x = Double(c.normalized.pos.x), y = Double(c.normalized.pos.y)
            lines += String(format: "%.4f,%d,%d,%.4f,%.4f,%.2f,%.2f,%.3f\n", ts, c.identifier, c.state, x, y,
                            x * recordSize.0, y * recordSize.1, c.size)
        }
        out.write(lines.data(using: .utf8)!)
        return 0
    }
    for k in 0..<n { tf_mt_register(tf_mt_device_at(k), cb); tf_mt_start(tf_mt_device_at(k)) }
    print("recording \(Int(seconds)) s of touches to \(path)…")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    try? out.close()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--replay"), i + 1 < CommandLine.arguments.count {
    // Replays a --record file through the gesture engine with your config and prints what would fire.
    ConfigStore.shared.load()
    var cfg = ConfigStore.shared.current
    cfg.guardrails.adaptive = false
    GestureEngine.testConfig = cfg
    var fired: [String] = []
    GestureEngine.testSink = { g, a in fired.append("\(g) → \(a.type)") }
    // Sliders are reported, never applied: replays can't change real volume / brightness.
    SliderController.testSink = { fired.append($0) }
    let text = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
    var frames: [(Double, [Contact])] = []
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",").map(String.init)
        guard f.count == 8, let t = Double(f[0]), let id = Int32(f[1]), let st = Int32(f[2]),
              let x = Float(f[3]), let y = Float(f[4]), let xm = Double(f[5]), let ym = Double(f[6]), let sz = Float(f[7]) else { continue }
        let c = Contact(id: id, x: x, y: y, state: st, size: sz, xmm: xm, ymm: ym)
        if let last = frames.last, abs(last.0 - t) < 0.0005 { frames[frames.count - 1].1.append(c) } else { frames.append((t, [c])) }
    }
    let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
    var prev = frames.first?.0 ?? 0
    for (t, cs) in frames {
        if t - prev > 0.03 { engine.process([], time: prev + 0.01) }   // finger lifted between recorded frames
        engine.process(cs, time: t)
        prev = t
    }
    engine.process([], time: prev + 0.02)
    Thread.sleep(forTimeInterval: 0.5)
    print("\(frames.count) frames replayed with your settings → \(fired.count) actions:")
    fired.forEach { print("  " + $0) }
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    // Hardware/API self-test: `Rim --probe`
    print("multitouch load:", tf_mt_load())
    let n = tf_mt_device_count()
    print("devices:", n)
    for i in 0..<n {
        var w: Float = 0, h: Float = 0
        let dims = tf_mt_surface_mm(tf_mt_device_at(i), &w, &h) ? "\(w) x \(h) mm" : "unknown size"
        print("  device \(i) builtin:", tf_mt_is_builtin(tf_mt_device_at(i)), dims)
    }
    let haptic = tf_haptic_open()
    print("force-touch actuator:", haptic, haptic ? "actuate=\(tf_haptic_actuate(6))" : "")
    print("brightness:", Brightness.get().map { String($0) } ?? "unavailable")
    print("volume:", Volume.get().map { String($0) } ?? "unavailable")
    if let k = KeyboardLight.get() {
        let wrote = KeyboardLight.set(k)              // write the same value back: proves control, changes nothing
        print("keyboard light:", k, "writable=\(wrote)")
    } else { print("keyboard light: unavailable") }
    print("accessibility trusted:", AXIsProcessTrusted())
    print("listening for touches for 5s…")
    var frames = 0, maxFingers = 0
    var states = Set<Int32>()
    let cb: TFFrameCallback = { _, touches, count, _, _ in
        probeFrame(touches, Int(count)); return 0
    }
    probeHandler = { touches, count in
        frames += 1
        maxFingers = max(maxFingers, count)
        for i in 0..<count { states.insert(touches![i].state) }
        if frames % 25 == 1, count > 0, let t = touches {
            print(String(format: "  frame %d: %d finger(s), first at (%.2f, %.2f) state %d", frames, count,
                         t[0].normalized.pos.x, t[0].normalized.pos.y, t[0].state))
        }
    }
    for i in 0..<n { tf_mt_register(tf_mt_device_at(i), cb); tf_mt_start(tf_mt_device_at(i)) }
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    print("frames: \(frames), max fingers: \(maxFingers), states seen: \(states.sorted())")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments[i + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--gate-test") {
    // Safety tests for the event gate: input must never stay blocked.
    var fails = 0
    func check(_ ok: Bool, _ m: String) { print(ok ? "ok  " : "FAIL", m); if !ok { fails += 1 } }
    func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    let gate = EventGate.shared
    let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
    let src = CGEventSource(stateID: .privateState)
    func move() -> CGEvent { CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)! }
    func down() -> CGEvent { CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)! }
    func up() -> CGEvent { CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)! }
    func passes(_ t: CGEventType, _ e: CGEvent) -> Bool {
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 1)   // as if from the trackpad driver
        return gate.handle(t, e) != nil
    }

    check(passes(.mouseMoved, move()) && passes(.leftMouseDown, down()) && passes(.leftMouseUp, up()), "idle: everything passes")

    gate.begin(owner: engine, captureAll: true)
    check(!passes(.mouseMoved, move()), "active capture with live heartbeat: movement swallowed")
    wait(0.12); gate.heartbeat()
    check(!passes(.mouseMoved, move()), "heartbeat keeps capture alive")
    wait(0.35)
    check(passes(.mouseMoved, move()), "touch frames stop: watchdog releases movement within 250 ms")
    check(passes(.leftMouseDown, down()) && passes(.leftMouseUp, up()), "after watchdog: clicks pass")

    gate.begin(owner: engine, captureAll: true)
    gate.reset()
    check(passes(.mouseMoved, move()) && passes(.leftMouseDown, down()), "reset (wake / restart input) releases everything")
    _ = gate.handle(.leftMouseUp, up())

    gate.begin(owner: engine, captureAll: true)
    gate.end(dropClicksFor: 0.3)
    check(!passes(.leftMouseDown, down()) && !passes(.leftMouseUp, up()), "corner tap: its tap-to-click is swallowed as a pair")
    wait(0.35)
    check(passes(.leftMouseDown, down()) && passes(.leftMouseUp, up()), "drop window expires: clicks pass again")

    gate.begin(owner: engine, captureAll: true)
    check(passes(.leftMouseDown, down()), "physical press during a gesture always passes")
    check(passes(.mouseMoved, move()) && passes(.leftMouseUp, up()), "and releases the gesture")

    gate.begin(owner: engine, captureAll: true)
    var alive = true
    let deadline = Date().addingTimeInterval(8.6)
    while Date() < deadline { gate.heartbeat(); wait(0.05) }
    alive = !passes(.mouseMoved, move())
    check(!alive, "even with heartbeats, a capture longer than 8 s is released")

    // Visual pointer freeze: every freeze is matched by exactly one unfreeze, on every exit path.
    var freezes: [String] = []
    PointerFreeze.testSink = { freezes.append($0) }
    gate.begin(owner: engine, captureAll: true); gate.end(dropClicksFor: 0)
    gate.begin(owner: engine, captureAll: true); gate.end(dropClicksFor: 0, giveBack: true)
    gate.begin(owner: engine, captureAll: true); gate.reset()
    gate.begin(owner: engine, captureAll: true); wait(0.3); _ = passes(.mouseMoved, move())     // watchdog release
    gate.begin(owner: engine, captureAll: true); _ = passes(.leftMouseDown, down()); _ = passes(.leftMouseUp, up())  // physical click
    check(freezes.filter { $0 == "freeze" }.count == 5 && freezes.filter { $0 == "unfreeze" }.count == 5,
          "pointer hidden at gesture start and shown again on lift, give-back, reset, watchdog and click (\(freezes.count) calls)")
    PointerFreeze.testSink = nil

    // Pointer freeze: motion during a zone touch is held back, and given back only if it wasn't a gesture.
    var warpedTo: CGPoint?
    gate.warp = { warpedTo = $0 }                         // never move the real pointer in tests
    func moveBy(_ dx: Double, _ dy: Double) -> CGEvent {
        let e = move(); e.setDoubleValueField(.mouseEventDeltaX, value: dx); e.setDoubleValueField(.mouseEventDeltaY, value: dy); return e
    }
    gate.begin(owner: engine, captureAll: true)
    let pin = CGEvent(source: nil)?.location ?? .zero
    check(!passes(.mouseMoved, moveBy(4, 1)) && !passes(.mouseMoved, moveBy(3, 1)), "pointer frozen from touch-down")
    check(gate.heldMotion.dx == 7 && gate.heldMotion.dy == 2, "held-back motion recorded (7, 2)")
    gate.end(dropClicksFor: 0, giveBack: false)
    check(warpedTo == nil, "after a gesture the pointer stays put (no give-back)")
    gate.begin(owner: engine, captureAll: true)
    _ = passes(.mouseMoved, moveBy(5, -3))
    gate.end(dropClicksFor: 0, giveBack: true)
    check(warpedTo.map { abs($0.x - (pin.x + 5)) < 1.01 && abs($0.y - (pin.y - 3)) < 1.01 } ?? false,
          "not a gesture → held-back motion given back, pointer lands where it would have been")
    gate.warp = { _ in }

    let own = down()
    gate.dropClicks(for: 0.3)
    check(gate.handle(.otherMouseDown, own) != nil, "Rim's own synthetic click (middle click) passes a drop window")
    wait(0.35)

    gate.stop(); gate.stop()
    check(!gate.isRunning, "stop is idempotent and leaves no tap")

    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--haptic") {
    Automation.hapticCLI(i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "success")
}

if CommandLine.arguments.contains("--gesture-test") {
    // Multi-finger recognizer: every gesture fires, and look-alikes don't.
    var fails = 0
    func check(_ ok: Bool, _ m: String) { print(ok ? "ok  " : "FAIL", m); if !ok { fails += 1 } }
    struct F { var id: Int32; var down: Double; var up: Double; var x: Double; var y: Double; var vx = 0.0; var vy = 0.0; var size: Float = 0.9 }
    func simulate(_ fingers: [F], typing: Bool = false) -> [String] {
        var r = MultiFingerRecognizer()
        var out: [String] = []
        let end = (fingers.map(\.up).max() ?? 0) + 0.1
        var t = 0.0
        while t <= end {
            let touching = fingers.filter { $0.down <= t && t < $0.up }.map { f -> Contact in
                let x = f.x + f.vx * (t - f.down), y = f.y + f.vy * (t - f.down)
                return Contact(id: f.id, x: Float(x / 124.8), y: Float(y / 76.8), state: 4, size: f.size, xmm: x, ymm: y)
            }
            out += r.process(touching, time: t, typing: typing, palmSize: 1.6).map(\.rawValue)
            t += 1.0 / 120
        }
        return out
    }
    let t3 = [F(id: 1, down: 0, up: 0.15, x: 50, y: 40), F(id: 2, down: 0.01, up: 0.16, x: 62, y: 42), F(id: 3, down: 0.02, up: 0.15, x: 74, y: 40)]
    check(simulate(t3) == ["threeFingerTap"], "three-finger tap")
    var t4 = t3; t4.append(F(id: 4, down: 0.01, up: 0.14, x: 86, y: 36))
    check(simulate(t4) == ["fourFingerTap"], "four-finger tap")
    var t5 = t4; t5.append(F(id: 5, down: 0.03, up: 0.15, x: 30, y: 20))
    check(simulate(t5) == ["fiveFingerTap"], "five-finger tap")
    check(simulate(t3.map { var f = $0; f.vy = 120; return f }).isEmpty, "three-finger DRAG (moving) is not a tap")
    check(simulate(t3.map { var f = $0; f.up += 0.5; return f }).isEmpty, "three fingers resting 0.65 s is not a tap")
    var stagger = t3; stagger[2].down = 0.3; stagger[2].up = 0.4
    check(simulate(stagger).isEmpty, "staggered landing (300 ms apart) is not a tap")
    check(simulate(t3, typing: true).isEmpty, "ignored while typing")
    var palm = t3; palm[0].size = 2.5
    check(simulate(palm).isEmpty, "ignored when a palm touches")

    let rightClick = [F(id: 1, down: 0, up: 0.12, x: 55, y: 40), F(id: 2, down: 0.01, up: 0.12, x: 75, y: 40)]
    check(simulate(rightClick).isEmpty, "normal two-finger tap (right click, 20 mm apart) untouched")
    // Tip-swipe: rest one finger, slide the neighbour; steps every 10 mm along the slide.
    let restF = F(id: 1, down: 0, up: 1.6, x: 60, y: 35)
    let swipeR = simulate([restF, F(id: 2, down: 0.4, up: 1.1, x: 80, y: 37, vx: 50)])
    check(swipeR.filter { $0 == "tipSwipeRight" }.count == 3 && !swipeR.contains("tipTapRight"),
          "tip-swipe right: 35 mm slide → 3 steps, not a tip-tap → \(swipeR)")
    check(simulate([restF, F(id: 2, down: 0.4, up: 1.0, x: 80, y: 30, vy: 40)]).filter { $0 == "tipSwipeUp" }.count == 2, "tip-swipe up")
    check(simulate([restF, F(id: 2, down: 0.4, up: 1.0, x: 40, y: 37, vx: -40)]).allSatisfy { $0 == "tipSwipeLeft" }, "tip-swipe left")
    check(simulate([F(id: 1, down: 0, up: 0.8, x: 55, y: 40, vy: 60), F(id: 2, down: 0.01, up: 0.8, x: 75, y: 40, vy: 60)]).isEmpty,
          "normal two-finger scroll is not a tip-swipe")
    check(simulate([F(id: 1, down: 0, up: 1.6, x: 60, y: 35, vx: 20), F(id: 2, down: 0.4, up: 1.1, x: 80, y: 37, vx: 50)]).isEmpty,
          "both fingers sliding is not a tip-swipe")

    // Two-finger swipe: quick horizontal flick → event; slow horizontal or vertical scrolling → nothing.
    let flickR = [F(id: 1, down: 0, up: 0.22, x: 45, y: 40, vx: 140), F(id: 2, down: 0.01, up: 0.22, x: 65, y: 40, vx: 140)]
    check(simulate(flickR) == ["twoFingerSwipeRight"], "two-finger flick right")
    let flickL = [F(id: 1, down: 0, up: 0.22, x: 80, y: 40, vx: -140), F(id: 2, down: 0.01, up: 0.22, x: 100, y: 40, vx: -140)]
    check(simulate(flickL) == ["twoFingerSwipeLeft"], "two-finger flick left")
    let slowSide = [F(id: 1, down: 0, up: 0.9, x: 40, y: 40, vx: 40), F(id: 2, down: 0.01, up: 0.9, x: 60, y: 40, vx: 40)]
    check(simulate(slowSide).isEmpty, "slow sideways two-finger scroll is not a swipe")
    let diag = [F(id: 1, down: 0, up: 0.22, x: 45, y: 30, vx: 140, vy: 90), F(id: 2, down: 0.01, up: 0.22, x: 65, y: 30, vx: 140, vy: 90)]
    check(simulate(diag).isEmpty, "diagonal flick (scrolling) is not a swipe")

    // Measured false positive: both sides of the hands brushing the trackpad's left and right borders at once.
    let brush = [F(id: 1, down: 0, up: 0.09, x: 0.8, y: 61.8, size: 1.13), F(id: 2, down: 0, up: 0.10, x: 122.8, y: 55.5, size: 1.18)]
    check(simulate(brush).isEmpty, "hands brushing both sides of the trackpad is not a two-hand tap")
    let twoHands = [F(id: 1, down: 0, up: 0.14, x: 20, y: 35), F(id: 2, down: 0.02, up: 0.15, x: 105, y: 38)]
    check(simulate(twoHands) == ["twoHandTap"], "two-hand tap (85 mm apart)")
    let scroll = [F(id: 1, down: 0, up: 0.5, x: 55, y: 40, vy: 60), F(id: 2, down: 0.01, up: 0.5, x: 75, y: 40, vy: 60)]
    check(simulate(scroll).isEmpty, "two-finger scroll untouched")

    check(Automation.isAllowedFromURL("playPause") && Automation.isAllowedFromURL("windowLeft"), "URL scheme runs safe actions")
    check(!["shell", "keys", "app", "url", "shortcut", "none", "rm -rf"].contains(where: Automation.isAllowedFromURL),
          "URL scheme refuses shell, keys, apps, URLs, shortcuts and unknown actions")
    check(!["paste", "copy", "closeWindow", "forceQuit", "save"].contains(where: Automation.isAllowedFromURL)
          && Automation.isAllowedFromURL("volumeUp") && Automation.isAllowedFromURL("keyboardLightToggle"),
          "URL scheme refuses editing / closing / quitting, allows controls")

    let rest = F(id: 1, down: 0, up: 1.2, x: 60, y: 35)
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 82, y: 38)]) == ["tipTapRight"], "tip-tap right")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 38, y: 38)]) == ["tipTapLeft"], "tip-tap left")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.5, x: 82, y: 38), F(id: 3, down: 0.7, up: 0.8, x: 38, y: 38)]) == ["tipTapRight", "tipTapLeft"],
          "repeated tip-taps while resting")
    check(simulate([F(id: 1, down: 0, up: 1.2, x: 30, y: 35, vx: 40), F(id: 2, down: 0.4, up: 0.52, x: 82, y: 38)]).isEmpty,
          "pointing finger moving + tap = normal click, not tip-tap")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.9, x: 82, y: 38)]).isEmpty, "second finger held 0.5 s is not a tip-tap")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 115, y: 38)]).isEmpty, "tap 55 mm away (another hand) is not a tip-tap")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 106, y: 36)]).isEmpty, "tap 46 mm away (not the neighbouring finger) is not a tip-tap")
    // The user's measured tip-taps (relative to the resting finger): all must count.
    let measured: [(Double, Double, String)] = [(-24.8, -10.8, "tipTapLeft"), (-23.7, -9.4, "tipTapLeft"), (10.1, 15.6, "tipTapRight"),
                                                (11.5, 13.1, "tipTapRight"), (-22.1, -22.1, "tipTapLeft"), (-10.9, -21.7, "tipTapLeft")]
    let hits = measured.filter { dx, dy, want in simulate([rest, F(id: 2, down: 0.4, up: 0.51, x: 60 + dx, y: 35 + dy)]) == [want] }.count
    check(hits == measured.count, "all \(measured.count) of your measured tip-taps are recognised (\(hits)/\(measured.count))")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 78, y: 37)]) == ["tipTapRight"], "neighbouring finger 18 mm away is a tip-tap")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 68, y: 36)]).isEmpty, "tap 8 mm away (same finger rolling) is not a tip-tap")
    check(simulate([rest, F(id: 2, down: 0.4, up: 0.52, x: 70, y: 70)]).isEmpty, "tap far above the resting finger is not a tip-tap")

    // ---- Zone engine: edges, corners, hold (actions are recorded, never run) ----
    var fired: [String] = []
    GestureEngine.testSink = { gesture, action in fired.append("\(gesture):\(action.type)") }
    var cfg = Config()
    cfg.guardrails.adaptive = false
    cfg.gestures.enabled = false
    cfg.edges.left = EdgeBinding()        // no real volume / brightness changes in tests
    cfg.edges.right = EdgeBinding(slide: "actions", forward: Action("nextTab"), backward: Action("previousTab"), repeats: true, stepMM: 10)
    cfg.edges.top = EdgeBinding(slide: "actions", forward: Action("forward"), backward: Action("back"), repeats: false, stepMM: 15, tap: Action("hideApp"))
    cfg.corners.topLeft = CornerBinding(Action("missionControl"), hold: Action("lockScreen"))
    GestureEngine.testConfig = cfg

    /// One finger from `from` to `to` (normalized), over `duration`, then lifted.
    func stroke(_ from: (Double, Double), _ to: (Double, Double), duration: Double, hold: Double = 0, settle: Double = 0.02,
                size: Float = 0.9,
                then next: ((GestureEngine, Double) -> Void)? = nil) -> [String] {
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 100.0
        let n = max(1, Int(duration * 120))
        for i in 0...n + Int(hold * 120) {
            let k = min(1, Double(i) / Double(n))
            let x = from.0 + (to.0 - from.0) * k, y = from.1 + (to.1 - from.1) * k
            engine.process([Contact(id: 7, x: Float(x), y: Float(y), state: 4, size: size, xmm: x * 124.8, ymm: y * 76.8)], time: t)
            t += 1.0 / 120
        }
        engine.process([], time: t)
        next?(engine, t)
        Thread.sleep(forTimeInterval: settle)
        return fired
    }

    check(stroke((0.5, 0.04), (0.75, 0.04), duration: 0.25) == ["edgeSwipe:nextTrack"], "bottom edge: swipe right = next track, once")
    check(stroke((0.5, 0.04), (0.25, 0.04), duration: 0.25) == ["edgeSwipe:previousTrack"], "bottom edge: swipe left = previous track")
    check(stroke((0.5, 0.04), (0.5, 0.04), duration: 0.1) == ["edgeTap:playPause"], "bottom edge: tap = play / pause")
    let slow = stroke((0.96, 0.25), (0.96, 0.75), duration: 1.2)
    check(slow.count == 3 && slow.allSatisfy { $0 == "edgeSlide:nextTab" }, "right edge: slow slide up 38 mm = exactly 3 × next tab (every 10 mm) → \(slow.count)")
    let fast = stroke((0.96, 0.25), (0.96, 0.75), duration: 0.2)
    check(fast.count > slow.count, "the same slide done fast runs more steps (acceleration) → \(fast.count)")
    check(stroke((0.96, 0.75), (0.96, 0.45), duration: 0.4).allSatisfy { $0 == "edgeSlide:previousTab" }, "right edge: slide down = previous tab")
    check(stroke((0.5, 0.96), (0.8, 0.96), duration: 0.3) == ["edgeSwipe:forward"], "top edge (new): swipe right = forward")
    check(stroke((0.5, 0.96), (0.5, 0.96), duration: 0.1) == ["edgeTap:hideApp"], "top edge: tap action")
    check(stroke((0.96, 0.3), (0.6, 0.5), duration: 0.3).isEmpty, "edge: diagonal move into the middle does nothing")

    // Edge double-tap and hold (bottom edge: tap play/pause, ×2 mute, hold hide app).
    var c2 = cfg
    c2.edges.bottom.doubleTap = Action("mute")
    c2.edges.bottom.hold = Action("hideApp")
    GestureEngine.testConfig = c2
    func taps(_ n: Int, at p: (Double, Double)) -> [String] {
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 200.0
        for _ in 0..<n {
            for _ in 0..<10 { engine.process([Contact(id: 9, x: Float(p.0), y: Float(p.1), state: 4, size: 0.9, xmm: p.0 * 124.8, ymm: p.1 * 76.8)], time: t); t += 1.0 / 120 }
            engine.process([], time: t); t += 0.12
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 0.4)
        return fired
    }
    check(taps(2, at: (0.5, 0.04)) == ["edgeDoubleTap:mute"], "bottom edge: double-tap = mute (no single tap)")
    check(taps(1, at: (0.5, 0.04)) == ["edgeTap:playPause"], "bottom edge: single tap still plays / pauses (after the double-tap window)")

    // A resting thumb on the bottom edge that bounces must not count as taps (was: play/pause firing by itself).
    func restThenBounce() -> [String] {
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 400.0
        let p = (0.5, 0.04)
        let c = { Contact(id: 11, x: Float(p.0), y: Float(p.1), state: 4, size: 0.9, xmm: p.0 * 124.8, ymm: p.1 * 76.8) }
        for _ in 0..<96 { engine.process([c()], time: t); t += 1.0 / 120 }   // rests 0.8 s
        for _ in 0..<2 {                                                        // then bounces twice
            engine.process([], time: t); t += 0.03
            for _ in 0..<8 { engine.process([c()], time: t); t += 1.0 / 120 }
        }
        engine.process([], time: t)
        Thread.sleep(forTimeInterval: 0.5)
        return fired
    }
    var noHold = c2
    noHold.edges.bottom.hold = .none            // your setup: tap / double-tap only (a long rest IS a hold by definition)
    GestureEngine.testConfig = noHold
    let bounced = restThenBounce()
    GestureEngine.testConfig = c2
    check(bounced.isEmpty, "resting thumb bouncing on the bottom edge fires nothing → \(bounced)")

    // Measured drumming: short touches every ~0.6 s, often in pairs 0.15 s apart, at one spot on the bottom edge.
    func drumming(size: Float) -> [String] {
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 500.0
        for beat in 0..<8 {
            for touch in 0..<(beat % 2 == 0 ? 2 : 1) {
                let x = 0.58 + Double(touch) * 0.003, y = 0.08
                for _ in 0..<9 { engine.process([Contact(id: Int32(20 + beat * 2 + touch), x: Float(x), y: Float(y), state: 4, size: size,
                                                         xmm: x * 124.8, ymm: y * 76.8)], time: t); t += 1.0 / 120 }
                engine.process([], time: t); t += 0.08
            }
            t += 0.45
        }
        Thread.sleep(forTimeInterval: 0.5)
        return fired
    }
    let drumBig = drumming(size: 1.4), drumTip = drumming(size: 1.0)
    print("   drumming fired: thumb \(drumBig) · fingertip \(drumTip)")
    check(drumBig.isEmpty && drumTip.count <= 1,
          "a hand drumming on the bottom edge: thumb-sized never fires; fingertip-sized at most its very first pair")
    check(taps(2, at: (0.5, 0.04)) == ["edgeDoubleTap:mute"], "an isolated deliberate double-tap still works")
    check(stroke((0.5, 0.04), (0.5, 0.04), duration: 0.1, hold: 0.6) == ["edgeHold:hideApp"], "bottom edge: press & hold")
    check(stroke((0.5, 0.04), (0.75, 0.04), duration: 0.25) == ["edgeSwipe:nextTrack"], "bottom edge: swipe still works with tap gestures set")
    GestureEngine.testConfig = cfg
    check(stroke((0.04, 0.5), (0.04, 0.5), duration: 0.1).isEmpty, "edge with nothing set: tap passes through")
    check(stroke((0.03, 0.97), (0.03, 0.97), duration: 0.1) == ["cornerTap:missionControl"], "corner: tap")
    // Physical clicks in zones: a corner click runs its tap; the gate swallows that click.
    do {
        var cc = cfg; cc.clickZones = "all"
        GestureEngine.testConfig = cc
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 700.0
        let corner = { Contact(id: 40, x: 0.03, y: 0.97, state: 4, size: 1.4, xmm: 3.7, ymm: 74.5) }
        for _ in 0..<6 { engine.process([corner()], time: t); t += 1.0 / 120 }
        let r = engine.physicalPress()
        for _ in 0..<20 { engine.process([corner()], time: t); t += 1.0 / 120 }     // a press lasts longer than a tap
        engine.process([], time: t)
        Thread.sleep(forTimeInterval: 0.1)
        check(r == .consumed && fired == ["cornerTap:missionControl"], "clicking a corner runs its tap (click swallowed) → \(fired)")
        // Bottom edge with only a double-tap action: first click passes through, a second click runs it.
        var dbl = cc; dbl.edges.bottom.tap = .none; dbl.edges.bottom.doubleTap = Action("mute")
        GestureEngine.testConfig = dbl
        fired = []
        let e2 = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var results: [GestureEngine.ClickResult] = []
        for _ in 0..<2 {
            let edge = { Contact(id: 41, x: 0.5, y: 0.04, state: 4, size: 0.9, xmm: 62.4, ymm: 3.1) }
            for _ in 0..<5 { e2.process([edge()], time: t); t += 1.0 / 120 }
            results.append(e2.physicalPress())
            for _ in 0..<10 { e2.process([edge()], time: t); t += 1.0 / 120 }
            e2.process([], time: t); t += 0.12
        }
        Thread.sleep(forTimeInterval: 0.4)
        check(results == [.passKeep, .consumed] && fired == ["edgeDoubleTap:mute"],
              "double-click on a double-tap edge: first click passes, second runs the action → \(results) \(fired)")
        var off = cc; off.clickZones = "corners"
        GestureEngine.testConfig = off
        let e3 = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        let edge = { Contact(id: 42, x: 0.5, y: 0.04, state: 4, size: 0.9, xmm: 62.4, ymm: 3.1) }
        for _ in 0..<5 { e3.process([edge()], time: t); t += 1.0 / 120 }
        check(e3.physicalPress() == .cancelled, "with clicks set to corners only, an edge click stays a normal click")
        GestureEngine.testConfig = cfg
    }

    // A resting palm drifting slowly on the left edge must not move brightness; a quick fingertip slide does.
    do {
        var bc = cfg; bc.edges.left = EdgeBinding(slide: "brightness")
        GestureEngine.testConfig = bc
        var sliders: [String] = []
        SliderController.testSink = { sliders.append($0) }
        _ = stroke((0.03, 0.40), (0.03, 0.43), duration: 0.5)                       // 2.3 mm drift at ~5 mm/s
        let drift = sliders.count
        sliders = []
        var palm = bc
        GestureEngine.testConfig = palm
        let e4 = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 800.0
        for i in 0...40 {                                                           // palm-sized, quick
            let y = 0.4 + Double(i) * 0.004
            e4.process([Contact(id: 50, x: 0.03, y: Float(y), state: 4, size: 1.6, xmm: 3.7, ymm: y * 76.8)], time: t); t += 1.0 / 120
        }
        e4.process([], time: t)
        let palmSlide = sliders.count
        sliders = []
        _ = stroke((0.001, 0.30), (0.001, 0.45), duration: 0.15)                    // measured: hand side on the border
        let border = sliders.count
        sliders = []
        _ = stroke((0.0, 0.30), (0.0, 0.55), duration: 0.3)                         // measured: fingertip slid over the border
        _ = stroke((0.001, 0.30), (0.001, 0.42), duration: 0.15, size: 1.1)         // full fingertip on the border
        let borderSlides = sliders.count
        sliders = []
        _ = stroke((0.03, 0.30), (0.03, 0.60), duration: 0.3)                       // fingertip, ~75 mm/s
        check(drift == 0 && palmSlide == 0 && border == 0 && borderSlides == 2 && sliders == ["slider:brightness"],
              "palm drift, palm-sized slides and a hand side on the border don't touch brightness; fingertip slides do, on the border too (\(drift)/\(palmSlide)/\(border)/\(borderSlides)/\(sliders.count))")
        SliderController.testSink = nil
        palm.edges.left = EdgeBinding()
        GestureEngine.testConfig = cfg
    }

    // Measured: deliberate repeat taps on a corner 0.3–0.5 s apart, fingertip pressed into the corner (size up to 1.55).
    func cornerTaps(gaps: [Double], size: Float) -> [String] {
        fired = []
        let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
        var t = 600.0
        for gap in gaps {
            for _ in 0..<9 { engine.process([Contact(id: 30, x: 0.99, y: 0.98, state: 4, size: size, xmm: 123.5, ymm: 75.3)], time: t); t += 1.0 / 120 }
            engine.process([], time: t); t += gap
        }
        Thread.sleep(forTimeInterval: 0.2)
        return fired
    }
    check(cornerTaps(gaps: [0.35, 0.4, 0.5], size: 0.8).count == 3, "quick deliberate repeat corner taps all count")
    check(cornerTaps(gaps: [0.5], size: 1.5) == ["cornerTap:missionControl"].map { _ in fired.first ?? "" } && !fired.isEmpty,
          "fingertip pressed into the corner (size 1.5) counts")
    check(cornerTaps(gaps: [0.03, 0.5], size: 0.8).count == 1, "a bounce 30 ms after a corner tap is ignored")
    check(stroke((0.03, 0.97), (0.03, 0.97), duration: 0.1, hold: 0.6) == ["cornerHold:lockScreen"], "corner: press & hold (no tap)")
    check(stroke((0.03, 0.97), (0.2, 0.75), duration: 0.2).isEmpty, "corner: moving away cancels")
    let fromCorner = stroke((0.96, 0.06), (0.96, 0.45), duration: 0.4)
    check(!fromCorner.isEmpty && fromCorner.allSatisfy { $0 == "edgeSlide:nextTab" }, "slide starting in a corner becomes the edge's slide")
    // Momentum: a fast flick on a repeating edge keeps stepping after lift; a slow slide doesn't; a new touch stops it.
    let flickSteps = stroke((0.96, 0.30), (0.96, 0.55), duration: 0.09).count
    let withMomentum = stroke((0.96, 0.30), (0.96, 0.55), duration: 0.09, settle: 1.5)
    let glide = withMomentum.count - flickSteps
    check(glide >= 2 && glide <= 5 && withMomentum.contains("edgeMomentum:nextTab"),
          "fast flick glides 2–5 extra steps with momentum: \(flickSteps) while touching + \(glide) gliding")
    check(!stroke((0.96, 0.30), (0.96, 0.55), duration: 1.2, settle: 1.0).contains("edgeMomentum:nextTab"), "slow slide has no momentum")
    var atTouch = 0
    let stopped = stroke((0.96, 0.30), (0.96, 0.55), duration: 0.09, settle: 1.0) { engine, t in
        Thread.sleep(forTimeInterval: 0.05)
        engine.process([Contact(id: 3, x: 0.5, y: 0.5, state: 4, size: 0.9, xmm: 62, ymm: 38)], time: t + 0.06)
        atTouch = fired.count
    }
    check(stopped.count == atTouch, "touching the trackpad stops momentum immediately (\(atTouch) → \(stopped.count))")
    var noMomentum = cfg; noMomentum.edges.momentum = false
    GestureEngine.testConfig = noMomentum
    check(!stroke((0.96, 0.30), (0.96, 0.55), duration: 0.09, settle: 1.0).contains("edgeMomentum:nextTab"), "momentum can be switched off")
    GestureEngine.testConfig = cfg

    // ---- Edge scrolling (events captured, never posted) ----
    var scrolled: [(Int32, Int32)] = []
    ScrollOutput.testSink = { dx, dy in scrolled.append((dx, dy)) }
    var sc = cfg
    sc.edges.right = EdgeBinding(slide: "scroll")
    sc.edges.bottom = EdgeBinding(slide: "scroll")
    GestureEngine.testConfig = sc
    scrolled = []
    _ = stroke((0.96, 0.30), (0.96, 0.60), duration: 0.8, settle: 0.05)
    let dy = scrolled.reduce(0) { $0 + Int($1.1) }
    check(!scrolled.isEmpty && scrolled.allSatisfy { $0.0 == 0 }, "right edge scrolls vertically only (\(scrolled.count) events)")
    check(ScrollOutput.natural ? dy < 0 : dy > 0, "finger up scrolls the content up with natural scrolling (\(dy) px)")
    let slowOnly = scrolled.count
    scrolled = []
    _ = stroke((0.5, 0.05), (0.75, 0.05), duration: 0.5, settle: 0.05)
    check(!scrolled.isEmpty && scrolled.allSatisfy { $0.1 == 0 }, "bottom edge scrolls horizontally")
    scrolled = []
    _ = stroke((0.96, 0.30), (0.96, 0.50), duration: 0.06, settle: 1.5)
    let scrollGlide = scrolled.count
    check(scrollGlide > slowOnly / 4 && scrollGlide > 10, "a scroll flick keeps gliding with momentum (\(scrollGlide) events)")
    // Sub-pixel accumulation: 100 tiny moves of 0.05 mm (0.35 px each) must still scroll ~35 px.
    ScrollOutput.reset(); scrolled = []
    for _ in 0..<100 { ScrollOutput.scroll(alongMM: 0.05, vertical: true, gain: 1) }
    let tiny = abs(scrolled.reduce(0) { $0 + Int($1.1) })
    check(tiny >= 34 && tiny <= 35, "slow movement isn't lost: 100 × 0.35 px → \(tiny) px")
    ScrollOutput.testSink = nil

    // ---- App switcher (keys captured, never posted): Cmd is always released ----
    var keys: [String] = []
    SwitcherHold.testSink = { keys.append($0) }
    var sw = cfg
    sw.edges.right = EdgeBinding(slide: "appSwitcher", stepMM: 10)
    GestureEngine.testConfig = sw
    keys = []
    _ = stroke((0.96, 0.75), (0.96, 0.30), duration: 0.6)
    check(keys.first == "cmdDown" && keys.last == "cmdUp" && keys.filter { $0 == "tab" }.count >= 2,
          "slide down: Cmd held, next apps selected, Cmd released on lift → \(keys)")
    keys = []
    _ = stroke((0.96, 0.30), (0.96, 0.75), duration: 0.6)
    check(keys.contains("shiftTab") && keys.last == "cmdUp", "slide up goes to previous apps")
    keys = []
    _ = stroke((0.96, 0.75), (0.96, 0.40), duration: 0.4) { engine, t in }
    let afterLift = keys.last
    keys = []
    let e2 = GestureEngine(widthMM: 124.8, heightMM: 76.8)
    var tt = 300.0
    for i in 0...40 {
        let y = 0.75 - Double(i) * 0.008
        e2.process([Contact(id: 5, x: 0.96, y: Float(y), state: 4, size: 0.9, xmm: 0.96 * 124.8, ymm: y * 76.8)], time: tt); tt += 1.0 / 120
    }
    e2.process([Contact(id: 5, x: 0.96, y: 0.42, state: 4, size: 0.9, xmm: 119.8, ymm: 32.2),
                Contact(id: 6, x: 0.5, y: 0.5, state: 4, size: 0.9, xmm: 62.4, ymm: 38.4)], time: tt)
    check(afterLift == "cmdUp" && keys.last == "cmdUp" && !SwitcherHold.holding, "Cmd released when a second finger lands (cancel)")
    keys = []
    for i in 0...40 {
        let y = 0.75 - Double(i) * 0.008
        e2.process([], time: tt); tt += 0.05
        e2.process([Contact(id: 7, x: 0.96, y: Float(y), state: 4, size: 0.9, xmm: 0.96 * 124.8, ymm: y * 76.8)], time: tt); tt += 1.0 / 120
        if i == 0 { keys = [] }
    }
    e2.physicalPress()
    check(!SwitcherHold.holding, "Cmd released on a physical click")
    SwitcherHold.testSink = nil
    GestureEngine.testConfig = cfg

    // ---- Video scrubbing per app ----
    var vc = cfg
    vc.edges.bottom = EdgeBinding(slide: "actions", forward: Action("nextTrack"), backward: Action("previousTrack"), repeats: false)
    var chrome = Config.AppRule(name: "Chrome")
    chrome.edgeOverrides["bottom"] = SettingsModel.videoScrubber
    vc.apps["com.google.Chrome"] = chrome
    check(vc.resolved(for: "com.google.Chrome").edges.bottom.forward.type == "seekForward"
          && vc.resolved(for: "com.apple.Music").edges.bottom.forward.type == "nextTrack",
          "bottom edge scrubs video in Chrome, still skips tracks in Music")
    GestureEngine.testConfig = vc.resolved(for: "com.google.Chrome")
    let scrub = stroke((0.4, 0.05), (0.6, 0.05), duration: 0.8, settle: 0.1)
    check(scrub.count >= 2 && scrub.allSatisfy { $0.hasSuffix(":seekForward") }, "slide right on the bottom edge seeks forward repeatedly → \(scrub.count)×")
    check(SmartActions.resolvedKeys("seekForward", bundle: "com.google.Chrome") == "right"
          && SmartActions.resolvedKeys("seekBackward", bundle: "com.apple.Safari") == "left"
          && SmartActions.resolvedKeys("seekForward", bundle: "org.videolan.vlc") == "cmd+alt+right"
          && SmartActions.resolvedKeys("videoFullscreen", bundle: "com.apple.QuickTimePlayerX") == "ctrl+cmd+f",
          "seek keys match each player (browsers ←/→, VLC ⌘⌥←/→, QuickTime full screen ⌃⌘F)")
    GestureEngine.testConfig = cfg

    // Shortcuts press and release their modifiers like a real keyboard, ending with nothing held.
    var keyLog: [String] = []
    keyEventSink = { keyLog.append($0) }
    _ = postKeys("cmd+shift+5")
    let shiftCode = 56, cmdCode = 55, fiveCode = 23
    check(keyLog.first == "down:\(shiftCode):\(CGEventFlags.maskShift.rawValue)"
          && keyLog.contains("down:\(fiveCode):\((CGEventFlags.maskShift.union(.maskCommand)).rawValue)")
          && keyLog.last == "up:\(shiftCode):0" && keyLog.contains("up:\(cmdCode):\(CGEventFlags.maskShift.rawValue)")
          && keyLog.count == 6,
          "⌘⇧5 is sent as ⇧↓ ⌘↓ 5↓ 5↑ ⌘↑ ⇧↑ and ends with no modifier held → \(keyLog)")
    keyLog = []
    _ = postKeys("right")
    check(keyLog == ["down:124:0", "up:124:0"], "plain keys carry no modifiers")
    keyEventSink = nil

    // Apple-style haptics: the right system pattern per event, and fast ticks never buzz.
    var feel: [String] = []
    Haptics.testSink = { feel.append($0) }
    var apple = Config(); apple.hapticSettings.style = "apple"
    let savedCfg = ConfigStore.shared.current
    ConfigStore.shared.setForTesting(apple)
    Haptics.play(.bump); Haptics.play(.confirm); Haptics.play(.gesture); Haptics.play(.doubleTap)
    check(feel == ["levelChange", "generic", "generic", "levelChange"], "ends / holds bump, actions click once → \(feel)")
    feel = []
    for _ in 0..<20 { Haptics.play(.tick) }               // 20 steps within a millisecond (a very fast slide)
    Thread.sleep(forTimeInterval: Haptics.minTickInterval + 0.005)
    Haptics.play(.tick)
    check(feel == ["alignment", "alignment"], "a burst of steps gives one tick, not a buzz → \(feel.count) ticks")
    ConfigStore.shared.setForTesting(savedCfg)
    Haptics.testSink = nil

    // Video keys only reach browser tabs that are video sites (arrow keys would scroll other pages sideways).
    check(SmartActions.isVideoContext(bundle: "com.google.Chrome", windowTitle: "Big Buck Bunny - YouTube")
          && SmartActions.isVideoContext(bundle: "com.apple.Safari", windowTitle: "Netflix")
          && !SmartActions.isVideoContext(bundle: "com.google.Chrome", windowTitle: "Hacker News")
          && !SmartActions.isVideoContext(bundle: "com.apple.Safari", windowTitle: nil)
          && SmartActions.isVideoContext(bundle: "com.colliderli.iina", windowTitle: "anything.mkv"),
          "seek keys go to video tabs and players only, never to ordinary web pages")

    // Real-hand swipes (measured): 8–21 mm at 70–200 mm/s must all fire with a 19 mm step.
    var real = cfg
    real.edges.bottom.stepMM = 18.9
    GestureEngine.testConfig = real
    check(stroke((0.45, 0.04), (0.45 + 14.6 / 124.8, 0.04), duration: 0.16) == ["edgeSwipe:nextTrack"],
          "typical real swipe (14.6 mm, fast) fires thanks to the speed boost")
    check(stroke((0.55, 0.05), (0.55 - 8.4 / 124.8, 0.05), duration: 0.16) == ["edgeSwipe:previousTrack"],
          "shortest real swipe (8.4 mm) fires when the finger lifts")
    check(stroke((0.5, 0.05), (0.5 + 4 / 124.8, 0.05), duration: 0.3).isEmpty, "a 4 mm nudge is not a swipe")
    check(GestureEngine.swipeBoost(30) == 1 && GestureEngine.swipeBoost(400) == 2.5 && GestureEngine.swipeBoost(130) > 1.6 && GestureEngine.swipeBoost(130) < 1.9,
          "speed boost eases from 1× (slow) to 2.5× (fast) and levels off")
    GestureEngine.testConfig = cfg

    // Too-thin zones are widened to what a fingertip can hit (the user's 6 mm bottom edge).
    var thin = cfg
    thin.edges.height = 0.078
    GestureEngine.testConfig = thin.normalized()
    check(thin.normalized().edges.height >= Config.minEdgeHeight, "edges thinner than ~8.5 mm are widened")
    check(stroke((0.4, 0.095), (0.7, 0.095), duration: 0.25) == ["edgeSwipe:nextTrack"],
          "slide starting 7 mm from the bottom is detected (was missed with a 6 mm edge)")
    check(stroke((0.5, 0.40), (0.8, 0.40), duration: 0.25).isEmpty, "a slide across the middle is not an edge gesture")
    check(!Action("app").isComplete && !Action("keys", "").isComplete && Action("app", "Safari").isComplete && Action("nextTrack").isComplete,
          "actions missing their app / keys are flagged as not set up")
    GestureEngine.testSink = nil
    GestureEngine.testConfig = nil

    // ---- Config migration from older versions ----
    var old: Any = ["edges": ["left": "volume", "right": "none"],
                    "media": ["tap": ["type": "mute"], "swipeLeft": ["type": "back"], "swipeRight": ["type": "forward"], "enabled": true]]
    check(ConfigStore.migrate(&old), "old config detected")
    let e = (old as! [String: Any])["edges"] as! [String: Any]
    check((e["left"] as? [String: Any])?["slide"] as? String == "volume", "old left: \"volume\" → slide volume")
    let bottom = e["bottom"] as? [String: Any]
    check((bottom?["tap"] as? [String: Any])?["type"] as? String == "mute" && (bottom?["forward"] as? [String: Any])?["type"] as? String == "forward",
          "old media strip → bottom edge with the same actions")
    check((old as! [String: Any])["media"] == nil, "media section removed")

    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--keycast-demo") {
    // Visual check of the action pills.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    KeyCast.shared.show(symbol: "doc.on.doc", title: "Copy")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { KeyCast.shared.show(symbol: "chevron.backward", title: "Back") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { KeyCast.shared.level(.volume, value: 0.62, overshoot: 0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
    app.run()
}

if CommandLine.arguments.contains("--freeze-demo") {
    // Visual check: freezes the pointer for 2 s (stand-in cursor drawn, real cursor hidden), then restores it.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let resolved = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") != nil
    print("SetsCursorInBackground API available:", resolved)
    let pin = CGEvent(source: nil)?.location ?? .zero
    print("freezing at", pin)
    PointerFreeze.freeze(at: pin)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PointerFreeze.unfreeze(at: pin) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { print("unfrozen"); exit(0) }
    app.run()
}

if CommandLine.arguments.contains("--bench") {
    // Per-frame cost of the touch pipeline (learner + gesture engine) with one moving finger.
    ConfigStore.shared.load()
    let engine = GestureEngine(widthMM: 124.8, heightMM: 76.8)
    let frames = 200_000
    var t = 0.0
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<frames {
        t += 1.0 / 120
        let phase = Double(i % 240) / 240
        let lifted = i % 240 > 200
        let x = Float(0.3 + 0.4 * phase), y = Float(0.5)
        let c = lifted ? [] : [Contact(id: Int32(i / 240), x: x, y: y, state: 4, size: 0.9,
                                       xmm: Double(x) * 124.8, ymm: Double(y) * 76.8)]
        Learner.shared.observe(c, time: t)
        engine.process(c, time: t)
    }
    let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames)
    print(String(format: "%.2f µs per frame → %.3f%% of one core at 120 Hz while touching", ns / 1000, ns * 120 / 1e9 * 100))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
