import AppKit
import SwiftUI

// MARK: - Color tokens

/// Semantic colors for the zone diagram. Views use only these roles; values come from one neutral
/// ramp (system label grays) plus the system accent. Hue never encodes zone type (icons do);
/// the accent means "selected or live" only.
enum ZoneColor {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Trackpad glass.
    static let surface = dynamic(light: NSColor(white: 0.985, alpha: 1), dark: NSColor(white: 0.155, alpha: 1))
    static let surfaceBorder = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.10))
    static let surfaceShadow = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 0, alpha: 0.45))
    /// Configured zone.
    static let tile = dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.075))
    static let tileHover = dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.12))
    static let tileBorder = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let icon = Color(nsColor: .secondaryLabelColor)
    /// Zone with nothing assigned: dashed outline and "+" (secondary gray: ≥ 3:1 on the surface).
    static let emptyBorder = Color(nsColor: .secondaryLabelColor)
    static let emptyIcon = Color(nsColor: .secondaryLabelColor)
    /// Second line of zone labels (≥ 4.5:1 on the window in both themes).
    static let labelDetail = dynamic(light: NSColor(white: 0, alpha: 0.62), dark: NSColor(white: 1, alpha: 0.62))
    /// Selection and live touch (the only accent uses).
    static let selectedFill = Color.accentColor.opacity(0.18)
    static let selectedBorder = Color.accentColor
    static let selectedIcon = Color.accentColor
    /// Selected label marker (non-text, ≥ 3:1); label text itself stays primary, accent text is < 4.5:1.
    static let selectedMarker = Color.accentColor
    static let touch = Color.accentColor
}

// MARK: - Trackpad drawing

/// Interactive trackpad diagram with all eight zones.
/// Regions follow detection priority (corners → left/right edges → top/bottom edges) so nothing overlaps.
/// One spacing unit (6 pt) is used for the rim inset and every gap; corner tiles are concentric with the rim.
/// Labels sit outside, 8 pt from the surface, and name the actions.
struct TrackpadView: View {
    let config: Config
    @Binding var selection: ZoneID
    var interactive = true
    var sideWidth: CGFloat = 96
    /// Which zone's popover is open (owned by the page so links can open one).
    var editing: Binding<ZoneID?> = .constant(nil)
    /// When set, clicking a zone (or its label) opens this editor in a popover next to it.
    var editor: ((ZoneID) -> AnyView)? = nil
    @ObservedObject private var feed = TouchFeed.shared
    @State private var hovered: ZoneID?

