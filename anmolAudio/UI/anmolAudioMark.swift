import SwiftUI
import AppKit

/// Clean audio mark for anmolAudio. Uses standard SF Symbols rather than
/// cartoon faces/logos for a sleek, native macOS utility feel.

struct anmolAudioMark: View {
    var face: Bool = false
    var filled: Bool = true
    var primary: Color = .accentColor
    var accent: Color = .secondary

    var body: some View {
        Image(systemName: filled ? "waveform" : "waveform.slash")
            .resizable()
            .scaledToFit()
            .foregroundStyle(primary)
            .padding(4)
    }
}

extension anmolAudioMark {
    /// Standalone speaker glyph mirroring the output volume. Absolutely no logo or brand mark.
    @MainActor
    static func statusBarVolumeImage(
        filled: Bool,
        volume: Float,
        isMuted: Bool,
        pointSize: CGFloat = 18
    ) -> NSImage {
        let symbol: String = switch (isMuted, filled) {
        case (true, true):   "speaker.slash.fill"
        case (true, false):  "speaker.slash"
        case (false, true):  "speaker.wave.3.fill"
        case (false, false): "speaker.wave.3"
        }
        let renderer = ImageRenderer(
            content: Image(systemName: symbol, variableValue: isMuted ? nil : Double(volume))
                .font(.system(size: pointSize * 0.8))
                .foregroundStyle(.black)
                .frame(height: pointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let image = renderer.nsImage {
            image.isTemplate = true
            return image
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize * 0.8, weight: .regular)
        let fallback = NSImage(systemSymbolName: isMuted ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: "Volume")?.withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        fallback.isTemplate = true
        return fallback
    }

    @MainActor
    static func statusBarImage(filled: Bool, pointSize: CGFloat = 18) -> NSImage {
        statusBarVolumeImage(filled: filled, volume: 1.0, isMuted: false, pointSize: pointSize)
    }
}
