import Foundation

/// Facade kept for existing callers: all on-screen feedback now lives in `KeyCast` (one small-pill style for
/// action notices and the live volume / brightness / keyboard-light level).
final class HUD {
    static let shared = HUD()

    func slider(_ kind: SliderController.Kind, value: Double, overshoot: Double) {
        guard ConfigStore.shared.current.hud else { return }
        KeyCast.shared.level(kind, value: value, overshoot: overshoot)
    }

    func releaseSlider() { KeyCast.shared.releaseLevel() }

    func message(_ symbol: String, _ text: String) { KeyCast.shared.message(symbol, text) }
}
