import AppKit

/// Debug window: draws the trackpad, the configured zones and live finger positions.
final class Visualizer: NSObject, NSWindowDelegate {
    static let shared = Visualizer()

    private var window: NSWindow?
    private let view = TouchView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    private let lock = NSLock()
    private var latest: [Contact] = []
    private var pending = false
    private var visible = false

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Rim: Touch Visualizer"
            w.contentView = view
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        lock.lock(); visible = true; lock.unlock()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        lock.lock(); visible = false; lock.unlock()
    }

    /// Called from the multitouch thread; coalesces redraws onto the main thread.
    func update(_ contacts: [Contact]) {
        lock.lock()
        guard visible else { lock.unlock(); return }
        latest = contacts
        let schedule = !pending
        pending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.lock.lock(); let c = self.latest; self.pending = false; self.lock.unlock()
            self.view.contacts = c
            self.view.needsDisplay = true
        }
    }
}

private final class TouchView: NSView {
    var contacts: [Contact] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let cfg = ConfigStore.shared.current
        let aspect: CGFloat = 1.6
        let avail = bounds.insetBy(dx: 24, dy: 24)
        var w = avail.width, h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        let pad = NSRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)

        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> NSRect {
            NSRect(x: pad.minX + CGFloat(x0) * w, y: pad.minY + CGFloat(y0) * h,
                   width: CGFloat(x1 - x0) * w, height: CGFloat(y1 - y0) * h)
        }
        func zone(_ r: NSRect, _ color: NSColor, _ text: String) {
            color.withAlphaComponent(0.22).setFill()
            r.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let s = text as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }

        let outline = NSBezierPath(roundedRect: pad, xRadius: 14, yRadius: 14)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if cfg.edges.enabled {
            let e = cfg.edges, w = e.width, h = e.height
            if !e.bottom.isNone { zone(rect(0, 0, 1, h), .systemGreen, "bottom: " + ActionCatalog.edgeSummary(e.bottom, .bottom)) }
            if !e.top.isNone { zone(rect(0, 1 - h, 1, 1), .systemGreen, "top: " + ActionCatalog.edgeSummary(e.top, .top)) }
            if !e.left.isNone { zone(rect(0, 0, w, 1), .systemBlue, ActionCatalog.edgeSummary(e.left, .left)) }
            if !e.right.isNone { zone(rect(1 - w, 0, 1, 1), .systemBlue, ActionCatalog.edgeSummary(e.right, .right)) }
        }
        if cfg.corners.enabled {
            let c = cfg.corners
            let boxes: [(Corner, NSRect)] = [
                (.topLeft, rect(0, 1 - c.height, c.width, 1)), (.topRight, rect(1 - c.width, 1 - c.height, 1, 1)),
                (.bottomLeft, rect(0, 0, c.width, c.height)), (.bottomRight, rect(1 - c.width, 0, 1, c.height)),
            ]
            for (corner, r) in boxes where !c.binding(corner).isNone {
                NSColor.windowBackgroundColor.setFill(); r.fill()
                zone(r, .systemOrange, ActionCatalog.label(c.binding(corner).tap))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1.5
        outline.stroke()

        for c in contacts {
            let p = NSPoint(x: pad.minX + CGFloat(c.x) * w, y: pad.minY + CGFloat(c.y) * h)
            let r: CGFloat = 16
            (c.touching ? NSColor.systemRed : NSColor.systemGray).withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
            let palm = c.size > cfg.guardrails.palmSize ? "  PALM" : ""
            let label = String(format: "%.0f, %.0f mm  size %.2f%@", c.xmm, c.ymm, c.size, palm) as NSString
            label.draw(at: NSPoint(x: p.x + r + 4, y: p.y - 6),
                       withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                        .foregroundColor: NSColor.labelColor])
        }
    }
}
