import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "AppVolumeStore")

/// Slider-position to amplitude-gain mapping for per-app volume.
///
/// A linear position-to-amplitude mapping crowds all perceived volume change into
/// the very bottom of the slider travel (0.5 is -6 dB, which sounds almost full volume).
/// A cubic taper (gain = position^3) gives a natural, smooth fader feel that matches
/// human hearing perception.
public enum VolumeTaper {
    @inline(__always)
    public static func gain(position: Float) -> Float {
        let p = max(0.0, min(1.0, position))
        return p * p * p
    }
}

/// Volume and mute settings for an individual application, keyed by bundle identifier.
public struct AppVolume: Codable, Equatable {
    /// Slider position: 0.0 (silent) to 1.0 (full/100%).
    public var volume: Float = 1.0
    public var isMuted: Bool = false

    /// Neutral = unmuted and full volume. Neutral apps are bundled into the default
    /// Core Audio mixdown tap with bit-perfect passthrough.
    public var isNeutral: Bool {
        volume >= 0.999 && !isMuted
    }

    public init(volume: Float = 1.0, isMuted: Bool = false) {
        self.volume = max(0.0, min(1.0, volume))
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey {
        case volume, isMuted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let v = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        self.volume = max(0.0, min(1.0, v))
        self.isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
    }
}

/// Persists per-app volume levels across app launches and system reboots.
///
/// Threading: mutations run on the main actor. The audio thread is updated
/// via `onGainChange` with lock-free atomic updates.
@MainActor
public final class AppVolumeStore: ObservableObject {
    private static let defaultsKey = "anmolAudio.appVolumes"

    @Published public private(set) var volumes: [String: AppVolume]

    /// Fired when an app transitions between neutral (100% unmuted) and custom volume,
    /// which requires rebuilding the Core Audio process tap topology.
    public var onConfigurationChange: (() -> Void)?

    /// Fired when a live app's volume slider moves or mute is toggled, allowing
    /// the audio engine to update the DSP gain instantly without restarting the tap.
    public var onGainChange: ((_ bundleID: String, _ gain: Float, _ isMuted: Bool) -> Void)?

    private var saveTask: Task<Void, Never>?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: AppVolume].self, from: data) {
            self.volumes = decoded
        } else {
            self.volumes = [:]
        }
    }

    public func volume(for bundleID: String) -> Float {
        volumes[bundleID]?.volume ?? 1.0
    }

    public func isMuted(for bundleID: String) -> Bool {
        volumes[bundleID]?.isMuted ?? false
    }

    public func effectiveGain(for bundleID: String) -> Float {
        guard let entry = volumes[bundleID] else { return 1.0 }
        if entry.isMuted { return 0.0 }
        return VolumeTaper.gain(position: entry.volume)
    }

    public func setVolume(_ value: Float, for bundleID: String) {
        let clamped = max(0.0, min(1.0, value))
        var entry = volumes[bundleID] ?? AppVolume()
        let oldNeutral = entry.isNeutral
        entry.volume = clamped
        apply(entry, for: bundleID, previousNeutral: oldNeutral)
    }

    public func setMuted(_ isMuted: Bool, for bundleID: String) {
        var entry = volumes[bundleID] ?? AppVolume()
        let oldNeutral = entry.isNeutral
        entry.isMuted = isMuted
        apply(entry, for: bundleID, previousNeutral: oldNeutral)
    }

    public func toggleMute(for bundleID: String) {
        var entry = volumes[bundleID] ?? AppVolume()
        let oldNeutral = entry.isNeutral
        entry.isMuted.toggle()
        apply(entry, for: bundleID, previousNeutral: oldNeutral)
    }

    public func reset(for bundleID: String) {
        guard let oldEntry = volumes[bundleID] else { return }
        let oldNeutral = oldEntry.isNeutral
        volumes.removeValue(forKey: bundleID)
        scheduleSave()
        onGainChange?(bundleID, 1.0, false)
        if !oldNeutral {
            onConfigurationChange?()
        }
    }

    private func apply(_ entry: AppVolume, for bundleID: String, previousNeutral: Bool) {
        if entry.isNeutral {
            volumes.removeValue(forKey: bundleID)
        } else {
            volumes[bundleID] = entry
        }
        scheduleSave()

        // Inform audio thread of live gain update
        let gain = entry.isMuted ? 0.0 : VolumeTaper.gain(position: entry.volume)
        onGainChange?(bundleID, gain, entry.isMuted)

        // Topology rebuild only required when an app transitions to/from neutral
        if entry.isNeutral != previousNeutral {
            log.info("App \(bundleID, privacy: .public) neutral state changed (\(previousNeutral) -> \(entry.isNeutral)); requesting tap reconfiguration")
            onConfigurationChange?()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms debounce
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        // Drop neutral entries to keep storage minimal (< 1 KB)
        let nonNeutral = volumes.filter { !$0.value.isNeutral }
        if let encoded = try? JSONEncoder().encode(nonNeutral) {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
    }
}
