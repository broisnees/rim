import AppKit
import QuartzCore

/// Translucent level / message overlay. Every visual property is a spring stepped on the
/// display link, so it moves like system UI: the bar follows the finger with a critically
/// damped spring, stretches with rubber-band resistance past the ends and springs back with
/// a slight bounce on release, and the panel scales + fades in and out.
final class HUD: NSObject {
    static let shared = HUD()

    enum Mode: Equatable { case level(SliderController.Kind), message(String, String) }
    private struct Update { var mode: Mode; var value: Double; var overshoot: Double }

    // Cross-thread mailbox (slider runs on the multitouch thread).
    private let lock = NSLock()
    private var pending: Update?

    // Main-thread state.
    private var panel: NSPanel?
    private var container: NSView!
    private let icon = NSImageView()
    private let bar = LevelBar()
    private let label = NSTextField(labelWithString: "")
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var level = Spring(response: 0.1, dampingFraction: 1)
    private var stretch = Spring(response: 0.08, dampingFraction: 1)
    private var presence = Spring(response: 0.3, dampingFraction: 0.8)
    private var dragging = false
    private var lastDragEvent: CFTimeInterval = 0
    private var hideAt: CFTimeInterval = 0
    private var symbolKey = ""

    private static let size = NSSize(width: 264, height: 56)
    private static let maxStretch = 14.0   // px

    // MARK: - API (any thread)

    func slider(_ kind: SliderController.Kind, value: Double, overshoot: Double) {
        guard ConfigStore.shared.current.hud else { return }
        post(Update(mode: .level(kind), value: value, overshoot: overshoot))
    }

    func message(_ symbol: String, _ text: String) {
        post(Update(mode: .message(symbol, text), value: 0, overshoot: 0))
    }

    func releaseSlider() {
        DispatchQueue.main.async {
            self.dragging = false
            self.stretch.configure(response: 0.38, dampingFraction: 0.62)   // spring back with a little bounce
            self.stretch.target = 0
            self.hideAt = CACurrentMediaTime() + 0.9
            self.startLink()
        }
    }

    private func post(_ u: Update) {
        lock.lock()
        let schedule = pending == nil
        pending = u
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    // MARK: - Main thread

    private func flush() {
        lock.lock(); let u = pending; pending = nil; lock.unlock()
        guard let u else { return }
        let p = panel ?? build()
        let now = CACurrentMediaTime()
        let appearing = presence.target == 0 || !p.isVisible

        if appearing { position(p) }

        switch u.mode {
        case .level(let kind):
            let wasMessage = bar.isHidden
            bar.isHidden = false
            label.isHidden = true
            if appearing || wasMessage { level.snap(u.value) } else { level.target = u.value }
            stretch.configure(response: 0.07, dampingFraction: 1)
            stretch.target = rubberBand(u.overshoot * bar.trackWidth, dimension: Self.maxStretch)
            dragging = true
            lastDragEvent = now
            hideAt = now + 1.2
            updateSymbol(kind, u.value)
        case .message(let symbol, let text):
            bar.isHidden = true
            label.isHidden = false
            label.stringValue = text
            setSymbol(symbol, variable: nil)
            hideAt = now + 1.1
        }

        if appearing {
            presence.configure(response: 0.3, dampingFraction: 0.78)
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        presence.target = 1
        startLink()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame == 0 ? 1.0 / 120 : min(now - lastFrame, 1.0 / 30)
        lastFrame = now

        if dragging && now - lastDragEvent > 3 { dragging = false }   // missed release safety
        if !dragging && now > hideAt && presence.target != 0 {
            presence.configure(response: 0.35, dampingFraction: 1)
            presence.target = 0
        }

        level.step(dt)
        stretch.step(dt)
        presence.step(dt)

        bar.value = CGFloat(level.value)
        bar.stretch = CGFloat(stretch.value)
        bar.needsDisplay = true

        let pr = presence.value
        panel?.alphaValue = CGFloat(min(1, max(0, pr)))
        let scale = 0.92 + 0.08 * pr
        let c = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        container.layer?.sublayerTransform = t

        if presence.target == 0 && pr < 0.002 {
            panel?.orderOut(nil)
            presence.snap(0)
            stopLink()
        } else if !dragging && level.settled && stretch.settled && presence.settled && presence.target == 1 && now < hideAt - 0.05 {
            // Idle while visible: nothing to animate until hide time.
            stopLink()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, hideAt - now)) { [weak self] in self?.startLink() }
        }
    }

    private func startLink() {
        guard let container else { return }
        if link == nil {
            let l = container.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        if link?.isPaused == true { lastFrame = 0 }
        link?.isPaused = false
    }

    private func stopLink() { link?.isPaused = true; lastFrame = 0 }

    private func updateSymbol(_ kind: SliderController.Kind, _ v: Double) {
        switch kind {
        case .volume:
            v <= 0.001 ? setSymbol("speaker.slash.fill", variable: nil)
                       : setSymbol("speaker.wave.3.fill", variable: (v * 20).rounded() / 20)
        case .brightness:
            setSymbol(v < 0.5 ? "sun.min.fill" : "sun.max.fill", variable: nil)
        case .keyboard:
            setSymbol(v <= 0.001 ? "light.min" : "light.max", variable: nil)
        }
    }

    private func setSymbol(_ name: String, variable: Double?) {
        let key = "\(name)|\(variable ?? -1)"
        guard key != symbolKey else { return }
        symbolKey = key
        icon.image = variable.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: (vf.midX - Self.size.width / 2).rounded(), y: vf.minY + 72))
        }
    }

    private func build() -> NSPanel {
        let rect = NSRect(origin: .zero, size: Self.size)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        container = NSView(frame: rect)
        container.wantsLayer = true

        let bg = NSVisualEffectView(frame: rect)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true

        icon.frame = NSRect(x: 16, y: 14, width: 30, height: 28)
        icon.symbolConfiguration = .init(pointSize: 19, weight: .semibold)
        icon.imageAlignment = .alignLeft
        icon.contentTintColor = .labelColor
        bar.frame = NSRect(x: 58 - LevelBar.inset, y: 23, width: 186 + 2 * LevelBar.inset, height: 10)
        label.frame = NSRect(x: 58, y: 18, width: 192, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail

        [icon, bar, label].forEach(bg.addSubview)
        container.addSubview(bg)
        p.contentView = container
        panel = p
        return p
    }
}

/// Track + fill. `stretch` (px) extends the track past its end (+ right, − left) and thins it,
/// the way iOS sliders deform under rubber-banding.
private final class LevelBar: NSView {
    static let inset: CGFloat = 16
    var value: CGFloat = 0
    var stretch: CGFloat = 0
    var trackWidth: Double { Double(bounds.width - 2 * Self.inset) }

    override func draw(_ dirtyRect: NSRect) {
        var track = bounds.insetBy(dx: Self.inset, dy: 0)
        let squish = min(abs(stretch) / Self.inset, 1) * 0.35
        let h = (bounds.height - 2) * (1 - squish)
        if stretch > 0 { track.size.width += stretch } else { track.origin.x += stretch; track.size.width -= stretch }
        track = NSRect(x: track.minX, y: bounds.midY - h / 2, width: track.width, height: h)

        let r = h / 2
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()

        let v = min(1, max(0, value))
        guard v > 0.001 else { return }
        let w = max(h, track.width * v)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: h), xRadius: r, yRadius: r).fill()
    }
}
