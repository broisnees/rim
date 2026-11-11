import AppKit
import SwiftUI

/// KeyCastr-style action feedback: compact black pills in the bottom-left corner showing the shortcut that ran
/// in large glyphs (⌘C, ⇧⌘1) with the action name beside it. Up to three stack; each fades after a moment.
final class KeyCast: ObservableObject {
    static let shared = KeyCast()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let glyph: String?      // "⌘C" when the action is a keyboard shortcut
        let symbol: String      // SF Symbol otherwise
        let title: String
        let warning: Bool
    }

    @Published private(set) var entries: [Entry] = []
    private var panel: NSPanel?
    private static let size = NSSize(width: 460, height: 230)
    private static let lifetime = 1.6
    private static let maxEntries = 3

    /// Shows an action. `keys` is a combo like "cmd+c" (shown as ⌘C) or nil to show the icon.
    func show(keys: String?, symbol: String, title: String, warning: Bool = false) {
        let glyph = keys.flatMap { $0.isEmpty ? nil : prettyCombo($0) }
        let entry = Entry(glyph: glyph, symbol: symbol, title: title, warning: warning)
        DispatchQueue.main.async {
            self.place()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                self.entries.append(entry)
                if self.entries.count > Self.maxEntries { self.entries.removeFirst(self.entries.count - Self.maxEntries) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) {
                withAnimation(.easeOut(duration: 0.25)) { self.entries.removeAll { $0.id == entry.id } }
            }
        }
    }

    /// Plain message (warnings, notices).
    func message(_ symbol: String, _ text: String) {
        show(keys: nil, symbol: symbol, title: text, warning: symbol.contains("exclamation") || symbol.contains("slash"))
    }

    private func place() {
        let p = panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.minX + 24, y: vf.minY + 24))
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
        let host = NSHostingView(rootView: KeyCastView(model: self))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        panel = p
        return p
    }
}

private struct KeyCastView: View {
    @ObservedObject var model: KeyCast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            ForEach(model.entries) { e in
                KeyCastPill(entry: e)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

private struct KeyCastPill: View {
    let entry: KeyCast.Entry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let glyph = entry.glyph {
                Text(glyph)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(entry.warning ? Color.orange : .white)
                    .frame(minWidth: 26)
            }
            Text(entry.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(entry.glyph == nil ? 0.92 : 0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, entry.glyph == nil ? 12 : 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
        .fixedSize()
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
