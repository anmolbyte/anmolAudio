import Foundation
import CoreAudio
import Combine
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "BalanceLockManager")

/// Automatically monitors the active output device for stereo balance drift (caused by a known
/// macOS Core Audio bug when volume is adjusted or devices re-enumerate) and restores balance to center.
@MainActor
final class BalanceLockManager: ObservableObject {
    private var boundDeviceID: AudioDeviceID?
    private var boundDeviceUID: String?
    private var panControlID: AudioObjectID?
    private var panListener: AudioDevicePropertyListener?
    private var volumeListener: AudioDevicePropertyListener?
    private var isResetting: Bool = false
    private var lastResetTime: Date = .distantPast

    private let preferences: OutputSelectionPreferences
    private var cancellables = Set<AnyCancellable>()

    init(preferences: OutputSelectionPreferences) {
        self.preferences = preferences
        preferences.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAndResetBalance()
                }
            }
            .store(in: &cancellables)
    }

    func rebind(to device: AudioDevice?) {
        rebind(to: device?.id, uid: device?.uid)
    }

    func rebind(to deviceID: AudioDeviceID?, uid: String?) {
        guard deviceID != boundDeviceID || uid != boundDeviceUID else { return }
        tearDown()
        boundDeviceID = deviceID
        boundDeviceUID = uid

        guard let deviceID else { return }

        // Find stereo pan control ('span' class) if available on this device
        panControlID = Self.findStereoPanControl(for: deviceID)
        if let panID = panControlID {
            panListener = AudioDevicePropertyListener(
                deviceID: panID,
                selector: kAudioStereoPanControlPropertyValue,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ) { [weak self] in
                Task { @MainActor in self?.checkAndResetBalance() }
            }
        }

        // Also listen to volume changes on the device (which trigger balance drift)
        volumeListener = AudioDevicePropertyListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementWildcard
        ) { [weak self] in
            Task { @MainActor in self?.checkAndResetBalance() }
        }

        checkAndResetBalance()
        log.debug("Bound balance lock to device \(deviceID) (panControl=\(String(describing: self.panControlID)))")
    }

    func checkAndResetBalance() {
        guard let uid = boundDeviceUID,
              preferences.autoLockBalance(for: uid),
              !isResetting,
              Date().timeIntervalSince(lastResetTime) > 0.35,
              let deviceID = boundDeviceID else { return }
        lastResetTime = Date()
        isResetting = true
        defer { isResetting = false }

        // 1. Check stereo pan control (center = 0.5)
        if let panID = panControlID {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioStereoPanControlPropertyValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var panVal: Float32 = 0.5
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(panID, &addr, 0, nil, &size, &panVal) == noErr {
                if abs(panVal - 0.5) > 0.015 {
                    log.info("Balance drift detected on pan control (\(panVal)). Auto-locking to 0.5")
                    var target: Float32 = 0.5
                    let status = AudioObjectSetPropertyData(panID, &addr, 0, nil, size, &target)
                    if status != noErr {
                        log.warning("Could not reset pan control to center: \(status)")
                    }
                }
            }
        }

        // 2. Check per-channel volume scalars (elements 1 and 2) if device uses per-channel volume
        var v1Addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1
        )
        var v2Addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 2
        )
        if AudioObjectHasProperty(deviceID, &v1Addr) && AudioObjectHasProperty(deviceID, &v2Addr) {
            var v1: Float32 = 0
            var v2: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &v1Addr, 0, nil, &size, &v1) == noErr &&
               AudioObjectGetPropertyData(deviceID, &v2Addr, 0, nil, &size, &v2) == noErr {
                if abs(v1 - v2) > 0.015 {
                    log.info("Balance drift detected on channel volumes (L: \(v1), R: \(v2)). Auto-locking to match")
                    let target = (v1 + v2) / 2.0
                    var val = target
                    _ = AudioObjectSetPropertyData(deviceID, &v1Addr, 0, nil, size, &val)
                    _ = AudioObjectSetPropertyData(deviceID, &v2Addr, 0, nil, size, &val)
                }
            }
        }
    }

    private func tearDown() {
        panListener = nil
        volumeListener = nil
        panControlID = nil
        boundDeviceID = nil
        boundDeviceUID = nil
    }

    private static func findStereoPanControl(for deviceID: AudioDeviceID) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var controls = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &controls) == noErr else {
            return nil
        }
        for controlID in controls {
            var classAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyClass,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cls: AudioClassID = 0
            var clsSize = UInt32(MemoryLayout<AudioClassID>.size)
            if AudioObjectGetPropertyData(controlID, &classAddr, 0, nil, &clsSize, &cls) == noErr,
               cls == kAudioStereoPanControlClassID {
                return controlID
            }
        }
        return nil
    }
}
