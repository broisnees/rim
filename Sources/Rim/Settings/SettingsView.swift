import AppKit
import SwiftUI

extension SettingsPage {
    /// Content size of each tab; the window animates between them.
    var size: NSSize {
        switch self {
        case .zones: return NSSize(width: 640, height: 680)
        case .gestures: return NSSize(width: 640, height: 600)
        case .haptics: return NSSize(width: 640, height: 620)
        case .apps: return NSSize(width: 640, height: 540)
        case .learning: return NSSize(width: 640, height: 560)
        case .general: return NSSize(width: 640, height: 560)
        }
    }
}

/// One tab: optional permission banner, then the page, at a fixed size.
struct SettingsPageView: View {
    let page: SettingsPage
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.accessibilityGranted { PermissionBanner() }
            Group {
                switch page {
                case .zones: ZonesPage()
                case .gestures: GesturesPage()
                case .haptics: HapticsPage()
                case .apps: AppsPage()
                case .learning: LearningPage()
                case .general: GeneralPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: page.size.width, height: page.size.height)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if model.page == page { model.refreshStatus() }
        }
    }
}

private struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
            Text("Rim needs Accessibility permission to work.").font(.callout)
            Spacer()
            Button("Allow…") { openAccessibilitySettings() }.controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}

struct StatusPill: View {
    @EnvironmentObject private var model: SettingsModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
    private var color: Color { !model.accessibilityGranted ? .orange : model.config.enabled ? .green : .secondary }
    private var text: String { !model.accessibilityGranted ? "Needs Accessibility" : model.config.enabled ? "Active" : "Paused" }
}

// MARK: - Zones

struct ZonesPage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageIntro(model.scope == nil ? "Click any zone to choose what it does. Your fingers show up live."
                                             : "Changes apply only while \(model.scopeName) is in front.", padded: false)
                Spacer()
                ScopePicker()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            TrackpadView(config: model.displayConfig, selection: $model.selection, sideWidth: 84,
                         editing: $model.editingZone) { zone in
                AnyView(ZoneEditor(zone: zone).environmentObject(model))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()
            ZoneSettings()
        }
    }
}

/// Popover shown when a zone is clicked: "when you … → do …" for that zone.
struct ZoneEditor: View {
    let zone: ZoneID
    @EnvironmentObject private var model: SettingsModel

    private var scoped: Bool { model.scope != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            Form {
                switch zone {
                case .corner(let c): cornerRows(c)
                case .edge(let e): edgeRows(e)
                }
            }
            .formStyle(.grouped)
            liveCheck
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(width: 460, height: height + 34)
    }

    private var height: CGFloat {
        switch zone {
        case .corner: return scoped ? 330 : 290
        case .edge(let e):
            let b = model.edgeBinding(e).wrappedValue
            return (b.slide == "actions" ? 560 : 340) + (scoped ? 40 : 0) + (b.doubleTap.isNone ? 0 : 24)
        }
    }

    /// "Try it": shows the last gesture Rim detected in this zone, so you can test while editing.
    private var liveCheck: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                if let e = model.lastEvent, e.zone == zone, ctx.date.timeIntervalSince(e.at) < 30 {
                    Image(systemName: e.text.hasSuffix("not set up yet") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(e.text.hasSuffix("not set up yet") ? Color.orange : Color.green)
                    Text("Detected: \(e.text)").font(.callout)
                    Spacer()
                    Text(ctx.date.timeIntervalSince(e.at) < 2 ? "just now" : "\(Int(ctx.date.timeIntervalSince(e.at))) s ago")
                        .font(.caption).foregroundStyle(ZoneColor.labelDetail)
                } else {
                    Image(systemName: "hand.point.up.left").foregroundStyle(ZoneColor.icon)
                    Text("Try it on your trackpad. Rim shows what it detects here.").font(.callout).foregroundStyle(ZoneColor.labelDetail)
                    Spacer()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZoneColor.icon)
                .frame(width: 34, height: 34)
                .background(ZoneColor.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(scoped ? "In \(model.scopeName)" : "All apps").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .edge(let e) = zone { presets(model.edgeBinding(e)).disabled(!editable) }
        }
    }