    static let aspect: CGFloat = 124.8 / 76.8
    private static let unit: CGFloat = 6          // rim inset = gap between tiles
    private static let tileRadius: CGFloat = 7

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                spacer
                HStack(alignment: .bottom, spacing: 16) {
                    cornerLabel(.topLeft)
                    Spacer(minLength: 0)
                    edgeLabel(.top)
                    Spacer(minLength: 0)
                    cornerLabel(.topRight)
                }
                spacer
            }
            GridRow {
                edgeLabel(.left)
                surface
                edgeLabel(.right)
            }
            GridRow {
                spacer
                HStack(alignment: .top, spacing: 16) {
                    cornerLabel(.bottomLeft)
                    Spacer(minLength: 0)
                    edgeLabel(.bottom)
                    Spacer(minLength: 0)
                    cornerLabel(.bottomRight)
                }
                spacer
            }
        }
    }

    private var spacer: some View { Color.clear.frame(width: sideWidth, height: 0) }

    // MARK: Geometry

    private struct Region: Identifiable {
        let id: ZoneID
        let rect: CGRect      // normalized, top-left origin
        let outer: Corner?
        let symbol: String
        let enabled: Bool
    }

    static func symbol(_ b: EdgeBinding, _ e: Edge) -> String {
        switch b.slide {
        case "volume": return "speaker.wave.2.fill"
        case "brightness": return "sun.max.fill"
        case "keyboard": return "light.max"
        case "scroll": return e.vertical ? "scroll" : "arrow.left.and.right.text.vertical"
        case "appSwitcher": return "square.stack.3d.forward.dottedline"
        case "actions" where b.slides: return e.vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        default:
            let a = !b.tap.isNone ? b.tap : !b.doubleTap.isNone ? b.doubleTap : b.hold
            return a.isNone ? "plus" : ActionCatalog.info(a.type).symbol
        }
    }

    static func symbol(_ b: CornerBinding) -> String {
        let a = !b.tap.isNone ? b.tap : !b.doubleTap.isNone ? b.doubleTap : b.hold
        return ActionCatalog.info(a.type).symbol
    }

    private var regions: [Region] {
        let c = config.corners, e = config.edges
        let cw = CGFloat(c.width), ch = CGFloat(c.height), ew = CGFloat(e.width), eh = CGFloat(e.height)
        var out: [Region] = []
        for k in Corner.allCases {
            let left = k == .topLeft || k == .bottomLeft, top = k == .topLeft || k == .topRight
            let b = c.binding(k)
            out.append(Region(id: .corner(k), rect: CGRect(x: left ? 0 : 1 - cw, y: top ? 0 : 1 - ch, width: cw, height: ch),
                              outer: k, symbol: Self.symbol(b), enabled: c.enabled && !b.isNone))
        }
        let x0 = max(ew, cw)
        let rects: [Edge: CGRect] = [
            .left: CGRect(x: 0, y: ch, width: ew, height: 1 - 2 * ch),
            .right: CGRect(x: 1 - ew, y: ch, width: ew, height: 1 - 2 * ch),
            .top: CGRect(x: x0, y: 0, width: 1 - 2 * x0, height: eh),
            .bottom: CGRect(x: x0, y: 1 - eh, width: 1 - 2 * x0, height: eh),
        ]
        for edge in Edge.allCases {
            let b = e.binding(edge)
            out.append(Region(id: .edge(edge), rect: rects[edge]!, outer: nil,
                              symbol: Self.symbol(b, edge), enabled: e.enabled && !b.isNone))
        }
        return out
    }

    // MARK: Surface

    private var surface: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let R = min(max(min(W, H) * 0.075, 14), 22)
            let u = Self.unit
            // Tiles live in the rim-inset area; each tile is inset by half a gap so gaps and rim are both `u`.
            let inner = CGRect(x: u / 2, y: u / 2, width: W - u, height: H - u)
            let shape = RoundedRectangle(cornerRadius: R, style: .continuous)

            ZStack(alignment: .topLeading) {
                shape
                    .fill(ZoneColor.surface)
                    .shadow(color: ZoneColor.surfaceShadow, radius: 10, y: 4)
                    .overlay(shape.strokeBorder(ZoneColor.surfaceBorder, lineWidth: 1))

                ForEach(regions) { r in
                    let px = CGRect(x: inner.minX + r.rect.minX * inner.width, y: inner.minY + r.rect.minY * inner.height,
                                    width: r.rect.width * inner.width, height: r.rect.height * inner.height)
                        .insetBy(dx: u / 2, dy: u / 2)
                        .integral
                    tile(r, px, outerRadius: max(Self.tileRadius, R - u))
                }

                ForEach(feed.contacts, id: \.id) { c in
                    dot(touching: c.touching)
                        .position(x: CGFloat(c.x) * W, y: CGFloat(1 - c.y) * H)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
    }

    private func radii(_ outer: Corner?, _ R: CGFloat) -> RectangleCornerRadii {
        let r = Self.tileRadius
        return RectangleCornerRadii(topLeading: outer == .topLeft ? R : r, bottomLeading: outer == .bottomLeft ? R : r,
                                    bottomTrailing: outer == .bottomRight ? R : r, topTrailing: outer == .topRight ? R : r)
    }

    private func tile(_ r: Region, _ px: CGRect, outerRadius: CGFloat) -> some View {
        let selected = interactive && selection == r.id
        let hover = interactive && hovered == r.id
        let shape = UnevenRoundedRectangle(cornerRadii: radii(r.outer, outerRadius), style: .continuous)
        let iconSize = max(10, min(15, min(px.width, px.height) * 0.4))

        let fill: Color = selected ? ZoneColor.selectedFill : r.enabled ? (hover ? ZoneColor.tileHover : ZoneColor.tile)
                                                                         : (hover ? ZoneColor.tile : .clear)
        let border: Color = selected ? ZoneColor.selectedBorder : r.enabled ? ZoneColor.tileBorder : ZoneColor.emptyBorder
        let iconColor: Color = selected ? ZoneColor.selectedIcon : r.enabled ? ZoneColor.icon : ZoneColor.emptyIcon

        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(border, style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: r.enabled || selected ? [] : [3, 3])))
            .overlay {
                Image(systemName: r.enabled ? r.symbol : "plus")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .frame(width: max(0, px.width), height: max(0, px.height))
            .contentShape(shape)
            .onTapGesture { select(r.id) }
            .onHover { inside in if interactive { withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? r.id : (hovered == r.id ? nil : hovered) } } }
            .popover(isPresented: Binding(get: { editing.wrappedValue == r.id },
                                          set: { if !$0 && editing.wrappedValue == r.id { editing.wrappedValue = nil } }),
                     arrowEdge: arrowEdge(r.id)) {
                editor?(r.id)
            }
            .help(help(r.id))
            .position(x: px.midX, y: px.midY)
            .animation(.snappy(duration: 0.18), value: selected)
    }

    private func help(_ id: ZoneID) -> String {
        switch id {
        case .corner(let k): return cornerLines(config.corners.binding(k)).joined(separator: "\n")
        case .edge(let e): return ActionCatalog.edgeSummary(config.edges.binding(e), e)
        }
    }

    private func dot(touching: Bool) -> some View {
        ZStack {
            Circle().fill(ZoneColor.touch.opacity(touching ? 0.2 : 0)).frame(width: 30, height: 30)
            Circle()
                .fill(touching ? ZoneColor.touch : Color.secondary.opacity(0.5))
                .frame(width: touching ? 12 : 9, height: touching ? 12 : 9)
        }
    }

    private func select(_ id: ZoneID) {
        guard interactive else { return }
        withAnimation(.snappy(duration: 0.18)) { selection = id }
        guard editor != nil else { return }
        // SwiftUI can't close one popover and open another in the same update: hand over in two steps.
        if let open = editing.wrappedValue, open != id {
            let e = editing
            e.wrappedValue = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { e.wrappedValue = id }
        } else {
            editing.wrappedValue = id
        }
    }

    /// Popovers open away from the trackpad's centre.
    private func arrowEdge(_ id: ZoneID) -> SwiftUI.Edge {
        switch id {
        case .edge(.left), .corner(.topLeft), .corner(.bottomLeft): return .trailing
        case .edge(.right), .corner(.topRight), .corner(.bottomRight): return .leading
        case .edge(.top): return .bottom
        case .edge(.bottom): return .top
        }
    }

    // MARK: Labels (what each zone does)

    private func titleColor(_ id: ZoneID, set: Bool) -> Color {
        set || (interactive && selection == id) ? .primary : ZoneColor.labelDetail
    }

    private func cornerLines(_ b: CornerBinding) -> [String] {
        var l: [String] = []
        if !b.tap.isNone { l.append(ActionCatalog.label(b.tap)) }
        if !b.doubleTap.isNone { l.append("×2 " + ActionCatalog.label(b.doubleTap)) }
        if !b.hold.isNone { l.append("Hold " + ActionCatalog.label(b.hold)) }
        return l
    }

    private var marker: some View { Circle().fill(ZoneColor.selectedMarker).frame(width: 6, height: 6) }

    private func label(_ id: ZoneID, title: String, detail: String, set: Bool, alignment: HorizontalAlignment) -> some View {
        let selected = interactive && selection == id
        return VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 5) {
                if selected && alignment != .trailing { marker }
                Text(title).font(.callout.weight(selected ? .semibold : .medium)).foregroundStyle(titleColor(id, set: set))
                if selected && alignment == .trailing { marker }
            }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(ZoneColor.labelDetail) }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { select(id) }
    }

    private func cornerLabel(_ k: Corner) -> some View {
        let b = config.corners.binding(k)
        let set = config.corners.enabled && !b.isNone
        let lines = cornerLines(b)
        let leading = k == .topLeft || k == .bottomLeft
        return label(.corner(k), title: set ? lines[0] : "Add action",
                     detail: set ? (lines.count > 1 ? lines.dropFirst().joined(separator: " · ") : (b.tap.isNone ? "" : "Tap")) : "",
                     set: set, alignment: leading ? .leading : .trailing)
            .frame(maxWidth: 150, alignment: leading ? .leading : .trailing)
    }

    /// What sliding does, then the tap-like gestures.
    private func edgeLines(_ b: EdgeBinding, _ e: Edge) -> (String, String) {
        guard config.edges.enabled, !b.isNone else { return ("Add action", "") }
        let a = ActionCatalog.arrows(e)
        var title: String, detail: [String] = []
        if b.continuous || b.isScroll || b.isSwitcher { title = ActionCatalog.sliderTitle(b.slide); detail.append("Slide") }
        else if b.slides {
            title = b.forward.isNone ? "\(a.backward) \(ActionCatalog.label(b.backward))" : "\(a.forward) \(ActionCatalog.label(b.forward))"
            if !b.forward.isNone && !b.backward.isNone { detail.append("\(a.backward) \(ActionCatalog.label(b.backward))") }
        } else {
            title = ActionCatalog.label(!b.tap.isNone ? b.tap : !b.doubleTap.isNone ? b.doubleTap : b.hold)
        }
        if b.slides && !b.tap.isNone { detail.append("Tap " + ActionCatalog.label(b.tap)) }
        if !b.doubleTap.isNone && !(title == ActionCatalog.label(b.doubleTap) && b.tap.isNone) { detail.append("×2 " + ActionCatalog.label(b.doubleTap)) }
        if !b.hold.isNone && !(title == ActionCatalog.label(b.hold) && b.tap.isNone && b.doubleTap.isNone) { detail.append("Hold " + ActionCatalog.label(b.hold)) }
        return (title, detail.joined(separator: " · "))
    }

    private func edgeLabel(_ e: Edge) -> some View {
        let b = config.edges.binding(e)
        let (title, detail) = edgeLines(b, e)
        let set = config.edges.enabled && !b.isNone
        let alignment: HorizontalAlignment = e == .left ? .trailing : e == .right ? .leading : .center
        return label(.edge(e), title: title, detail: detail, set: set, alignment: alignment)
            .frame(maxWidth: e.vertical ? sideWidth : 220, alignment: e == .left ? .trailing : e == .right ? .leading : .center)
    }
}

