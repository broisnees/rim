import Foundation

// Motion primitives. All distances are millimetres, times are seconds.

/// 1€ filter (Casiez et al., CHI 2012): heavy smoothing when the finger is slow (kills sensor jitter),
/// light smoothing when it is fast (keeps latency low).
struct OneEuroFilter {
    var minCutoff = 2.5   // Hz at rest
    var beta = 0.05       // cutoff gain per mm/s
    var dCutoff = 1.0
    private var x: Double?
    private var dx = 0.0
    private var t = 0.0

    mutating func reset() { x = nil; dx = 0 }

    mutating func filter(_ value: Double, time: Double) -> Double {
        guard let prev = x else { x = value; t = time; return value }
        let dt = max(time - t, 1e-4)
        t = time
        dx += Self.alpha(dt, dCutoff) * ((value - prev) / dt - dx)
        let out = prev + Self.alpha(dt, minCutoff + beta * abs(dx)) * (value - prev)
        x = out
        return out
    }

    private static func alpha(_ dt: Double, _ cutoff: Double) -> Double {
        1 / (1 + 1 / (2 * .pi * cutoff * dt))
    }
}

/// Least-squares velocity over a short window (what UIKit/Android velocity trackers do),
/// robust against one noisy frame.
struct VelocityTracker {
    private var samples: [(t: Double, x: Double)] = []
    var window = 0.08

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ x: Double, _ t: Double) {
        samples.append((t, x))
        samples.removeAll { t - $0.t > window }
    }

    /// mm/s
    var velocity: Double {
        guard samples.count >= 2 else { return 0 }
        let n = Double(samples.count)
        let tm = samples.reduce(0) { $0 + $1.t } / n
        let xm = samples.reduce(0) { $0 + $1.x } / n
        var num = 0.0, den = 0.0
        for s in samples { num += (s.t - tm) * (s.x - xm); den += (s.t - tm) * (s.t - tm) }
        return den > 1e-9 ? num / den : 0
    }
}

/// Speed-dependent transfer function, shaped like macOS pointer acceleration:
/// slow = precise, fast = covers the whole range in a short flick. Smooth in log-speed.
enum Acceleration {
    static let linearRange = 55.0   // mm for 0→100 % with acceleration off
    static let slowRange = 110.0    // mm for 0→100 % when moving slowly
    static let fastRange = 24.0     // mm for 0→100 % when flicking
    static let slowSpeed = 12.0     // mm/s
    static let fastSpeed = 220.0    // mm/s

    /// Value (0…1) per mm of travel.
    static func gain(speed: Double, amount: Double) -> Double {
        let lo = log(slowSpeed), hi = log(fastSpeed)
        let s = smoothstep((log(max(speed, 1)) - lo) / (hi - lo))
        let accel = (1 / slowRange) * pow(slowRange / fastRange, s)   // geometric blend
        let linear = 1 / linearRange
        return linear + (accel - linear) * min(max(amount, 0), 1)
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Apple's rubber-band function (UIScrollView): resistance grows with distance, never exceeds `dimension`.
func rubberBand(_ offset: Double, dimension: Double, coefficient c: Double = 0.55) -> Double {
    let sign: Double = offset < 0 ? -1 : 1
    return sign * (1 - 1 / (abs(offset) * c / dimension + 1)) * dimension
}

/// Damped harmonic spring parameterised like SwiftUI's `.spring(response:dampingFraction:)`.
struct Spring {
    var value: Double
    var target: Double
    var velocity = 0.0
    private var stiffness = 0.0
    private var damping = 0.0

    init(_ value: Double = 0, response: Double, dampingFraction: Double) {
        self.value = value
        target = value
        configure(response: response, dampingFraction: dampingFraction)
    }

    mutating func configure(response: Double, dampingFraction: Double) {
        stiffness = pow(2 * .pi / response, 2)
        damping = 4 * .pi * dampingFraction / response
    }

    mutating func snap(_ v: Double) { value = v; target = v; velocity = 0 }

    mutating func step(_ dt: Double) {
        var remaining = dt
        while remaining > 0 {   // fixed sub-steps keep stiff springs stable
            let h = min(remaining, 1.0 / 480)
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
            remaining -= h
        }
        if settled { value = target; velocity = 0 }
    }

    var settled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.005 }
}

/// Counts detent crossings (16 steps like macOS volume) with hysteresis so a finger resting on a
/// boundary doesn't tick repeatedly, and rate-limits ticks so a fast drag doesn't buzz.
struct Detents {
    let count: Double
    var hysteresis = 0.2        // in steps
    var minInterval = 0.018     // s between ticks
    private var prev = 0.0
    private var lastTicked: Int?
    private var lastTickTime = -1.0

    init(count: Double) { self.count = count }

    mutating func reset(_ value: Double) { prev = value * count; lastTicked = nil }

    /// Returns true when a tick should be played.
    mutating func update(_ value: Double, time: Double) -> Bool {
        let s = value * count
        defer { prev = s }
        var crossed: [Int] = []
        if s > prev {
            let a = Int(floor(prev)) + 1, b = Int(floor(s))
            if a <= b { crossed = Array(a...b) }
        } else if s < prev {
            let a = Int(ceil(s)), b = Int(ceil(prev)) - 1
            if a <= b { crossed = Array((a...b).reversed()) }
        }
        let fresh = crossed.filter { $0 != lastTicked }
        if let last = crossed.last { lastTicked = last }
        if let l = lastTicked, abs(s - Double(l)) > hysteresis, crossed.isEmpty { lastTicked = nil }

        guard !fresh.isEmpty, time - lastTickTime >= minInterval else { return false }
        lastTickTime = time
        return true
    }
}