    private var title: String {
        switch zone {
        case .corner(let c):
            return ["topLeft": "Top-Left", "topRight": "Top-Right", "bottomLeft": "Bottom-Left", "bottomRight": "Bottom-Right"][c.rawValue]! + " Corner"
        case .edge(let e): return e.title
        }
    }

    private var symbol: String {
        switch zone {
        case .corner(let c): return TrackpadView.symbol(model.cornerBinding(c).wrappedValue)
        case .edge(let e): return TrackpadView.symbol(model.edgeBinding(e).wrappedValue, e)
        }
    }

    private var editable: Bool {
        switch zone {
        case .corner(let c): return !scoped || model.cornerOverridden(c).wrappedValue
        case .edge(let e): return !scoped || model.edgeOverridden(e).wrappedValue
        }
    }

    // MARK: Corner

    @ViewBuilder private func cornerRows(_ c: Corner) -> some View {
        let binding = model.cornerBinding(c)
        if scoped {
            Section { Toggle("Different in \(model.scopeName)", isOn: model.cornerOverridden(c)) }
        }
        Section {
            ActionField(title: "Tap", action: binding.tap, symbol: "hand.tap", subtitle: "Quick tap in the corner")
            ActionField(title: "Double-tap", action: binding.doubleTap, symbol: "hand.tap.fill", subtitle: "Two quick taps")
            ActionField(title: "Press & hold", action: binding.hold, symbol: "hand.point.up.left.fill",
                        subtitle: "Keep a finger still \(Int(model.config.corners.holdTime * 1000)) ms")
        } footer: {
            Text(binding.wrappedValue.doubleTap.isNone
                 ? "Taps run instantly."
                 : "The single tap waits \(Int(model.config.corners.doubleTapWindow * 1000)) ms to tell it apart from a double-tap.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!editable)
    }

    // MARK: Edge

    @ViewBuilder private func edgeRows(_ e: Edge) -> some View {
        let binding = model.edgeBinding(e)
        let b = binding.wrappedValue
        let arrows = ActionCatalog.arrows(e)
        if scoped {
            Section { Toggle("Different in \(model.scopeName)", isOn: model.edgeOverridden(e)) }
        }
        Section {
            Picker("Slide along the edge", selection: binding.slide) {
                Section("Levels") {
                    Label("Volume", systemImage: "speaker.wave.2.fill").tag("volume")
                    Label("Brightness", systemImage: "sun.max.fill").tag("brightness")
                    Label("Keyboard Light", systemImage: "light.max").tag("keyboard")
                }
                Section("Navigate") {
                    Label("Scroll", systemImage: "scroll").tag("scroll")
                    Label("App Switcher", systemImage: "square.stack.3d.forward.dottedline").tag("appSwitcher")
                }
                Label("Run Actions", systemImage: e.vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right").tag("actions")
                Label("Nothing", systemImage: "nosign").tag("none")
            }
            if b.slide == "actions" {
                ActionField(title: "Slide \(e.vertical ? "up" : "right") \(arrows.forward)", action: binding.forward,
                            symbol: e.vertical ? "arrow.up" : "arrow.right")
                ActionField(title: "Slide \(e.vertical ? "down" : "left") \(arrows.backward)", action: binding.backward,
                            symbol: e.vertical ? "arrow.down" : "arrow.left")
                Picker("Runs", selection: binding.repeats) {
                    Text("Once per swipe").tag(false)
                    Text("Repeatedly while sliding").tag(true)
                }
                SliderRow(title: b.repeats ? "Every" : "After", value: binding.stepMM, range: 5...40) { "\(Int($0)) mm" }
            }
        } footer: {
            Text(b.slide == "actions"
                 ? (b.repeats ? "Each \(Int(b.stepMM)) mm of sliding runs it again, with a tick you can feel."
                              : "One swipe runs it once; a quick flick counts too.")
                 : b.continuous ? "Slide along the edge to change the \(ActionCatalog.sliderTitle(b.slide).lowercased())."
                 : b.isScroll ? "Slide to scroll whatever is under the pointer; flick to glide. Follows your natural-scrolling setting."
                 : b.isSwitcher ? "Slide to move through the app switcher; lift your finger to switch."
                 : "Sliding does nothing on this edge.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!editable)
        Section {
            ActionField(title: "Tap", action: binding.tap, symbol: "hand.tap", subtitle: "Quick tap on the edge")
            ActionField(title: "Double-tap", action: binding.doubleTap, symbol: "hand.tap.fill", subtitle: "Two quick taps")
            ActionField(title: "Press & hold", action: binding.hold, symbol: "hand.point.up.left.fill",
                        subtitle: "Keep a finger still \(Int(model.config.corners.holdTime * 1000)) ms")
        } footer: {
            if !b.doubleTap.isNone {
                Text("The single tap waits \(Int(model.config.corners.doubleTapWindow * 1000)) ms to tell it apart from a double-tap.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!editable)
    }

    private func presets(_ binding: Binding<EdgeBinding>) -> some View {
        Menu {
            ForEach(EdgePreset.all, id: \.name) { p in
                Button { binding.wrappedValue = p.binding } label: { Label(p.name, systemImage: p.symbol) }
            }
        } label: {
            Label("Presets", systemImage: "wand.and.stars")
        }
        .fixedSize()
    }
}

/// Settings that apply to every zone, under the diagram.
private struct ZoneSettings: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Corners", isOn: $model.config.corners.enabled)
                Toggle("Edges", isOn: $model.config.edges.enabled)
            }
            Section("Corners") {
                SliderRow(title: "Width", value: $model.config.corners.width.double, range: 0.07...0.25) { "\(Int($0 * 100))%" }
                SliderRow(title: "Height", value: $model.config.corners.height.double, range: 0.11...0.35) { "\(Int($0 * 100))%" }
                SliderRow(title: "Double-tap window", value: $model.config.corners.doubleTapWindow, range: 0.18...0.5) { "\(Int($0 * 1000)) ms" }
                SliderRow(title: "Hold time", value: $model.config.corners.holdTime, range: 0.3...1.2) { "\(Int($0 * 1000)) ms" }
            }
            Section {
                SliderRow(title: "Left & right width", value: $model.config.edges.width.double, range: 0.07...0.16) { "\(Int($0 * 100))%" }
                SliderRow(title: "Top & bottom height", value: Binding(get: { Double(model.config.edges.height) },
                                                                        set: { model.config.edges.height = Float($0); model.config.edgeHeightCustomized = true }),
                          range: 0.12...0.25) { "\(Int($0 * 100))%" }
                SliderRow(title: "Volume / brightness speed", value: $model.config.edges.speed, range: 0.4...2.5) { String(format: "%.1f×", $0) }
                SliderRow(title: "Acceleration", value: $model.config.edges.acceleration, range: 0...1) { "\(Int($0 * 100))%" }
                Toggle(isOn: $model.config.edges.momentum) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Momentum")
                        Text("Flick a repeating edge and it keeps going, slowing down naturally").font(.caption).foregroundStyle(ZoneColor.labelDetail)
                    }
                }
                Toggle(isOn: $model.config.edges.repeatSpeedup) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Speed up repeated slides")
                        Text("Quick slides in a row go further each time").font(.caption).foregroundStyle(ZoneColor.labelDetail)
                    }
                }
            } header: {
                Text("Edges")
            } footer: {
                Text("Acceleration makes slow slides precise and quick flicks cover the whole range, like the pointer.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .disabled(model.scope != nil)
    }
}

struct EdgePreset {
    let name: String
    let symbol: String
    let binding: EdgeBinding

    static let all: [EdgePreset] = [
        .init(name: "Video Scrubber", symbol: "play.rectangle",
              binding: EdgeBinding(slide: "actions", forward: Action("seekForward"), backward: Action("seekBackward"), repeats: true,
                                   stepMM: 8, tap: Action("playPause"), doubleTap: Action("videoFullscreen"))),
        .init(name: "Scroll Strip", symbol: "scroll", binding: EdgeBinding(slide: "scroll")),
        .init(name: "App Switcher", symbol: "square.stack.3d.forward.dottedline", binding: EdgeBinding(slide: "appSwitcher", stepMM: 12)),
        .init(name: "Slides & Photos", symbol: "photo.on.rectangle",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "right"), backward: Action("keys", "left"), repeats: false, stepMM: 12)),
        .init(name: "Window Cycler", symbol: "macwindow.on.rectangle",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "cmd+`"), backward: Action("keys", "cmd+shift+`"), repeats: true, stepMM: 16)),
        .init(name: "Volume", symbol: "speaker.wave.2.fill", binding: EdgeBinding(slide: "volume")),
        .init(name: "Brightness", symbol: "sun.max.fill", binding: EdgeBinding(slide: "brightness")),
        .init(name: "Keyboard Light", symbol: "light.max", binding: EdgeBinding(slide: "keyboard", tap: Action("keyboardLightToggle"))),
        .init(name: "Copy / Paste", symbol: "doc.on.clipboard",
              binding: EdgeBinding(slide: "actions", forward: Action("paste"), backward: Action("copy"), repeats: false, stepMM: 12)),
        .init(name: "Switch Tabs", symbol: "square.on.square",
              binding: EdgeBinding(slide: "actions", forward: Action("nextTab"), backward: Action("previousTab"), repeats: true, stepMM: 14)),
        .init(name: "Switch Desktops", symbol: "rectangle.split.3x1",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "ctrl+right"), backward: Action("keys", "ctrl+left"), repeats: false, stepMM: 15)),
        .init(name: "Zoom In / Out", symbol: "plus.magnifyingglass",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "cmd+="), backward: Action("keys", "cmd+-"), repeats: true, stepMM: 10)),
        .init(name: "Undo / Redo", symbol: "arrow.uturn.backward",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "cmd+shift+z"), backward: Action("keys", "cmd+z"), repeats: true, stepMM: 14)),
        .init(name: "Tracks & Play / Pause", symbol: "playpause.fill",
              binding: EdgeBinding(slide: "actions", forward: Action("nextTrack"), backward: Action("previousTrack"), repeats: false, stepMM: 18, tap: Action("playPause"), doubleTap: Action("mute"))),
        .init(name: "Back / Forward", symbol: "chevron.left.forwardslash.chevron.right",
              binding: EdgeBinding(slide: "actions", forward: Action("forward"), backward: Action("back"), repeats: false, stepMM: 18)),
        .init(name: "Page Up / Down", symbol: "doc.text",
              binding: EdgeBinding(slide: "actions", forward: Action("keys", "pageup"), backward: Action("keys", "pagedown"), repeats: true, stepMM: 12)),
        .init(name: "Windows Left / Right", symbol: "rectangle.split.2x1",
              binding: EdgeBinding(slide: "actions", forward: Action("windowRight"), backward: Action("windowLeft"), repeats: false, stepMM: 18, tap: Action("windowMaximize"))),
        .init(name: "Off", symbol: "nosign", binding: EdgeBinding()),
    ]
}

