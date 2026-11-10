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
    enum Event: String { case threeFingerTap, fourFingerTap, fiveFingerTap, tipTapLeft, tipTapRight, twoHandTap }

    struct Limits {
        var landingSpread = 0.15      // s between first and last finger landing
        var maxDuration = 0.35        // s from first down to last up
        var maxMove = 4.0             // mm any finger may travel
        var twoHandDistance = 55.0    // mm between the two hands' fingers
        var restBefore = 0.2          // s the resting finger must be down before a tip-tap
        var tipTapMax = 0.25          // s the tip-tapping finger may stay down
        var restMove = 3.0            // mm the resting finger may move during a tip-tap
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
        }
        maxConcurrent = max(maxConcurrent, fingers.count)
        return events
    }

    private func tipTap(_ f: Finger, liftedAt time: Double) -> Event? {
        guard !invalid, f.concurrentAtLanding == 2, fingers.count == 1, let rest = fingers.values.first,
              let anchor = f.restAnchor else { return nil }
        let restedFor = f.t0 - rest.t0
        let restMoved = hypot(rest.x - anchor.x, rest.y - anchor.y)
        guard restedFor >= limits.restBefore, time - f.t0 <= limits.tipTapMax,
              f.maxMove <= limits.maxMove, restMoved <= limits.restMove, rest.maxMove <= limits.maxMove * 2 else { return nil }
        return f.x0 < rest.x ? .tipTapLeft : .tipTapRight
    }

    private func sequenceEnded(at time: Double) -> Event? {
        guard !invalid, !fired else { return nil }
        let all = Array(lifted.values)
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
        fingers.removeAll()
        lifted.removeAll()
        maxConcurrent = 0
        invalid = false
        fired = false
    }
}
