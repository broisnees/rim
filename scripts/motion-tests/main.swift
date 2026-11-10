// Motion math tests. Run: scripts/test.sh
import Foundation

var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "ok  " : "FAIL", m); if !c { fails += 1 } }

// Acceleration: monotonic, ranges as designed
let gSlow = Acceleration.gain(speed: 5, amount: 1), gFast = Acceleration.gain(speed: 400, amount: 1)
var mono = true, last = 0.0
for v in stride(from: 1.0, to: 600, by: 1) { let g = Acceleration.gain(speed: v, amount: 1); if g < last - 1e-12 { mono = false }; last = g }
check(mono, "gain is monotonic in speed")
check(abs(1 / gSlow - 110) < 0.5 && abs(1 / gFast - 24) < 0.5, "full range: 110 mm slow, 24 mm fast")

// Rubber band
check(rubberBand(1000, dimension: 14) < 14, "rubber band bounded")
check(abs(rubberBand(1, dimension: 14) - 0.55) < 0.05, "rubber band slope 0.55 at origin")
check(rubberBand(-5, dimension: 14) == -rubberBand(5, dimension: 14), "rubber band symmetric")

// Springs
var s = Spring(0, response: 0.3, dampingFraction: 1); s.target = 1
var maxV = 0.0, t = 0.0
while !s.settled && t < 3 { s.step(1 / 120); maxV = max(maxV, s.value); t += 1 / 120 }
check(maxV <= 1.0005 && s.settled, String(format: "critical spring settles in %.2fs without overshoot", t))
var b = Spring(0, response: 0.38, dampingFraction: 0.62); b.target = 1; maxV = 0; t = 0
while !b.settled && t < 3 { b.step(1 / 120); maxV = max(maxV, b.value); t += 1 / 120 }
check(maxV > 1.02 && b.settled, String(format: "bouncy spring overshoots %.1f%% and settles in %.2fs", (maxV - 1) * 100, t))

// Detents
var d = Detents(count: 16); d.reset(0.5)
var ticks = 0, time = 0.0
for i in 1...160 { time += 0.008; if d.update(0.5 + Double(i) / 160 * 0.25, time: time) { ticks += 1 } }
check(ticks == 4, "slow sweep over 4 steps = \(ticks) ticks")
time += 1
d.reset(9.0 / 16); ticks = 0
for i in 0..<200 { time += 0.008; if d.update((9.0 + (i % 2 == 0 ? 0.03 : -0.03)) / 16, time: time) { ticks += 1 } }
check(ticks <= 1, "jitter on a step boundary = \(ticks) tick(s)")
d.reset(0); ticks = 0
for i in 1...10 { time += 0.008; if d.update(Double(i) / 10, time: time) { ticks += 1 } }
check(ticks >= 4 && ticks <= 10, "fast flick through 16 steps is rate-limited: \(ticks) ticks")

// 1€ filter
var f = OneEuroFilter(); var outs: [Double] = []
for i in 0..<240 { outs.append(f.filter(10 + (i % 2 == 0 ? 0.15 : -0.15), time: Double(i) / 120)) }
let jitter = outs.suffix(60).max()! - outs.suffix(60).min()!
check(jitter < 0.1, String(format: "rest jitter 0.30 mm -> %.3f mm", jitter))
f.reset(); var lag = 0.0
for i in 0..<120 { let x = Double(i) * 200 / 120; lag = x - f.filter(x, time: Double(i) / 120) }
check(lag < 5, String(format: "lag at 200 mm/s = %.1f mm (%.0f ms)", lag, lag / 200 * 1000))

// Velocity
var vt = VelocityTracker()
for i in 0..<20 { vt.add(Double(i) * 1.5 + (i % 2 == 0 ? 0.1 : -0.1), Double(i) / 120) }
check(abs(vt.velocity - 180) < 15, String(format: "velocity estimate %.0f mm/s (true 180)", vt.velocity))

print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
