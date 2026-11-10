import AppKit
import ApplicationServices

/// Moves / resizes the frontmost window through Accessibility.
enum WindowActions {
    static let types: Set<String> = ["windowLeft", "windowRight", "windowTop", "windowBottom", "windowMaximize",
                                     "windowCenter", "windowNextDisplay", "windowMinimize", "fullScreen"]

    static func perform(_ type: String) {
        if type == "fullScreen" { postKeys("ctrl+cmd+f"); return }
        let pid = AppContext.shared.pid
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { apply(type, pid: pid) }
    }

    private static func apply(_ type: String, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
        let win = ref as! AXUIElement

        if type == "windowMinimize" {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        guard let frame = frame(of: win) else { return }

        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        // AX uses top-left origin on the primary display; AppKit uses bottom-left.
        func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height) }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let currentIndex = screens.firstIndex { toAX($0.frame).contains(center) } ?? 0
        let screen = screens[currentIndex]
        let vf = toAX(screen.visibleFrame)

        var target: CGRect
        switch type {
        case "windowLeft": target = CGRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case "windowRight": target = CGRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case "windowTop": target = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height / 2)
        case "windowBottom": target = CGRect(x: vf.minX, y: vf.midY, width: vf.width, height: vf.height / 2)
        case "windowMaximize": target = vf
        case "windowCenter":
            let w = min(frame.width, vf.width), h = min(frame.height, vf.height)
            target = CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
        case "windowNextDisplay":
            guard screens.count > 1 else { return }
            let next = toAX(screens[(currentIndex + 1) % screens.count].visibleFrame)
            // Keep the window's relative position and size.
            let rx = (frame.minX - vf.minX) / vf.width, ry = (frame.minY - vf.minY) / vf.height
            let w = min(frame.width / vf.width * next.width, next.width), h = min(frame.height / vf.height * next.height, next.height)
            target = CGRect(x: next.minX + rx * next.width, y: next.minY + ry * next.height, width: w, height: h)
        default: return
        }
        // Position, size, position again: some apps clamp size against the old position.
        set(win, position: target.origin)
        set(win, size: target.size)
        set(win, position: target.origin)
    }

    private static func frame(of win: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func set(_ win: AXUIElement, position: CGPoint) {
        var p = position
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v) }
    }

    private static func set(_ win: AXUIElement, size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v) }
    }
}

/// Synthetic middle click at the pointer (open link in new tab, close tab, paste in terminals).
func postMiddleClick() {
    let loc = CGEvent(source: nil)?.location ?? .zero
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: loc, mouseButton: .center)
        e?.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        e?.post(tap: .cghidEventTap)
    }
}
