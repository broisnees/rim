import AppKit
import SwiftUI

/// First-run tour: welcome → Accessibility → try each gesture → done.
struct OnboardingView: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var step = UserDefaults.standard.bool(forKey: "resumeTourAfterPermission") ? 2 : 0
    @State private var tried: Set<String> = []
    @State private var dummy: ZoneID = .edge(.bottom)

    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: tryIt
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            HStack {
                HStack(spacing: 7) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 && step < steps - 1 { Button("Back") { go(step - 1) } }
                Button(step == steps - 1 ? "Done" : "Continue") { step == steps - 1 ? finish() : go(step + 1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !model.accessibilityGranted)
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            let was = model.accessibilityGranted
            model.refreshStatus()
            if step == 1 && !was && model.accessibilityGranted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { go(2) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gesturePerformed)) { n in
            if let g = n.object as? String { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { _ = tried.insert(g) } }
        }
    }

    private func go(_ s: Int) { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { step = s } }

    private func clearResume() { UserDefaults.standard.removeObject(forKey: "resumeTourAfterPermission") }

    private func finish() {
        clearResume()
        model.config.onboarded = true
        OnboardingWindow.shared.close()
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Welcome to Rim").font(.largeTitle.weight(.bold))
            Text("Your trackpad's edges and corners become controls, with haptics that feel like part of the Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                feature("speaker.wave.2.fill", .blue, "Edge sliders", "Slide along the right edge for volume, left for brightness.")
                feature("square.dashed", .orange, "Corner taps", "Tap or double-tap a corner to run anything: apps, Shortcuts, sidebars.")
                feature("playpause.fill", .green, "Media strip", "Tap the bottom edge to play or pause, swipe to skip.")
                feature("hand.raised.fill", .pink, "Ignores accidents", "Palms, typing and stray touches are filtered out, and it learns your habits.")
            }
            .padding(.top, 6)
        }
    }

    private var permission: some View {
        VStack(spacing: 18) {
            Image(systemName: model.accessibilityGranted ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(model.accessibilityGranted ? .green : .accentColor)
                .contentTransition(.symbolEffect(.replace))
            Text("Allow Accessibility").font(.title.weight(.bold))
            Text("Rim needs Accessibility so a corner tap doesn't also click, and an edge slide doesn't move the pointer. It never reads what you type, only *when* you type, to ignore your palms.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if model.accessibilityGranted {
                Label("Permission granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            } else {
                Button { openAccessibilitySettings() } label: {
                    Label("Open System Settings", systemImage: "gearshape").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Text("Turn on **Rim** in Privacy & Security → Accessibility. This page continues by itself.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 16) {
            Text("Try it").font(.title.weight(.bold))
            TrackpadView(config: model.config, selection: $dummy, interactive: false, sideWidth: 78)
                .frame(width: 530)
            VStack(alignment: .leading, spacing: 10) {
                check("slider", "Slide one finger along the right or left edge")
                check("cornerTap", "Tap a corner")
                check("edgeTap", "Tap the bottom edge (plays / pauses)")
            }
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "menubar.arrow.up.rectangle").font(.system(size: 60)).foregroundStyle(.tint)
            Text("You're all set").font(.largeTitle.weight(.bold))
            Text("Rim lives in your menu bar. Open Settings to change any zone, add per-app rules, or see what it has learned about your touch.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Open Settings") { finish(); SettingsWindow.shared.show(page: .zones) }
                .controlSize(.large)
        }
    }

    // MARK: Pieces

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func check(_ key: String, _ text: String) -> some View {
        let ok = tried.contains(key)
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
            Text(text).foregroundStyle(ok ? .secondary : .primary).strikethrough(ok)
        }
    }
}