// MARK: - Per-app rules

struct AppsPage: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var presetResult: String?

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            PageIntro("Turn Rim off in games and drawing apps, or give an app its own corners, gestures and shortcuts.", padded: false)

            HStack {
                Menu {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button {
                            model.addRule(bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!)
                        } label: {
                            Label { Text(app.localizedName ?? "") } icon: { Image(nsImage: app.icon ?? NSImage()) }
                        }
                        .disabled(model.config.apps[app.bundleIdentifier!] != nil)
                    }
                } label: { Label("Add Running App", systemImage: "plus") }
                .fixedSize()
                Button("Add Other App…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url { model.addRule(fromAppAt: url) }
                }
                Button("Video Scrubber in Browsers & Players") {
                    let n = model.addVideoScrubber()
                    presetResult = n == 0 ? "No browsers or video players found." : "Bottom edge now scrubs video in \(n) app\(n == 1 ? "" : "s"); other apps keep their bottom edge."
                }
                Button("Add Drawing & Game Apps") {
                    let n = model.addCreativePresets()
                    presetResult = n == 0 ? "No new drawing or game apps found." : "Added \(n) app\(n == 1 ? "" : "s") with Rim turned off."
                }
            }
            if let r = presetResult { Text(r).font(.callout).foregroundStyle(.secondary) }

            if model.config.apps.isEmpty {
                ContentUnavailableView("No app rules yet", systemImage: "square.grid.2x2",
                                       description: Text("Rim behaves the same in every app until you add one."))
                    .frame(maxWidth: .infinity, minHeight: 260)
            }

            ForEach(model.config.apps.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }, id: \.key) { id, _ in
                AppRuleCard(id: id)
            }
        }
        .padding(20)
        }
    }
}

