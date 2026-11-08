import Foundation
import CoreAudio
import Combine
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "OutputVolumeMonitor")

/// Mirrors the active output device's hardware volume so the menu bar icon can
/// show it live (issue #118). Display-only: it never writes volume — the OS
/// volume keys remain the control surface.
///
/// Owns Core Audio property listeners (volume + mute) on the current device and
/// rebinds them whenever the selected output changes; the listeners are keyed
/// by `AudioDeviceID`, which differs per device. Mirrors `DeviceManager`'s
/// listener-ownership style: hold the listener objects, drop them to deregister
/// (their `deinit` removes the block).
@MainActor
final class OutputVolumeMonitor: ObservableObject {
    /// Current output volume as 0...1, or `nil` when the device has no software
    /// volume control (HDMI, optical, fixed line-outs). The menu bar falls back
    /// to the plain brand mark in that case.
    @Published private(set) var volume: Float?
    @Published private(set) var isMuted: Bool = false

    private var boundDeviceID: AudioDeviceID?
    private var boundDeviceUID: String?
    private var volumeListener: AudioDevicePropertyListener?
    private var muteListener: AudioDevicePropertyListener?
    private var isClampingVolume: Bool = false

    weak var preferences: OutputSelectionPreferences?

    init(preferences: OutputSelectionPreferences? = nil) {
        self.preferences = preferences
    }

    /// Point the monitor at a new output device (or `nil` to tear down).
    func rebind(to device: AudioDevice?, isDeviceSwitch: Bool = false) {
        rebind(to: device?.id, uid: device?.uid, isDeviceSwitch: isDeviceSwitch)
    }

    /// Point the monitor at a new output device (or `nil` to tear down). Re-reads
    /// synchronously so the published values aren't stale for a notification
    /// cycle, then installs fresh listeners. No-op if already bound to `deviceID` and `uid`.
    func rebind(to deviceID: AudioDeviceID?, uid: String? = nil, isDeviceSwitch: Bool = false) {
        guard deviceID != boundDeviceID || uid != boundDeviceUID else { return }
        boundDeviceID = deviceID
        boundDeviceUID = uid

        guard let deviceID else {
            volumeListener = nil
            muteListener = nil
            volume = nil
            isMuted = false
            return
        }

        applyConnectVolumeSafety(deviceID: deviceID, uid: uid, isDeviceSwitch: isDeviceSwitch)
        readNow(deviceID)

        // The listener fires on the main queue, but its handler type isn't
        // main-actor-isolated; hop explicitly like DeviceManager does.
        // Wildcard element so we still hear changes on devices that publish
        // volume per channel (elements 1/2) rather than on the main element.
        volumeListener = AudioDevicePropertyListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementWildcard
        ) { [weak self] in
            Task { @MainActor in self?.handleVolumeChange(deviceID) }
        }
        muteListener = AudioDevicePropertyListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ) { [weak self] in
            Task { @MainActor in self?.readNow(deviceID) }
        }
        log.debug("Bound output volume monitor to device \(deviceID)")
    }

    private func applyConnectVolumeSafety(deviceID: AudioDeviceID, uid: String?, isDeviceSwitch: Bool) {
        guard let uid, let prefs = preferences, !isClampingVolume else { return }
        isClampingVolume = true
        defer { isClampingVolume = false }

        let currentVol = CoreAudioVolume.scalar(for: deviceID) ?? 0.0

        // 1. Enforce max volume limit first if active for this device
        if prefs.enforceVolumeLimit(for: uid) {
            let limit = prefs.maxVolumeLimit(for: uid)
            if currentVol > (limit + 0.015) {
                log.info("Volume Limit on connect: clamping device \(deviceID) from \(currentVol) to \(limit)")
                CoreAudioVolume.setScalar(limit, for: deviceID)
            }
        }

        // 2. Safe volume on connect (cap to safeVolumeLevel if louder on device switch)
        if isDeviceSwitch {
            if prefs.safeVolumeOnConnect(for: uid) {
                let safeCap: Float = prefs.safeVolumeLevel(for: uid)
                let effectiveVol = CoreAudioVolume.scalar(for: deviceID) ?? currentVol
                if effectiveVol > (safeCap + 0.015) {
                    log.info("Safe Volume on connect: clamping device \(deviceID) from \(effectiveVol) to \(safeCap)")
                    CoreAudioVolume.setScalar(safeCap, for: deviceID)
                }
            } else if prefs.rememberVolume(for: uid), let saved = prefs.lastVolume(for: uid) {
                log.info("Restoring remembered volume \(saved) for device \(uid)")
                CoreAudioVolume.setScalar(saved, for: deviceID)
            }
        }
    }

    private func handleVolumeChange(_ deviceID: AudioDeviceID) {
        guard deviceID == boundDeviceID, !isClampingVolume else { return }
        let rawVolume = CoreAudioVolume.scalar(for: deviceID)
        let newMuted = CoreAudioVolume.isMuted(for: deviceID)
        if newMuted != isMuted { isMuted = newMuted }

        guard let currentVol = rawVolume, let uid = boundDeviceUID, let prefs = preferences else {
            if rawVolume != volume { volume = rawVolume }
            return
        }

        // Enforce maximum volume limit ceiling if enabled for this device
        if prefs.enforceVolumeLimit(for: uid) {
            let maxLimit = prefs.maxVolumeLimit(for: uid)
            if currentVol > (maxLimit + 0.015) {
                isClampingVolume = true
                defer { isClampingVolume = false }
                log.info("Volume (\(currentVol)) exceeded max limit (\(maxLimit)) for \(uid); clamping")
                CoreAudioVolume.setScalar(maxLimit, for: deviceID)
                self.volume = maxLimit
                if prefs.rememberVolume(for: uid) {
                    prefs.setLastVolume(maxLimit, for: uid)
                }
                return
            }
        }

        if currentVol != volume { volume = currentVol }

        // Remember volume for this device if enabled
        if prefs.rememberVolume(for: uid) {
            prefs.setLastVolume(currentVol, for: uid)
        }
    }

    private func readNow(_ deviceID: AudioDeviceID) {
        // Ignore late callbacks from a device we've since rebound away from.
        guard deviceID == boundDeviceID else { return }
        let newVolume = CoreAudioVolume.scalar(for: deviceID)
        let newMuted = CoreAudioVolume.isMuted(for: deviceID)
        if newVolume != volume { volume = newVolume }
        if newMuted != isMuted { isMuted = newMuted }
    }
}
