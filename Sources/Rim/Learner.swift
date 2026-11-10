import Foundation

/// Learns how *this* person uses the trackpad and derives the accidental-touch thresholds from it.
///
/// Samples come only from touches that were certainly intentional:
///  - finger size: single-finger contacts that moved the cursor > 8 mm (palms rest, fingers point)
///  - tap timing / movement: contacts confirmed by the tap-to-click they produced
///  - typing → trackpad gap: time from the last keystroke to an intentional pointing move
/// Stats are fixed-bin histograms (constant memory) and halve when large, so habits can drift over days.
final class Learner {
    static let shared = Learner()

    struct Histogram: Codable {
        let lo: Double, hi: Double
        var bins: [Double]

        init(_ lo: Double, _ hi: Double, _ count: Int) { self.lo = lo; self.hi = hi; bins = Array(repeating: 0, count: count) }

        var total: Double { bins.reduce(0, +) }

        mutating func add(_ x: Double) {
            let i = Int(((x - lo) / (hi - lo) * Double(bins.count)).rounded(.down))
            bins[min(max(i, 0), bins.count - 1)] += 1
            if total > 4000 { for j in bins.indices { bins[j] *= 0.5 } }
        }

        func percentile(_ p: Double) -> Double? {
            let t = total
            guard t > 0 else { return nil }
            var acc = 0.0
            let w = (hi - lo) / Double(bins.count)
            for (i, c) in bins.enumerated() {
                if acc + c >= p * t {
                    let frac = c > 0 ? (p * t - acc) / c : 0
                    return lo + (Double(i) + frac) * w
                }
                acc += c
            }
            return hi
        }
    }

    struct Stats: Codable {
        var fingerSize = Histogram(0, 6, 300)
        var tapDuration = Histogram(0, 0.6, 120)
        var tapMove = Histogram(0, 8, 160)
        var keyToPointer = Histogram(0, 3, 150)
    }

    /// Minimum samples before a learned value is used.
    static let need = (size: 150.0, tap: 40.0, typing: 30.0)

    private struct Track {
        let t0: Double
        let sx: Double, sy: Double
        let keyGap: Double
        var maxSize: Float = 0
        var maxMove = 0.0
        var maxFingers = 1
        var recordedPointer = false
    }

    private struct PendingTap { let endedAt: Double; let duration: Double; let move: Double; let size: Float }

    private let lock = NSLock()
    private var stats = Stats()
    private var tracks: [Int32: Track] = [:]
    private var pendingTaps: [PendingTap] = []
    private var dirty = false
    private var cached: (base: Config.Guard, result: Config.Guard)?

    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rim/learned.json")

    // MARK: - Input

    /// Every multitouch frame (any thread).
    func observe(_ contacts: [Contact], time: Double) {
        lock.lock(); defer { lock.unlock() }
        let touching = contacts.filter { $0.touching }
        let n = touching.count
        var live = Set<Int32>()

        for c in touching {
            live.insert(c.id)
            var t = tracks[c.id] ?? Track(t0: time, sx: c.xmm, sy: c.ymm, keyGap: EventGate.shared.secondsSinceKey)
            t.maxSize = max(t.maxSize, c.size)
            t.maxMove = max(t.maxMove, hypot(c.xmm - t.sx, c.ymm - t.sy))
            t.maxFingers = max(t.maxFingers, n)
            if !t.recordedPointer, t.maxFingers == 1, t.maxMove > 8 {
                t.recordedPointer = true
                if t.keyGap < 3 { add(\.keyToPointer, t.keyGap) }
            }
            tracks[c.id] = t
        }

        guard tracks.count > live.count else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, t) in tracks where !live.contains(id) {
            tracks[id] = nil
            guard t.maxFingers == 1 else { continue }
            let duration = time - t.t0
            if t.maxMove > 8 { add(\.fingerSize, Double(t.maxSize)) }
            else if duration < 0.5 { pendingTaps.append(PendingTap(endedAt: now, duration: duration, move: t.maxMove, size: t.maxSize)) }
        }
        pendingTaps.removeAll { now - $0.endedAt > 0.4 }
    }

    /// A click passed through that wasn't a physical press: confirms the most recent tap.
    func didClick() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard let i = pendingTaps.lastIndex(where: { now - $0.endedAt < 0.35 }) else { return }
        let tap = pendingTaps.remove(at: i)
        add(\.tapDuration, tap.duration)
        add(\.tapMove, tap.move)
        add(\.fingerSize, Double(tap.size))
    }

    private func add(_ kp: WritableKeyPath<Stats, Histogram>, _ x: Double) {
        stats[keyPath: kp].add(x)
        dirty = true
        cached = nil
    }

    // MARK: - Output

    struct Snapshot {
        var samples: (size: Double, tap: Double, typing: Double)
        var progress: Double
        var learned: Config.Guard
    }

    func snapshot(base: Config.Guard) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let s = (stats.fingerSize.total, stats.tapDuration.total, stats.keyToPointer.total)
        let progress = (min(1, s.0 / Self.need.size) + min(1, s.1 / Self.need.tap) + min(1, s.2 / Self.need.typing)) / 3
        var forced = base
        forced.adaptive = true
        return Snapshot(samples: s, progress: progress, learned: compute(forced))
    }

    /// Thresholds to use right now (learned where there is enough data, configured otherwise).
    func guardrails(_ base: Config.Guard) -> Config.Guard {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.base == base { return c.result }
        let r = compute(base)
        cached = (base, r)
        return r
    }

    private func compute(_ base: Config.Guard) -> Config.Guard {
        guard base.adaptive else { return base }
        var g = base
        func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

        if stats.fingerSize.total >= Self.need.size, let p99 = stats.fingerSize.percentile(0.99) {
            g.palmSize = Float(clamp(p99 * 1.3, 0.3, 6))          // 30 % above your largest normal finger
        }
        if stats.tapDuration.total >= Self.need.tap,
           let p95 = stats.tapDuration.percentile(0.95), let p02 = stats.tapDuration.percentile(0.02) {
            g.maxTap = clamp(p95 * 1.25, 0.15, 0.45)
            g.minTap = clamp(p02 * 0.7, 0.01, 0.06)
        }
        if stats.tapMove.total >= Self.need.tap, let p95 = stats.tapMove.percentile(0.95) {
            g.tapSlop = clamp(p95 * 1.4, 1.2, 4.5)
        }
        if stats.keyToPointer.total >= Self.need.typing, let p10 = stats.keyToPointer.percentile(0.10) {
            g.typingPause = clamp(p10 * 0.8, 0.2, 0.9)            // just under your fastest real switch
        }
        return g
    }

    // MARK: - Persistence

    func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stats.self, from: data) { stats = s }
    }

    func saveIfNeeded() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let data = try? JSONEncoder().encode(stats)
        lock.unlock()
        try? data?.write(to: url, options: .atomic)
    }

    func reset() {
        lock.lock()
        stats = Stats()
        cached = nil
        dirty = true
        lock.unlock()
        saveIfNeeded()
    }
}