// MARK: - Action picker

struct ActionField: View {
    let title: String
    @Binding var action: Action
    var symbol: String? = nil
    var subtitle: String? = nil
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Menu {
                    ForEach(ActionCatalog.groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { info in
                                Button {
                                    action = Action(info.id, info.input == .none ? nil : (info.id == action.type ? action.value : ""))
                                } label: { Label(info.title, systemImage: info.symbol) }
                            }
                        }
                    }
                } label: {
                    let info = ActionCatalog.info(action.type)
                    Label(info.title.replacingOccurrences(of: "…", with: ""), systemImage: info.symbol)
                }
                .fixedSize()
                valueEditor
            }
        } label: {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(ZoneColor.icon).frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if !action.isNone && !action.isComplete {
                        Label(missingHint, systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var missingHint: String {
        switch ActionCatalog.info(action.type).input {
        case .app: return "Choose an app"
        case .shortcut: return "Choose a Shortcut"
        case .keys: return "Record the keys"
        case .url: return "Enter a URL"
        case .shell: return "Enter a command"
        case .none: return ""
        }
    }

    private var value: Binding<String> {
        Binding(get: { action.value ?? "" }, set: { action.value = $0 })
    }

    @ViewBuilder private var valueEditor: some View {
        switch ActionCatalog.info(action.type).input {
        case .none:
            EmptyView()
        case .app:
            TextField("App name", text: value).frame(minWidth: 120)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.application]
                if panel.runModal() == .OK, let url = panel.url {
                    action.value = url.deletingPathExtension().lastPathComponent
                }
            }
        case .shortcut:
            if model.shortcuts.isEmpty {
                TextField("Shortcut name", text: value).frame(minWidth: 140).onAppear { model.loadShortcuts() }
            } else {
                Picker("", selection: value) {
                    Text("Choose…").tag("")
                    ForEach(model.shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .keys:
            KeyRecorder(combo: value)
        case .url:
            TextField("https://…", text: value).frame(minWidth: 180)
        case .shell:
            TextField("open ~/Downloads", text: value).font(.body.monospaced()).frame(minWidth: 180)
        }
    }
}

// MARK: - Key recorder

/// Click, press a key combo, done. Produces "ctrl+alt+shift+cmd+k" strings.
struct KeyRecorder: View {
    @Binding var combo: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : (combo.isEmpty ? "Record Shortcut" : prettyCombo(combo)))
                .font(.body.monospaced())
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { stop(); return nil }
            if let name = keyName(e.keyCode) {
                var parts: [String] = []
                let f = e.modifierFlags
                if f.contains(.control) { parts.append("ctrl") }
                if f.contains(.option) { parts.append("alt") }
                if f.contains(.shift) { parts.append("shift") }
                if f.contains(.command) { parts.append("cmd") }
                parts.append(name)
                combo = parts.joined(separator: "+")
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

private let keyNames: [Int: String] = {
    var r: [Int: String] = [:]
    for (name, code) in keyCodes where r[code] == nil || ["return", "escape"].contains(name) { r[code] = name }
    return r
}()

func keyName(_ code: UInt16) -> String? { keyNames[Int(code)] }

/// "ctrl+cmd+s" → "⌃⌘S"
func prettyCombo(_ combo: String) -> String {
    let symbols = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "opt": "⌥", "option": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘", "fn": "fn "]
    let keys = ["space": "Space", "return": "↩", "enter": "↩", "tab": "⇥", "esc": "⎋", "escape": "⎋", "delete": "⌫",
                "left": "←", "right": "→", "up": "↑", "down": "↓"]
    return combo.lowercased().split(separator: "+").map { p in
        let s = String(p)
        return symbols[s] ?? keys[s] ?? s.uppercased()
    }.joined()
}

// MARK: - Small pieces

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

/// One-line page description under the toolbar.
struct PageIntro: View {
    let text: String
    var padded = true
    init(_ text: String, padded: Bool = true) { self.text = text; self.padded = padded }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, padded ? 20 : 0)
            .padding(.top, padded ? 14 : 0)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range).frame(minWidth: 160)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}

extension Binding where Value == Float {
    var double: Binding<Double> { Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Float($0) }) }
}
