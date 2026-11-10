import AppKit
import SwiftUI

/// `Rim --snapshot <dir>`: renders the trackpad diagram (light + dark) to PNGs for design review.
enum Snapshot {
    @MainActor static func run(_ dir: String) {
        ConfigStore.shared.load()
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = TrackpadView(config: ConfigStore.shared.current, selection: .constant(.corner(.bottomRight)))
                .padding(28)
                .frame(width: 720)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("trackpad-\(name).png"))
            }
        }
    }
}
