import AppKit
import SwiftUI

/// On-screen feedback: small black pills centred at the bottom of the screen; they pop in and fade out.
/// - Action pills: icon + name; up to three stack and fade after a moment.
/// - Level pill (volume, brightness, keyboard light): icon, slim bar and percentage, updated live while sliding,
///   with rubber-band stretch past the ends; it fades shortly after the finger lifts.
final class KeyCast: ObservableObject {
    static let shared = KeyCast()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let symbol: String
        let title: String
        let warning: Bool
    }

    struct Level: Equatable {
        var kind: SliderController.Kind
        var value: Double
        var stretch: Double     // px, + past the top, − past the bottom
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var level: Level?

    private var panel: NSPanel?
    private var hideLevel: DispatchWorkItem?
    private let lock = NSLock()
    private var pendingLevel: Level?

    private static let size = NSSize(width: 320, height: 200)
    private static let lifetime = 1.5
    private static let maxEntries = 3
    static let barWidth: CGFloat = 110
    /// Pop in: springs up from smaller with a slight overshoot. Fade out: quick, soft, a touch smaller.
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.62)
    static let fade = Animation.easeIn(duration: 0.22)

    // MARK: Actions

    func message(_ symbol: String, _ text: String) {
        show(symbol: symbol, title: text, warning: symbol.contains("exclamation") || symbol.contains("slash"))
    }

    func show(symbol: String, title: String, warning: Bool = false) {
        let entry = Entry(symbol: symbol, title: title, warning: warning)
        DispatchQueue.main.async {
            self.place()
            withAnimation(Self.pop) {
                self.entries.append(entry)
                if self.entries.count > Self.maxEntries { self.entries.removeFirst(self.entries.count - Self.maxEntries) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) {
                withAnimation(Self.fade) { self.entries.removeAll { $0.id == entry.id } }
            }
        }
    }

    // MARK: Level (any thread; coalesced to one UI update per frame)

    func level(_ kind: SliderController.Kind, value: Double, overshoot: Double) {
        let stretch = rubberBand(overshoot * Double(Self.barWidth), dimension: 12)
        lock.lock()
        let schedule = pendingLevel == nil
        pendingLevel = Level(kind: kind, value: value, stretch: stretch)
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.lock.lock(); let l = self.pendingLevel; self.pendingLevel = nil; self.lock.unlock()
            guard let l else { return }
            self.hideLevel?.cancel()
            self.place()
            if self.level == nil {
                withAnimation(Self.pop) { self.level = l }
            } else {
                withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 1)) { self.level = l }
            }
        }
    }

    /// Finger lifted: spring the stretch back (with a little bounce), then fade the level pill.
    func releaseLevel() {
        DispatchQueue.main.async {
            guard self.level != nil else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { self.level?.stretch = 0 }
            let work = DispatchWorkItem { withAnimation(Self.fade) { self.level = nil } }
            self.hideLevel = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
    }

    // MARK: Window

    private func place() {
        let p = panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: (vf.midX - Self.size.width / 2).rounded(), y: vf.minY + 56))
        }
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: FeedbackStack(model: self))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        panel = p
        return p
    }
}

// MARK: - Views

private struct FeedbackStack: View {
    @ObservedObject var model: KeyCast

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 0)
            ForEach(model.entries) { e in
                Pill { ActionPill(entry: e) }.transition(Self.popTransition)
            }
            if let level = model.level {
                Pill { LevelPill(level: level) }.transition(Self.popTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Pops in from 60 % scale (anchored at its bottom) with a fade; leaves at 90 % while fading out.
    static let popTransition = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
        removal: .scale(scale: 0.9, anchor: .center).combined(with: .opacity))
}

/// Shared pill chrome: small, black, rounded, hairline border.
private struct Pill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            )
            .fixedSize()
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

private struct ActionPill: View {
    let entry: KeyCast.Entry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(entry.warning ? Color.orange : .white)
                .frame(width: 16)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct LevelPill: View {
    let level: KeyCast.Level

    private var symbol: (name: String, variable: Double?) {
        switch level.kind {
        case .volume: return level.value <= 0.001 ? ("speaker.slash.fill", nil) : ("speaker.wave.3.fill", level.value)
        case .brightness: return (level.value < 0.5 ? "sun.min.fill" : "sun.max.fill", nil)
        case .keyboard: return (level.value <= 0.001 ? "light.min" : "light.max", nil)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol.name, variableValue: symbol.variable)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18)
            bar
            Text("\(Int((level.value * 100).rounded()))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 24, alignment: .trailing)
        }
    }

    /// Slim bar; past an end it stretches (rubber band) and thins slightly, like iOS sliders.
    private var bar: some View {
        let w = KeyCast.barWidth
        let s = CGFloat(level.stretch)
        let squish = 1 - min(abs(s) / 40, 0.3)
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(.white).frame(width: max(5, w * CGFloat(min(1, max(0, level.value)))))
        }
        .frame(width: w, height: 5)
        .scaleEffect(x: 1 + abs(s) / w, y: squish, anchor: s >= 0 ? .leading : .trailing)
        .frame(width: w)
    }
}
