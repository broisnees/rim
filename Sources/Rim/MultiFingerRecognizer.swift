import Foundation

/// Recognises multi-finger taps, tip-taps and two-hand taps from raw contacts.
///
/// Only *taps* are recognised: three-finger drag and the system's 3/4-finger swipes keep working.
/// A sequence runs from the first finger down to the last finger up.
///  - N-finger tap (3–5): all fingers land within 150 ms, nobody moves > 4 mm, all up within 350 ms.
///  - Two-hand tap: exactly two fingers ≥ 55 mm apart (one per hand), same timing rules.
///    (A normal two-finger tap — right click — has fingers ~20 mm apart and is ignored.)
///  - Tip-tap: one finger *resting* (down ≥ 200 ms, still), a second finger taps beside it.
///    Fires as the tapping finger lifts; the resting finger can keep tip-tapping.
/// Rejected: during typing, palm-sized contacts, any finger that moved, slow or staggered landings.
struct MultiFingerRecognizer {
    enum Event: String {
        case threeFingerTap, fourFingerTap, fiveFingerTap, tipTapLeft, tipTapRight, twoHandTap
        case tipSwipeLeft, tipSwipeRight, tipSwipeUp, tipSwipeDown
        case twoFingerSwipeLeft, twoFingerSwipeRight
    }

    struct Limits {
        var landingSpread = 0.15      // s between first and last finger landing
        var maxDuration = 0.35        // s from first down to last up
        var maxMove = 4.0             // mm any finger may travel
        var twoHandDistance = 55.0    // mm between the two hands' fingers
        var restBefore = 0.2          // s the resting finger must be down before a tip-tap
        var tipTapMax = 0.25          // s the tip-tapping finger may stay down
        var restMove = 3.0            // mm the resting finger may move during a tip-tap
        // Measured on a real hand: neighbouring-finger taps land 17–31 mm away and up to 22 mm above / below
        // (the hand sits at an angle). Limits leave a margin around that.
        var tipTapMinDistance = 12.0  // mm: closer than this is the same finger rolling
        var tipTapMaxDistance = 40.0  // mm: further than this is another hand or a stray touch
        var tipTapMaxVertical = 28.0  // mm above / below the resting finger
        var tipTapMinSideways = 5.0   // mm: left vs right must be clear
        var border = 0.04             // fraction of the trackpad: touches landing this close to the frame are
                                      // the sides of the hands brushing it, never deliberate multi-finger taps
    }

    private struct Finger {
        let t0: Double
        let x0: Double, y0: Double
        var x: Double, y: Double
        var maxMove = 0.0
        var concurrentAtLanding = 1
        var restAnchor: (x: Double, y: Double)?   // other finger's position when this one landed
    }

    var limits = Limits()
    var tipSwipeStep = 10.0                  // mm of sliding per action
    static let tipSwipeEngage = 4.0          // mm the sliding finger must move before a tip-swipe starts

    /// A tip-swipe is in progress (one finger resting, a neighbour sliding). The engine freezes scrolling meanwhile.
    private(set) var tipSwipeActive = false
    private var swipe: (mover: Int32, vertical: Bool, last: Double, accum: Double)?
    private var fingers: [Int32: Finger] = [:]
    private var lifted: [Int32: Finger] = [:]
    private var seqStart = 0.0
    private var lastLanding = 0.0
    private var maxConcurrent = 0
    private var invalid = false
    private var fired = false

    /// Feed every frame. `typing` = a key was pressed recently; `palmSize` from the guardrails.
    mutating func process(_ touching: [Contact], time: Double, typing: Bool, palmSize: Float) -> [Event] {
        var events: [Event] = []
        let live = Set(touching.map(\.id))

        // Lifts first, so a tip-tap is judged against the finger(s) still resting.
        for (id, f) in fingers where !live.contains(id) {
            fingers[id] = nil
            if let e = tipTap(f, liftedAt: time) {
                events.append(e)
                fired = true
            } else {
                lifted[id] = f
            }
        }

        if fingers.isEmpty && !lifted.isEmpty && touching.isEmpty {
            if let e = sequenceEnded(at: time) { events.append(e) }
            reset()
        }

        for c in touching {
            if fingers.isEmpty && lifted.isEmpty {   // new sequence
                seqStart = time
                invalid = typing
                fired = false
                maxConcurrent = 0
            }
            if var f = fingers[c.id] {
                f.x = c.xmm; f.y = c.ymm
                f.maxMove = max(f.maxMove, hypot(c.xmm - f.x0, c.ymm - f.y0))
                fingers[c.id] = f
            } else {
                var f = Finger(t0: time, x0: c.xmm, y0: c.ymm, x: c.xmm, y: c.ymm)
                f.concurrentAtLanding = touching.count
                if touching.count == 2, let other = fingers.values.first { f.restAnchor = (other.x, other.y) }
                fingers[c.id] = f
                lastLanding = time
            }
            if c.size > palmSize { invalid = true }
            let b = Float(limits.border)
            if fingers[c.id]?.t0 == time, c.x < b || c.x > 1 - b || c.y < b || c.y > 1 - b {
                invalid = true    // landed on the frame: hands brushing the trackpad's sides
            }
        }
        maxConcurrent = max(maxConcurrent, fingers.count)
        events += trackTipSwipe()
        return events
    }

