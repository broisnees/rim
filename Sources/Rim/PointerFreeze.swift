import AppKit

/// Keeps the pointer visually still during a zone gesture.
///
/// macOS moves the cursor before any event tap sees the motion, so swallowing events alone makes the pointer
/// jitter (it moves, then gets warped back). The technique (as used by Mac Mouse Fix's PointerFreeze): hide the
/// real cursor (allowed for a background app via the `SetsCursorInBackground` connection property), keep warping
/// it to the frozen point with no event suppression, and draw an identical stand-in cursor image there.
///
/// Hide/show calls are counted by macOS, so every `freeze` is balanced by exactly one `unfreeze`, on main.
enum PointerFreeze {
    /// Test hook: records "freeze" / "unfreeze" instead of touching the real cursor.
    static var testSink: ((String) -> Void)?

    private static var frozen = false          // main thread only
    private static var window: NSWindow?
    private static var imageView: NSImageView?
    private static var prepared = false

    /// One-time setup: allow hiding the cursor while Rim isn't the front app, and remove the post-warp lag.
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        typealias DefaultConn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        if let a = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
           let b = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") {
            let conn = unsafeBitCast(a, to: DefaultConn.self)()
            _ = unsafeBitCast(b, to: SetProp.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
        if let src = CGEventSource(stateID: .combinedSessionState) { src.localEventsSuppressionInterval = 0 }
    }

    /// Freeze at `point` (global top-left coordinates). Safe from any thread.
    static func freeze(at point: CGPoint) {
        if let sink = testSink { sink("freeze"); return }
        DispatchQueue.main.async {
            guard !frozen else { return }
            frozen = true
            prepare()
            showStandIn(at: point)
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }

    /// Unfreeze; the real cursor reappears at `point` (or where it is). Safe from any thread; idempotent.
    static func unfreeze(at point: CGPoint? = nil) {
        if let sink = testSink { sink("unfreeze"); return }
        DispatchQueue.main.async {
            guard frozen else { return }
            frozen = false
            if let point { CGWarpMouseCursorPosition(point); CGAssociateMouseAndMouseCursorPosition(1) }
            CGDisplayShowCursor(CGMainDisplayID())
            window?.orderOut(nil)
        }
    }

    // MARK: Stand-in cursor

    private static func showStandIn(at point: CGPoint) {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        let w = window ?? makeWindow()
        imageView?.image = image
        // Global CG (top-left of the primary display) → Cocoa (bottom-left), aligned on the hot spot.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(x: point.x - cursor.hotSpot.x, y: primaryHeight - point.y - (image.size.height - cursor.hotSpot.y))
        w.setFrame(NSRect(origin: origin, size: image.size), display: true)
        w.orderFrontRegardless()
    }

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSImageView()
        v.imageScaling = .scaleNone
        w.contentView = v
        imageView = v
        window = w
        return w
    }
}
