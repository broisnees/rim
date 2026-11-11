import AppKit
import SwiftUI

/// "All Apps" or one app's rule: which configuration the page edits.
struct ScopePicker: View {
    @EnvironmentObject private var model: SettingsModel
    var body: some View {
        Picker("Editing", selection: $model.scope) {
            Text("All Apps").tag(String?.none)
            if !model.config.apps.isEmpty { Divider() }
            ForEach(model.config.apps.sorted { $0.value.name < $1.value.name }, id: \.key) { id, rule in
                Text(rule.name).tag(Optional(id))
            }
        }
        .fixedSize()
    }
}

// MARK: - Gestures

struct GesturesPage: View {
    @EnvironmentObject private var model: SettingsModel

    private struct Row { let name, title, subtitle, symbol: String }

    private let taps = [
        Row(name: "threeFingerTap", title: "Three-finger tap", subtitle: "Three fingers together, lift quickly", symbol: "3.circle"),
        Row(name: "fourFingerTap", title: "Four-finger tap", subtitle: "Four fingers together", symbol: "4.circle"),
        Row(name: "fiveFingerTap", title: "Five-finger tap", subtitle: "The whole hand", symbol: "hand.raised"),
    ]
    private let tipTaps = [
        Row(name: "tipTapLeft", title: "Tip-tap left", subtitle: "Rest a finger, tap another to its left", symbol: "hand.point.left"),
        Row(name: "tipTapRight", title: "Tip-tap right", subtitle: "Rest a finger, tap another to its right", symbol: "hand.point.right"),
    ]
    private let tipSwipes = [
        Row(name: "tipSwipeRight", title: "Tip-swipe right", subtitle: "Rest a finger, slide the one beside it right", symbol: "arrow.right"),
        Row(name: "tipSwipeLeft", title: "Tip-swipe left", subtitle: "…slide it left", symbol: "arrow.left"),
        Row(name: "tipSwipeUp", title: "Tip-swipe up", subtitle: "…slide it up", symbol: "arrow.up"),
        Row(name: "tipSwipeDown", title: "Tip-swipe down", subtitle: "…slide it down", symbol: "arrow.down"),
    ]
    private let twoFingerSwipes = [
        Row(name: "twoFingerSwipeRight", title: "Two-finger swipe right", subtitle: "Quick flick with two fingers to the right", symbol: "hand.draw"),
        Row(name: "twoFingerSwipeLeft", title: "Two-finger swipe left", subtitle: "Quick flick with two fingers to the left", symbol: "hand.draw"),
    ]
    private let hands = [
        Row(name: "twoHandTap", title: "Two-hand tap", subtitle: "One finger from each hand, far apart, together", symbol: "hands.clap"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageIntro("Multi-finger and two-hand gestures. macOS swipes and three-finger drag keep working.", padded: false)
                Spacer()
                Menu {
                    ForEach(GesturePreset.all, id: \.name) { p in
                        Button { p.apply(&model.config.gestures) } label: { Label(p.name, systemImage: p.symbol) }
                    }
                } label: { Label("Presets", systemImage: "wand.and.stars") }
                .fixedSize()
                .disabled(model.scope != nil)
                ScopePicker()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Form {
                if model.scope == nil {
                    Section {
                        Toggle("Multi-finger gestures", isOn: $model.config.gestures.enabled)
                    } footer: {
                        VStack(alignment: .leading) { Text(SystemGestures.threeFingerDrag
                             ? "Three-finger drag is on, so only taps are offered for three fingers; dragging keeps working."
                             : "Only taps are used, so system swipes and pinches keep working.") }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    }
                }
                section("Finger Taps", taps)
                section("Tip-Tap", tipTaps, footer: "Keep one finger resting still for a moment, then tap once with another finger beside it. Great for tabs: left = previous, right = next.")
                section("Tip-Swipe", tipSwipes, footer: "Keep one finger resting, slide the neighbouring finger. The action repeats as you slide (great for seeking video or volume); the page doesn't scroll meanwhile.")
                section("Two-Finger Swipe", twoFingerSwipes, footer: "A quick sideways flick; slow sideways scrolling is unaffected. Browsers already go back / forward on this swipe (Trackpad settings → Swipe between pages), so set it per app for apps that don't, e.g. Finder, Xcode, VS Code, Figma or a video player.")
                section("Two Hands", hands, footer: "Two fingers at least 5.5 cm apart. A normal two-finger tap (right click) is never affected.")
            }
            .formStyle(.grouped)
            .disabled(!model.config.gestures.enabled)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [Row], footer: String? = nil) -> some View {
        Section {
            ForEach(rows, id: \.name) { r in
                if model.scope != nil {
                    Toggle("Different in \(model.scopeName)", isOn: model.gestureOverridden(r.name))
                        .font(.caption)
                }
                ActionField(title: r.title, action: model.gestureBinding(r.name), symbol: r.symbol, subtitle: r.subtitle)
                    .disabled(model.scope != nil && !model.gestureOverridden(r.name).wrappedValue)
                if let warning = SystemGestures.conflict(r.name), !model.gestureBinding(r.name).wrappedValue.isNone {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading) { if let footer { Text(footer) } }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Haptics

struct HapticsPage: View {
    @EnvironmentObject private var model: SettingsModel

    private let events: [(String, String, WritableKeyPath<Config.HapticSettings, String>)] = [
        ("Slider steps", "Each of the 16 volume / brightness steps", \.sliderStep),
        ("Slider end", "Hitting 0 % or 100 %", \.sliderEnd),
        ("Corner tap", "A corner action runs", \.cornerTap),
        ("Corner double-tap", "A double-tap action runs", \.cornerDoubleTap),
        ("Edge tap & swipe", "Tapping an edge, or a one-shot slide", \.media),
        ("Gestures", "Multi-finger and two-hand taps", \.gesture),
        ("Tip-tap", "Rest-and-tap gestures", \.tipTap),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageIntro("How each action feels under your finger. You feel it only while touching the trackpad.")
            Form {
                Section {
                    Toggle("Haptic feedback", isOn: $model.config.haptics)
                    LabeledContent("Actuator") {
                        Label(Haptics.forceTouchAvailable ? "Force Touch: full control" : "Basic system feedback",
                              systemImage: Haptics.forceTouchAvailable ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(Haptics.forceTouchAvailable ? .green : .secondary)
                    }
                }

                Section {
                    strength("Light", \.light)
                    strength("Medium", \.medium)
                    strength("Strong", \.strong)
                } header: {
                    Text("Strength")
                } footer: {
                    VStack(alignment: .leading) { Text("Each level uses one of the trackpad's built-in pulses. Rest a finger on the trackpad and press Feel to compare.") }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }

                Section("Feedback for Each Event") {
                    ForEach(events, id: \.0) { title, subtitle, kp in
                        LabeledContent {
                            HStack {
                                Picker("", selection: hb(kp)) {
                                    ForEach(HapticPattern.allCases) { Text($0.title).tag($0.rawValue) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                feel { Haptics.play(HapticPattern(rawValue: model.config.hapticSettings[keyPath: kp]) ?? .none, settings: model.config.hapticSettings) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title)
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(!model.config.haptics)

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(HapticPattern.allCases.filter { $0 != .none }) { p in
                            Button(p.title) { Haptics.play(p, settings: model.config.hapticSettings) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    CommandRow(command: "open -g \"rim://haptic/success\"")
                    CommandRow(command: "/Applications/Rim.app/Contents/MacOS/Rim --haptic error")
                    CommandRow(command: "open -g \"rim://run/playPause\"")
                } header: {
                    Text("Haptic Alerts")
                } footer: {
                    VStack(alignment: .leading) { Text("Scripts can buzz your trackpad, e.g. `make && open -g rim://haptic/success || open -g rim://haptic/error`. `run/` accepts any action that takes no input.") }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func hb<T>(_ kp: WritableKeyPath<Config.HapticSettings, T>) -> Binding<T> {
        Binding(get: { model.config.hapticSettings[keyPath: kp] }, set: { model.config.hapticSettings[keyPath: kp] = $0 })
    }

    private func strength(_ title: String, _ kp: WritableKeyPath<Config.HapticSettings, Int32>) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("", selection: hb(kp)) {
                    ForEach(Haptics.actuatorIDs, id: \.self) { Text("Pulse \($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                feel { Haptics.pulse(model.config.hapticSettings[keyPath: kp]) }
            }
        }
    }

    private func feel(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Feel", systemImage: "hand.tap") }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct CommandRow: View {
    let command: String
    @State private var copied = false
    var body: some View {
        HStack {
            Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .controlSize(.small)
        }
    }
}

/// One-click setups for all multi-finger gestures.
struct GesturePreset {
    let name: String
    let symbol: String
    let actions: [String: Action]

    func apply(_ g: inout Config.Gestures) {
        g.enabled = true
        for name in Config.Gestures.names { g.set(name, actions[name] ?? .none) }
    }

    static let all: [GesturePreset] = [
        .init(name: "Video", symbol: "play.rectangle", actions: [
            "tipTapLeft": Action("seekBackward"), "tipTapRight": Action("seekForward"),
            "tipSwipeLeft": Action("seekBackward"), "tipSwipeRight": Action("seekForward"),
            "tipSwipeUp": Action("volumeUp"), "tipSwipeDown": Action("volumeDown"),
            "threeFingerTap": Action("playPause"), "fourFingerTap": Action("videoFullscreen"),
        ]),
        .init(name: "Browsing", symbol: "safari", actions: [
            "tipTapLeft": Action("back"), "tipTapRight": Action("forward"),
            "tipSwipeLeft": Action("previousTab"), "tipSwipeRight": Action("nextTab"),
            "tipSwipeUp": Action("scrollTop"), "tipSwipeDown": Action("scrollBottom"),
            "threeFingerTap": Action("middleClick"), "fourFingerTap": Action("reopenTab"),
        ]),
        .init(name: "Editing", symbol: "doc.text", actions: [
            "tipTapLeft": Action("paste"), "tipTapRight": Action("copy"),
            "tipSwipeLeft": Action("undo"), "tipSwipeRight": Action("redo"),
            "tipSwipeUp": Action("pageUp"), "tipSwipeDown": Action("pageDown"),
            "threeFingerTap": Action("middleClick"), "fourFingerTap": Action("previousApp"),
        ]),
        .init(name: "Default", symbol: "arrow.counterclockwise", actions: [
            "threeFingerTap": Action("middleClick"), "fourFingerTap": Action("previousApp"), "twoHandTap": Action("missionControl"),
        ]),
    ]
}