private struct AppRuleCard: View {
    let id: String
    @EnvironmentObject private var model: SettingsModel

    private var rule: Binding<Config.AppRule> {
        Binding(get: { model.config.apps[id] ?? Config.AppRule(name: id) }, set: { model.config.apps[id] = $0 })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: appIcon(id)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.wrappedValue.name).font(.headline)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Turn off Rim", isOn: rule.disabled).toggleStyle(.switch)
                    Button(role: .destructive) { withAnimation { model.removeRule(id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove rule")
                }

                if !rule.wrappedValue.disabled {
                    HStack(spacing: 18) {
                        triPicker("Edges", \.edges)
                        triPicker("Corners", \.corners)
                        Spacer()
                        Button {
                            model.scope = id
                            model.page = .zones
                        } label: {
                            let n = rule.wrappedValue.cornerOverrides.count
                            Label(n == 0 ? "Customize Corners…" : "\(n) Custom Corner\(n == 1 ? "" : "s")…", systemImage: "square.dashed")
                        }
                    }
                    DisclosureGroup("Shortcut overrides") {
                        Grid(alignment: .leading, verticalSpacing: 8) {
                            ForEach(["toggleSidebar", "closeTab", "newTab", "reopenTab", "back", "forward"], id: \.self) { type in
                                GridRow {
                                    Text(ActionCatalog.info(type).title).foregroundStyle(.secondary)
                                    KeyRecorder(combo: model.smartKey(id, type))
                                    if !model.smartKey(id, type).wrappedValue.isEmpty {
                                        Button("Reset") { model.smartKey(id, type).wrappedValue = "" }.buttonStyle(.link)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                        Text("Leave empty to let Rim find the right keys for this app automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private func triPicker(_ title: String, _ kp: WritableKeyPath<Config.AppRule, Bool?>) -> some View {
        Picker(title, selection: model.ruleState(id, kp)) {
            ForEach(TriState.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
    }
}

// MARK: - Learning

struct LearningPage: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageIntro("Rim watches how you really tap and point, then tunes its accidental-touch protection to you.")

            Form {
                Section {
                    Toggle("Adapt to how I use the trackpad", isOn: $model.config.guardrails.adaptive)
                    if let s = model.learning {
                        LabeledContent("Progress") {
                            HStack {
                                ProgressView(value: s.progress).frame(width: 180)
                                Text("\(Int(s.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        sampleRow("Finger sizes", s.samples.size, Learner.need.size)
                        sampleRow("Taps", s.samples.tap, Learner.need.tap)
                        sampleRow("Typing → trackpad switches", s.samples.typing, Learner.need.typing)
                    }
                } footer: {
                    VStack(alignment: .leading) { Text("Only clearly intentional touches are used: pointer moves for finger size, taps that clicked for tap timing. Data stays on this Mac.") }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }

                if let s = model.learning {
                    Section("Thresholds") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            GridRow {
                                Text("").gridColumnAlignment(.leading)
                                Text("Default").foregroundStyle(.secondary)
                                Text("Learned").foregroundStyle(.secondary)
                                Text("In use").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            let base = model.config.guardrails
                            let inUse = Learner.shared.guardrails(base)
                            row("Palm size", base.palmSize, s.learned.palmSize, inUse.palmSize, s.samples.size >= Learner.need.size) { String(format: "%.2f", $0) }
                            row("Longest tap", base.maxTap, s.learned.maxTap, inUse.maxTap, s.samples.tap >= Learner.need.tap) { "\(Int($0 * 1000)) ms" }
                            row("Shortest tap", base.minTap, s.learned.minTap, inUse.minTap, s.samples.tap >= Learner.need.tap) { "\(Int($0 * 1000)) ms" }
                            row("Tap movement", base.tapSlop, s.learned.tapSlop, inUse.tapSlop, s.samples.tap >= Learner.need.tap) { String(format: "%.1f mm", $0) }
                            row("Pause after typing", base.typingPause, s.learned.typingPause, inUse.typingPause, s.samples.typing >= Learner.need.typing) { "\(Int($0 * 1000)) ms" }
                        }
                    }
                }

                Section {
                    Button("Reset Learning…", role: .destructive) { confirmReset = true }
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog("Forget everything Rim has learned?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Learner.shared.reset(); model.refreshStatus() }
        }
    }

    private func sampleRow(_ title: String, _ n: Double, _ need: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text("\(Int(min(n, need))) / \(Int(need))").monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: n >= need ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(n >= need ? .green : .secondary)
            }
        }
    }

    private func row<T: BinaryFloatingPoint>(_ title: String, _ base: T, _ learned: T, _ inUse: T, _ ready: Bool,
                                             _ f: @escaping (Double) -> String) -> some View {
        GridRow {
            Text(title)
            Text(f(Double(base))).monospacedDigit().foregroundStyle(.secondary)
            Text(ready ? f(Double(learned)) : "learning…").monospacedDigit().foregroundStyle(ready ? .primary : .tertiary)
            Text(f(Double(inUse))).monospacedDigit().fontWeight(.semibold)
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageIntro("Feedback, permissions and manual tuning.")
            Form {
                Section("Rim") {
                    LabeledContent("Status") { StatusPill() }
                    Toggle("Enabled", isOn: $model.config.enabled)
                    Toggle("Haptic feedback", isOn: $model.config.haptics)
                    Toggle("On-screen indicator", isOn: $model.config.hud)
                    Toggle("Launch at login", isOn: model.launchAtLogin)
                }
                Section("Permissions") {
                    LabeledContent("Accessibility") {
                        if model.accessibilityGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open System Settings") { openAccessibilitySettings() }
                        }
                    }
                    Button("Show Welcome Tour") { OnboardingWindow.shared.show() }
                }
                Section {
                    SliderRow(title: "Pause after typing", value: $model.config.guardrails.typingPause, range: 0.15...1.2) { "\(Int($0 * 1000)) ms" }
                    SliderRow(title: "Palm size", value: $model.config.guardrails.palmSize.double, range: 0.4...5) { String(format: "%.2f", $0) }
                    SliderRow(title: "Slider must start within", value: $model.config.guardrails.activationWindow, range: 0.3...1.5) { "\(Int($0 * 1000)) ms" }
                    SliderRow(title: "Longest tap", value: $model.config.guardrails.maxTap, range: 0.12...0.5) { "\(Int($0 * 1000)) ms" }
                } header: {
                    Text("Accidental Touch")
                } footer: {
                    VStack(alignment: .leading) { Text(model.config.guardrails.adaptive
                         ? "Learning is on: these are starting values, replaced by what Rim learns about you."
                         : "Learning is off: these values are used as-is.") }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
                Section("Advanced") {
                    Toggle("Debug log (~/Library/Logs/Rim.log)", isOn: $model.config.debug)
                    Toggle("Flip trackpad vertically", isOn: $model.config.invertY)
                    HStack {
                        Button("Touch Visualizer") { Visualizer.shared.show() }
                        Button("Reveal Config File") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.shared.url]) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

func openAccessibilitySettings() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}
