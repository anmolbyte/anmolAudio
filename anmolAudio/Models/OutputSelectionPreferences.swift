import Foundation
import Combine

/// Persisted preferences for how anmolAudio picks and tracks output devices,
/// filters out unwanted destinations (like displays or docks), and handles
/// VoIP call audio.
@MainActor
final class OutputSelectionPreferences: ObservableObject {
    /// A single escalating policy for automatic output switching.
    enum SwitchPolicy: String, CaseIterable, Identifiable {
        case stay
        case followDefault
        case switchToNew

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stay:          return "Do nothing"
            case .followDefault: return "Follow the system default"
            case .switchToNew:   return "Switch to newly connected devices"
            }
        }

        var detail: String {
            switch self {
            case .stay:
                return "anmolAudio keeps playing to the output you pick and never changes it on its own."
            case .followDefault:
                return "When macOS changes its default output \u{2014} say AirPods connect \u{2014} anmolAudio follows along."
            case .switchToNew:
                return "anmolAudio follows the system default and also jumps to any newly connected output, like a USB DAC that macOS detects but doesn\u{2019}t switch to on its own."
            }
        }
    }

    /// Per-device policy for automatic output switching and visibility.
    enum DevicePolicy: String, Codable, CaseIterable, Identifiable {
        case auto = "auto"
        case manualOnly = "manualOnly"
        case ignored = "ignored"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "Auto-switch"
            case .manualOnly: return "Manual only"
            case .ignored: return "Blocked"
            }
        }

        var detail: String {
            switch self {
            case .auto: return "Normal automatic switching when connected or default."
            case .manualOnly: return "Can be selected manually, but anmolAudio will never auto-switch to it."
            case .ignored: return "Completely hidden and blocked from output selection."
            }
        }
    }

    /// Policy for how anmolAudio handles audio during active calls (FaceTime, Zoom).
    enum CallHandlingMode: String, Codable, CaseIterable, Identifiable {
        case bypassCallAudio = "bypassCallAudio"
        case flattenEQKeepPreamp = "flattenEQKeepPreamp"
        case pauseDuringCalls = "pauseDuringCalls"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bypassCallAudio: return "Bypass call audio (Recommended)"
            case .flattenEQKeepPreamp: return "Flatten EQ & keep Preamp"
            case .pauseDuringCalls: return "Pause during calls"
            }
        }

        var detail: String {
            switch self {
            case .bypassCallAudio:
                return "Call audio (FaceTime, Zoom) bypasses anmolAudio directly to hardware with full native volume and echo cancellation. Background music retains full EQ."
            case .flattenEQKeepPreamp:
                return "Call audio passes through anmolAudio with flat EQ filters to protect echo cancellation, while preserving the active preset's preamp level."
            case .pauseDuringCalls:
                return "Suspends anmolAudio entirely during active calls and resumes when you hang up."
            }
        }
    }

    /// Trigger behavior for pausing media during audio/video calls.
    enum CallPauseBehavior: String, Codable, CaseIterable, Identifiable {
        case onAnswer = "onAnswer"
        case onRing = "onRing"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .onAnswer: return "Pause when call is answered"
            case .onRing:   return "Pause immediately on incoming ring"
            }
        }

        var detail: String {
            switch self {
            case .onAnswer:
                return "Auto-detects active call status and pauses playback once the call is connected or in progress."
            case .onRing:
                return "Pauses all media immediately as soon as a ring is received, whether or not the call is accepted."
            }
        }
    }

    /// Persistent record of every audio device anmolAudio has ever encountered.
    struct KnownDeviceRecord: Codable, Identifiable {
        var id: String { uid }
        let uid: String
        var name: String
        var transportType: AudioDeviceTransportType
        var lastSeen: Date
        var policy: DevicePolicy
        var aecDucking: Bool?
        var backgroundAudioDucking: Bool?
        var enablePreampDuringCalls: Bool?
        var enableEQDuringCalls: Bool?
        var enablePreamp: Bool?
        var enableEQ: Bool?
        var bypassCallAudioToDAC: Bool?
        var disableSystemDucking: Bool?
        var muteOnRateChange: Bool?
        var isMonoDownmix: Bool?
        var isChannelSwap: Bool?
        var autoLockBalance: Bool?
        var pan: Float?
        var lastVolume: Float?
        var rememberVolume: Bool?
        var safeVolumeOnConnect: Bool?
        var enforceVolumeLimit: Bool?
        var maxVolumeLimit: Float?
    }

    static let lastOutputUIDKey = "anmolAudio.lastOutputDeviceUID"
    static let switchPolicyKey = "anmolAudio.outputSwitchPolicy"
    static let ignoreDisplayAudioKey = "anmolAudio.ignoreDisplayAudio"
    static let callHandlingModeKey = "anmolAudio.callHandlingMode"
    static let knownDevicesKey = "anmolAudio.knownDevices"
    static let autoLockBalanceKey = "anmolAudio.autoLockBalance"
    static let autoMuteOnDeviceChangeKey = "anmolAudio.autoMuteOnDeviceChange"
    static let autoPauseOnDeviceChangeKey = "anmolAudio.autoPauseOnDeviceChange"
    static let safeVolumeOnConnectKey = "anmolAudio.safeVolumeOnConnect"
    static let pauseMusicOnCallKey = "anmolAudio.pauseMusicOnCall"
    static let resumeMusicAfterCallKey = "anmolAudio.resumeMusicAfterCall"
    static let callPauseBehaviorKey = "anmolAudio.callPauseBehavior"

    // Legacy migration keys
    static let legacyLastOutputUIDKey = "lurar.lastOutputDeviceUID"
    static let legacySwitchPolicyKey = "lurar.outputSwitchPolicy"
    static let legacyFollowModeKey = "lurar.followSystemDefaultMode"

    private let defaults: UserDefaults

    @Published var autoMuteOnDeviceChange: Bool {
        didSet {
            defaults.set(autoMuteOnDeviceChange, forKey: Self.autoMuteOnDeviceChangeKey)
        }
    }

    @Published var autoPauseOnDeviceChange: Bool {
        didSet {
            defaults.set(autoPauseOnDeviceChange, forKey: Self.autoPauseOnDeviceChangeKey)
        }
    }

    @Published var safeVolumeOnConnect: Bool {
        didSet {
            defaults.set(safeVolumeOnConnect, forKey: Self.safeVolumeOnConnectKey)
        }
    }

    @Published var pauseMusicOnCall: Bool {
        didSet {
            defaults.set(pauseMusicOnCall, forKey: Self.pauseMusicOnCallKey)
        }
    }

    @Published var resumeMusicAfterCall: Bool {
        didSet {
            defaults.set(resumeMusicAfterCall, forKey: Self.resumeMusicAfterCallKey)
        }
    }

    @Published var callPauseBehavior: CallPauseBehavior {
        didSet {
            defaults.set(callPauseBehavior.rawValue, forKey: Self.callPauseBehaviorKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoMuteOnDeviceChange = defaults.bool(forKey: Self.autoMuteOnDeviceChangeKey)
        if defaults.object(forKey: Self.autoPauseOnDeviceChangeKey) == nil {
            self.autoPauseOnDeviceChange = true
        } else {
            self.autoPauseOnDeviceChange = defaults.bool(forKey: Self.autoPauseOnDeviceChangeKey)
        }
        if defaults.object(forKey: Self.safeVolumeOnConnectKey) == nil {
            self.safeVolumeOnConnect = true
        } else {
            self.safeVolumeOnConnect = defaults.bool(forKey: Self.safeVolumeOnConnectKey)
        }
        self.pauseMusicOnCall = defaults.bool(forKey: Self.pauseMusicOnCallKey)
        if defaults.object(forKey: Self.resumeMusicAfterCallKey) == nil {
            self.resumeMusicAfterCall = true
        } else {
            self.resumeMusicAfterCall = defaults.bool(forKey: Self.resumeMusicAfterCallKey)
        }
        if let raw = defaults.string(forKey: Self.callPauseBehaviorKey),
           let b = CallPauseBehavior(rawValue: raw) {
            self.callPauseBehavior = b
        } else {
            self.callPauseBehavior = .onAnswer
        }
        purgePrivateAggregateRecords()
    }

    private func purgePrivateAggregateRecords() {
        let current = knownDevices
        self.knownDevices = current
    }

    var lastOutputUID: String? {
        get {
            let val = defaults.string(forKey: Self.lastOutputUIDKey)
                ?? defaults.string(forKey: Self.legacyLastOutputUIDKey) ?? ""
            return val.isEmpty ? nil : val
        }
        set {
            defaults.set(newValue ?? "", forKey: Self.lastOutputUIDKey)
            objectWillChange.send()
        }
    }

    var switchPolicy: SwitchPolicy {
        get {
            if let raw = defaults.string(forKey: Self.switchPolicyKey)
                ?? defaults.string(forKey: Self.legacySwitchPolicyKey),
               let policy = SwitchPolicy(rawValue: raw) {
                return policy
            }
            if let legacy = defaults.string(forKey: Self.legacyFollowModeKey) {
                return legacy == "ignore" ? .stay : .followDefault
            }
            return .followDefault
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.switchPolicyKey)
            objectWillChange.send()
        }
    }

    var followsSystemDefault: Bool { switchPolicy != .stay }
    var switchesToNewDevices: Bool { switchPolicy == .switchToNew }

    /// When true, DisplayPort and HDMI audio devices (monitors/TVs) are automatically
    /// blocked from output selection and autoswitching. Defaults to true.
    var ignoreDisplayAudio: Bool {
        get {
            if defaults.object(forKey: Self.ignoreDisplayAudioKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.ignoreDisplayAudioKey)
        }
        set {
            defaults.set(newValue, forKey: Self.ignoreDisplayAudioKey)
            objectWillChange.send()
        }
    }

    /// Strategy for handling audio during VoIP calls. Defaults to .bypassCallAudio.
    var callHandlingMode: CallHandlingMode {
        get {
            guard let raw = defaults.string(forKey: Self.callHandlingModeKey),
                  let mode = CallHandlingMode(rawValue: raw) else {
                return .bypassCallAudio
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.callHandlingModeKey)
            objectWillChange.send()
        }
    }

    // MARK: - Known Devices & Policy Management

    var knownDevices: [KnownDeviceRecord] {
        get {
            guard let data = defaults.data(forKey: Self.knownDevicesKey),
                  let decoded = try? JSONDecoder().decode([KnownDeviceRecord].self, from: data) else {
                return []
            }
            return decoded
                .filter { record in
                    !record.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
                    !record.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
                    !record.name.contains("System Tap")
                }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
        set {
            let clean = newValue.filter { record in
                !record.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
                !record.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
                !record.name.contains("System Tap")
            }
            if let encoded = try? JSONEncoder().encode(clean) {
                defaults.set(encoded, forKey: Self.knownDevicesKey)
                objectWillChange.send()
            }
        }
    }

    func recordSeen(devices: [AudioDevice]) {
        let validDevices = devices.filter {
            !$0.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
            !$0.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
            !$0.name.contains("System Tap")
        }
        guard !validDevices.isEmpty else { return }

        var list = knownDevices
        let now = Date()
        var changed = false

        for device in validDevices {
            if let idx = list.firstIndex(where: { $0.uid == device.uid }) {
                if list[idx].name != device.name || list[idx].transportType != device.transportType {
                    list[idx].name = device.name
                    list[idx].transportType = device.transportType
                    list[idx].lastSeen = now
                    changed = true
                }
            } else {
                // Smart defaults: Docks default to .manualOnly; Displays default to .ignored
                let initialPolicy: DevicePolicy
                if device.isDisplay {
                    initialPolicy = .ignored
                } else if device.isDock {
                    initialPolicy = .manualOnly
                } else {
                    initialPolicy = .auto
                }
                list.append(KnownDeviceRecord(
                    uid: device.uid,
                    name: device.name,
                    transportType: device.transportType,
                    lastSeen: now,
                    policy: initialPolicy,
                    autoLockBalance: true,
                    pan: 0.0,
                    rememberVolume: true,
                    safeVolumeOnConnect: true,
                    enforceVolumeLimit: false,
                    maxVolumeLimit: 0.60
                ))
                changed = true
            }
        }

        if changed {
            self.knownDevices = list
        }
    }

    func recordSeen(device: AudioDevice) {
        recordSeen(devices: [device])
    }

    func forgetDevice(uid: String) {
        var list = knownDevices
        list.removeAll { $0.uid == uid }
        self.knownDevices = list
    }

    func policy(for uid: String) -> DevicePolicy? {
        knownDevices.first(where: { $0.uid == uid })?.policy
    }

    func setPolicy(_ policy: DevicePolicy, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].policy = policy
            self.knownDevices = list
        }
    }

    // MARK: - Per-Device Audio & Call Options

    static func defaultAECDucking(for transportType: AudioDeviceTransportType, name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("headphone") || n.contains("earphone") || n.contains("airpod") || n.contains("etymotic") || n.contains("iem") {
            // Headphones have no acoustic feedback loop -> keep in tap (AEC ducking not triggered)
            return true
        }
        if transportType == .bluetooth {
            return true
        }
        // Built-in speakers, external speakers, displays, and general docks have acoustic feedback risk
        // -> AEC ducking is disabled by default (calls bypass to DAC)
        return false
    }

    func aecDucking(for uid: String) -> Bool {
        if let rec = knownDevices.first(where: { $0.uid == uid }) {
            if let explicit = rec.aecDucking {
                return explicit
            }
            if let legacyBypass = rec.bypassCallAudioToDAC {
                return !legacyBypass
            }
            return Self.defaultAECDucking(for: rec.transportType, name: rec.name)
        }
        return false
    }

    func setAECDucking(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].aecDucking = value
            list[idx].bypassCallAudioToDAC = !value
            self.knownDevices = list
        }
    }

    func backgroundAudioDucking(for uid: String) -> Bool {
        if let rec = knownDevices.first(where: { $0.uid == uid }) {
            if let explicit = rec.backgroundAudioDucking {
                return explicit
            }
            if let legacyDisable = rec.disableSystemDucking {
                return !legacyDisable
            }
        }
        return true // Standard macOS communication ducking is active by default
    }

    func setBackgroundAudioDucking(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].backgroundAudioDucking = value
            list[idx].disableSystemDucking = !value
            self.knownDevices = list
        }
    }

    func enablePreampDuringCalls(for uid: String) -> Bool {
        if let rec = knownDevices.first(where: { $0.uid == uid }) {
            return rec.enablePreampDuringCalls ?? rec.enablePreamp ?? true
        }
        return true
    }

    func setEnablePreampDuringCalls(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].enablePreampDuringCalls = value
            list[idx].enablePreamp = value
            self.knownDevices = list
        }
    }

    func enableEQDuringCalls(for uid: String) -> Bool {
        if let rec = knownDevices.first(where: { $0.uid == uid }) {
            return rec.enableEQDuringCalls ?? rec.enableEQ ?? true
        }
        return true
    }

    func setEnableEQDuringCalls(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].enableEQDuringCalls = value
            list[idx].enableEQ = value
            self.knownDevices = list
        }
    }

    func enablePreamp(for uid: String) -> Bool {
        enablePreampDuringCalls(for: uid)
    }

    func setEnablePreamp(_ value: Bool, for uid: String) {
        setEnablePreampDuringCalls(value, for: uid)
    }

    func enableEQ(for uid: String) -> Bool {
        enableEQDuringCalls(for: uid)
    }

    func setEnableEQ(_ value: Bool, for uid: String) {
        setEnableEQDuringCalls(value, for: uid)
    }

    func muteOnRateChange(for uid: String) -> Bool {
        if let rec = knownDevices.first(where: { $0.uid == uid }) {
            return rec.muteOnRateChange ?? true
        }
        return true
    }

    func setMuteOnRateChange(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].muteOnRateChange = value
            self.knownDevices = list
        }
    }

    func isMonoDownmix(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.isMonoDownmix ?? false
    }

    func setIsMonoDownmix(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].isMonoDownmix = value
            self.knownDevices = list
        }
    }

    func isChannelSwap(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.isChannelSwap ?? false
    }

    func setIsChannelSwap(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].isChannelSwap = value
            self.knownDevices = list
        }
    }

    func autoLockBalance(for uid: String) -> Bool {
        if let explicit = knownDevices.first(where: { $0.uid == uid })?.autoLockBalance {
            return explicit
        }
        if let global = defaults.object(forKey: Self.autoLockBalanceKey) as? Bool {
            return global
        }
        return true
    }

    func setAutoLockBalance(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].autoLockBalance = value
            self.knownDevices = list
        }
    }

    func pan(for uid: String) -> Float {
        knownDevices.first(where: { $0.uid == uid })?.pan ?? 0.0
    }

    func setPan(_ value: Float, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].pan = max(-1.0, min(1.0, value))
            self.knownDevices = list
        }
    }

    func lastVolume(for uid: String) -> Float? {
        knownDevices.first(where: { $0.uid == uid })?.lastVolume
    }

    func setLastVolume(_ value: Float, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].lastVolume = max(0.0, min(1.0, value))
            self.knownDevices = list
        }
    }

    func rememberVolume(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.rememberVolume ?? true
    }

    func setRememberVolume(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].rememberVolume = value
            self.knownDevices = list
        }
    }

    func safeVolumeOnConnect(for uid: String) -> Bool {
        if let explicit = knownDevices.first(where: { $0.uid == uid })?.safeVolumeOnConnect {
            return explicit
        }
        return self.safeVolumeOnConnect
    }

    func setSafeVolumeOnConnect(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].safeVolumeOnConnect = value
            self.knownDevices = list
        }
    }

    func enforceVolumeLimit(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.enforceVolumeLimit ?? false
    }

    func setEnforceVolumeLimit(_ value: Bool, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].enforceVolumeLimit = value
            self.knownDevices = list
        }
    }

    func maxVolumeLimit(for uid: String) -> Float {
        knownDevices.first(where: { $0.uid == uid })?.maxVolumeLimit ?? 0.60
    }

    func setMaxVolumeLimit(_ value: Float, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].maxVolumeLimit = max(0.10, min(1.0, value))
            self.knownDevices = list
        }
    }

    // Legacy compatibility bridges
    func bypassCallAudioToDAC(for uid: String) -> Bool {
        !aecDucking(for: uid)
    }

    func setBypassCallAudioToDAC(_ value: Bool, for uid: String) {
        setAECDucking(!value, for: uid)
    }

    func disableSystemDucking(for uid: String) -> Bool {
        !backgroundAudioDucking(for: uid)
    }

    func setDisableSystemDucking(_ value: Bool, for uid: String) {
        setBackgroundAudioDucking(!value, for: uid)
    }

    /// Evaluates the effective policy for an audio device, accounting for the global
    /// `ignoreDisplayAudio` setting and per-device overrides.
    func effectivePolicy(for device: AudioDevice) -> DevicePolicy {
        if ignoreDisplayAudio && device.isDisplay {
            return .ignored
        }
        if let explicit = policy(for: device.uid) {
            return explicit
        }
        if device.isDock {
            return .manualOnly
        }
        return .auto
    }
}
