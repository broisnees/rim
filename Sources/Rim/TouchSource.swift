import Foundation
import CMT

struct Contact {
    let id: Int32
    let x: Float      // 0 = left, 1 = right
    let y: Float      // 0 = bottom, 1 = top
    let state: Int32
    let size: Float
    let xmm: Double   // physical position on the surface
    let ymm: Double
    var touching: Bool { state == 3 || state == 4 }
}

/// Receives raw multitouch frames from every trackpad and feeds one GestureEngine per device.
final class TouchSource {
    static let shared = TouchSource()

    private var devices: [UnsafeMutableRawPointer] = []
    private var engines: [UnsafeMutableRawPointer: GestureEngine] = [:]
    private let lock = NSLock()

    private(set) var deviceCount = 0

    @discardableResult
    func start() -> Bool {
        guard tf_mt_load() else { return false }
        stop()
        let n = tf_mt_device_count()
        for i in 0..<n {
            guard let d = tf_mt_device_at(Int32(i)) else { continue }
            tf_mt_register(d, mtFrameCallback)
            tf_mt_start(d)
            devices.append(d)
        }
        deviceCount = devices.count
        return !devices.isEmpty
    }

    func stop() {
        for d in devices {
            tf_mt_unregister(d, mtFrameCallback)
            tf_mt_stop(d)
        }
        devices.removeAll()
        lock.lock(); engines.removeAll(); lock.unlock()
        EventGate.shared.reset()
        SliderController.shared.end()
        SwitcherHold.release()
    }

    fileprivate func handle(device: UnsafeMutableRawPointer?, touches: UnsafePointer<TFTouch>?, count: Int, time: Double) {
        let key = device ?? UnsafeMutableRawPointer(bitPattern: 1)!
        lock.lock()
        let engine = engines[key] ?? {
            var w: Float = 0, h: Float = 0
            if !tf_mt_surface_mm(device, &w, &h) { w = 125; h = 77 }   // 14" MacBook Pro
            let e = GestureEngine(widthMM: Double(w), heightMM: Double(h))
            engines[key] = e
            return e
        }()
        lock.unlock()

        let invert = ConfigStore.shared.current.invertY
        var contacts: [Contact] = []
        contacts.reserveCapacity(count)
        if let touches {
            for i in 0..<count {
                let t = touches[i]
                let y = invert ? 1 - t.normalized.pos.y : t.normalized.pos.y
                contacts.append(Contact(id: t.identifier, x: t.normalized.pos.x, y: y, state: t.state, size: t.size,
                                        xmm: Double(t.normalized.pos.x) * engine.widthMM, ymm: Double(y) * engine.heightMM))
            }
        }
        Visualizer.shared.update(contacts)
        TouchFeed.shared.feed(contacts)
        Learner.shared.observe(contacts, time: time)
        engine.process(contacts, time: time)
    }
}

private let mtFrameCallback: TFFrameCallback = { device, touches, count, timestamp, _ in
    TouchSource.shared.handle(device: device, touches: touches, count: Int(count), time: timestamp)
    return 0
}