    private func tipTap(_ f: Finger, liftedAt time: Double) -> Event? {
        guard !invalid, f.concurrentAtLanding == 2, fingers.count == 1, let rest = fingers.values.first,
              let anchor = f.restAnchor else { return nil }
        let restedFor = f.t0 - rest.t0
        let restMoved = hypot(rest.x - anchor.x, rest.y - anchor.y)
        guard restedFor >= limits.restBefore, time - f.t0 <= limits.tipTapMax,
              f.maxMove <= limits.maxMove, restMoved <= limits.restMove, rest.maxMove <= limits.maxMove * 2 else { return nil }
        // A tip-tap is a neighbouring finger: close to the resting one and roughly level with it.
        let dx = f.x0 - anchor.x, dy = f.y0 - anchor.y
        let distance = hypot(dx, dy)
        guard distance >= limits.tipTapMinDistance, distance <= limits.tipTapMaxDistance,
              abs(dy) <= limits.tipTapMaxVertical, abs(dx) >= limits.tipTapMinSideways else { return nil }
        return dx < 0 ? .tipTapLeft : .tipTapRight
    }

    /// Rest one finger, slide the neighbouring one: steps fire every `tipSwipeStep` mm along the slide's axis.
    private mutating func trackTipSwipe() -> [Event] {
        guard !invalid, fingers.count == 2 else { endSwipe(); return [] }
        let pair = fingers.sorted { $0.value.t0 < $1.value.t0 }
        let rest = pair[0].value, (moverID, mover) = (pair[1].key, pair[1].value)
        guard let anchor = mover.restAnchor else { endSwipe(); return [] }
        let restMoved = hypot(rest.x - anchor.x, rest.y - anchor.y)

        if var s = swipe {
            guard s.mover == moverID, restMoved <= limits.restMove else { endSwipe(); return [] }
            let pos = s.vertical ? mover.y : mover.x
            s.accum += pos - s.last
            s.last = pos
            var out: [Event] = []
            while abs(s.accum) >= tipSwipeStep {
                let positive = s.accum > 0
                out.append(s.vertical ? (positive ? .tipSwipeUp : .tipSwipeDown) : (positive ? .tipSwipeRight : .tipSwipeLeft))
                s.accum -= positive ? tipSwipeStep : -tipSwipeStep
            }
            swipe = s
            if !out.isEmpty { fired = true }
            return out
        }

        // Engage: the neighbour landed after a real rest, close by, and has started sliding while the rest stays put.
        let dx = mover.x - mover.x0, dy = mover.y - mover.y0
        let landing = hypot(mover.x0 - anchor.x, mover.y0 - anchor.y)
        guard mover.t0 - rest.t0 >= limits.restBefore, restMoved <= limits.restMove, rest.maxMove <= limits.maxMove * 1.5,
              landing >= limits.tipTapMinDistance, landing <= limits.tipTapMaxDistance,
              hypot(dx, dy) >= Self.tipSwipeEngage else { return [] }
        let vertical = abs(dy) > abs(dx)
        swipe = (moverID, vertical, vertical ? mover.y0 : mover.x0, 0)
        tipSwipeActive = true
        return trackTipSwipe()
    }

    private mutating func endSwipe() {
        swipe = nil
        tipSwipeActive = false
    }

    /// Two-finger swipe: a quick, mostly horizontal flick with both fingers moving together.
    /// Slow horizontal scrolling never qualifies, so wide documents and timelines scroll as usual.
    static let swipeMinTravel = 18.0, swipeMaxDuration = 0.45, swipeMinSpeed = 110.0, swipeRatio = 3.0

    private func twoFingerSwipe(_ all: [Finger], at time: Double) -> Event? {
        guard all.count == 2, lastLanding - seqStart <= 0.12 else { return nil }
        let dur = time - seqStart
        guard dur > 0.03, dur <= Self.swipeMaxDuration else { return nil }
        let d = all.map { (dx: $0.x - $0.x0, dy: $0.y - $0.y0) }
        guard d.allSatisfy({ abs($0.dx) >= Self.swipeMinTravel && abs($0.dx) >= abs($0.dy) * Self.swipeRatio }),
              (d[0].dx > 0) == (d[1].dx > 0) else { return nil }
        let travel = (abs(d[0].dx) + abs(d[1].dx)) / 2
        guard travel / dur >= Self.swipeMinSpeed else { return nil }
        return d[0].dx > 0 ? .twoFingerSwipeRight : .twoFingerSwipeLeft
    }

    private func sequenceEnded(at time: Double) -> Event? {
        guard !invalid, !fired else { return nil }
        let all = Array(lifted.values)
        if all.count == maxConcurrent, let swipe = twoFingerSwipe(all, at: time) { return swipe }
        guard all.count == maxConcurrent,
              lastLanding - seqStart <= limits.landingSpread,
              time - seqStart <= limits.maxDuration,
              all.allSatisfy({ $0.maxMove <= limits.maxMove }) else { return nil }
        switch all.count {
        case 2:
            return hypot(all[0].x0 - all[1].x0, all[0].y0 - all[1].y0) >= limits.twoHandDistance ? .twoHandTap : nil
        case 3: return .threeFingerTap
        case 4: return .fourFingerTap
        case 5: return .fiveFingerTap
        default: return nil
        }
    }

    private mutating func reset() {
        endSwipe()
        fingers.removeAll()
        lifted.removeAll()
        maxConcurrent = 0
        invalid = false
        fired = false
    }
}
