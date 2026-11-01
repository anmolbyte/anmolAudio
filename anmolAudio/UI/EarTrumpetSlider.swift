import SwiftUI

/// An EarTrumpet-style sleek line slider with an integrated real-time audio peak meter,
/// magnetic 100% snap notch, volume boost up to 150%, and crisp light/dark mode contrast.
struct EarTrumpetSlider: View {
    @Binding var volume: Float      // 0.0 to 1.5 (0% to 150%)
    let peakLevel: Float           // 0.0 to 1.0 (real-time audio amplitude)
    let isMuted: Bool
    let isBypassed: Bool
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging: Bool = false
    @State private var hasBrokenThroughNotch: Bool = false

    private let maxVolume: Float = 1.5
    private let notchVolume: Float = 1.0
    private var notchRatio: CGFloat { CGFloat(notchVolume / maxVolume) } // ~0.6667 (100% mark)

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let height = geometry.size.height
            let currentVolume = max(0.0, min(maxVolume, volume))
            let fillWidth = width * CGFloat(currentVolume / maxVolume)
            let notchX = width * notchRatio

            // Peak level bar inside the track (bounces with real-time music up to current volume)
            let activePeak = (!isMuted && !isBypassed) ? max(0.0, min(1.0, peakLevel)) : 0.0
            // sqrt expansion gives punchy, natural VU-meter ballistics, scaled directly to the fader fill
            let peakWidth = max(0, min(fillWidth, fillWidth * CGFloat(sqrt(activePeak))))

            ZStack(alignment: .leading) {
                // 1. Background Track Line (crisp contrast in both Light & Dark mode)
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 4)

                // 2. 100% Unity Gain Notch Divider
                Rectangle()
                    .fill(Color.primary.opacity(0.30))
                    .frame(width: 1.5, height: 7)
                    .position(x: notchX, y: height / 2)

                // 3. Volume Track Range Fill (from 0 to thumb) in native macOS neutral gray
                if fillWidth > 0 && !isMuted {
                    if currentVolume <= 1.0 {
                        Capsule()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: fillWidth, height: 4)
                    } else {
                        // Segmented: Neutral gray up to 100%, subtle amber for boost portion
                        HStack(spacing: 0) {
                            Capsule()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: notchX, height: 4)
                            Capsule()
                                .fill(Color.orange.opacity(0.35))
                                .frame(width: fillWidth - notchX, height: 4)
                        }
                    }
                }

                // 4. EarTrumpet Live Audio Peak Meter (richer, darker/brighter tone of the track color)
                if peakWidth > 0.5 {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: peakWidth, height: 4)
                }

                // 5. Sleek Vertical Pill / Bar Thumb (Clean & high-contrast, no bulky AppKit oval)
                let thumbX = max(2, min(width - 2, fillWidth))
                Capsule()
                    .fill(currentVolume > 1.0 ? Color.orange : Color.white)
                    .frame(width: 4, height: 14)
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.20), radius: 1.5, x: 0, y: 1)
                    .position(x: thumbX, y: height / 2)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            hasBrokenThroughNotch = false
                            onEditingChanged?(true)
                        }
                        updateVolume(location: gesture.location.x, totalWidth: width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        hasBrokenThroughNotch = false
                        onEditingChanged?(false)
                    }
            )
            .disabled(isBypassed)
        }
        .frame(height: 20)
    }

    private func updateVolume(location: CGFloat, totalWidth: CGFloat) {
        guard totalWidth > 0 else { return }
        let fraction = Float(max(0.0, min(1.0, location / totalWidth)))
        let raw = fraction * maxVolume

        // Magnetic notch at 100% (1.0)
        let snapRange: Float = 0.04 // 96% to 104%
        if abs(raw - notchVolume) < snapRange {
            if !hasBrokenThroughNotch {
                volume = notchVolume // Snap firmly to 100%
                return
            }
        } else {
            // Once dragged outside the snap window, allow free dragging including boost
            hasBrokenThroughNotch = true
        }

        volume = max(0.0, min(maxVolume, raw))
    }
}

/// An inline percentage label that can be double-clicked to directly type in a percentage (0-150%).
struct EditablePercentageLabel: View {
    @Binding var volume: Float
    let isMuted: Bool
    let isBypassed: Bool

    @State private var isEditing: Bool = false
    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing && !isBypassed {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.caption2.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 32)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        isEditing = false
                    }
            } else {
                let text = isBypassed ? "Bypassed" : (isMuted ? "Muted" : "\(Int(round(volume * 100)))%")
                let isBoosted = volume > 1.005 && !isMuted && !isBypassed

                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isMuted ? Color.red : (isBoosted ? Color.orange : Color.secondary))
                    .frame(minWidth: 28, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isBypassed else { return }
                        inputText = "\(Int(round(volume * 100)))"
                        isEditing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isFocused = true
                        }
                    }
                    .help(isBypassed ? "Bypassed from EQ" : "Double-click to type volume (0-150%)")
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing {
                commitEdit()
            }
        }
    }

    private func commitEdit() {
        isEditing = false
        if let val = Int(inputText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let clamped = max(0, min(150, val))
            volume = Float(clamped) / 100.0
        }
    }
}
