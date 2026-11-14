import Foundation
import Combine

/// Persisted preferences for audio input devices (microphones, webcams, interfaces).
/// Manages per-device policies (Auto-switch, Manual only, Blocked), volume memory,
/// ceiling limits, AEC ducking preferences, mono summing, and supreme mic mute state.
@MainActor
final class InputSelectionPreferences: ObservableObject {
    /// Escalating policy for automatic input switching.
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
                return "anmolAudio keeps using the microphone you pick and never changes it on its own."
            case .followDefault:
                return "When macOS changes its default input (say a headset connects), anmolAudio follows along."
            case .switchToNew:
                return "anmolAudio follows the system default and also switches to any newly connected microphone."
            }
        }
    }

    /// Per-device policy for automatic input switching and visibility.
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
            case .manualOnly: return "Can be selected manually, but will never be auto-switched to."
            case .ignored: return "Completely hidden and blocked from input selection."
            }
        }
    }

    /// Persistent record of an input device encountered by anmolAudio.
    struct KnownInputDeviceRecord: Codable, Identifiable {
        var id: String { uid }
        let uid: String
        var name: String
        var transportType: AudioDeviceTransportType
        var lastSeen: Date
        var policy: DevicePolicy
        var rememberVolume: Bool?
        var lastVolume: Float?
        var enforceVolumeLimit: Bool?
        var maxVolumeLimit: Float?
        var triggerAECBypass: Bool?
        var backgroundAudioDucking: Bool?
        var monoSumming: Bool?
        var preferredSampleRate: Double?
    }

    static let lastInputUIDKey = "anmolAudio.lastInputDeviceUID"
    static let inputSwitchPolicyKey = "anmolAudio.inputSwitchPolicy"
    static let supremeMicMutedKey = "anmolAudio.supremeMicMuted"
    static let knownInputDevicesKey = "anmolAudio.knownInputDevices"

    private let defaults: UserDefaults

    static func isPrivateAggregate(uid: String, name: String) -> Bool {
        uid.hasPrefix("app.anmol.anmolAudio.aggregate.") ||
        uid.hasPrefix("app.lurar.Lurar.aggregate.") ||
        uid.hasPrefix("CADefaultDeviceAggregate") ||
        uid.contains("Aggregate") ||
        name.contains("System Tap") ||
        name.contains("Aggregate")
    }

    @Published var knownDevices: [KnownInputDeviceRecord] {
        didSet {
            let clean = knownDevices.filter { record in
                !Self.isPrivateAggregate(uid: record.uid, name: record.name)
            }
            if clean.count != knownDevices.count {
                knownDevices = clean
                return
            }
            if let data = try? JSONEncoder().encode(clean) {
                defaults.set(data, forKey: Self.knownInputDevicesKey)
            }
        }
    }

    @Published var switchPolicy: SwitchPolicy {
        didSet {
            defaults.set(switchPolicy.rawValue, forKey: Self.inputSwitchPolicyKey)
        }
    }

    @Published var isSupremeMicMuted: Bool {
        didSet {
            defaults.set(isSupremeMicMuted, forKey: Self.supremeMicMutedKey)
        }
    }

    var lastInputUID: String? {
        get { defaults.string(forKey: Self.lastInputUIDKey) }
        set {
            if let val = newValue {
                defaults.set(val, forKey: Self.lastInputUIDKey)
            } else {
                defaults.removeObject(forKey: Self.lastInputUIDKey)
            }
        }
    }

    var followsSystemDefault: Bool {
        switchPolicy != .stay
    }

    var switchesToNewDevices: Bool {
        switchPolicy == .switchToNew
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawPolicy = defaults.string(forKey: Self.inputSwitchPolicyKey)
        self.switchPolicy = rawPolicy.flatMap(SwitchPolicy.init(rawValue:)) ?? .followDefault

        self.isSupremeMicMuted = defaults.bool(forKey: Self.supremeMicMutedKey)

        if let data = defaults.data(forKey: Self.knownInputDevicesKey),
           let list = try? JSONDecoder().decode([KnownInputDeviceRecord].self, from: data) {
            self.knownDevices = list.filter {
                !Self.isPrivateAggregate(uid: $0.uid, name: $0.name)
            }
        } else {
            self.knownDevices = []
        }
    }

    func effectivePolicy(for device: AudioDevice) -> DevicePolicy {
        if let rec = knownDevices.first(where: { $0.uid == device.uid }) {
            return rec.policy
        }
        if device.isDock { return .manualOnly }
        return .auto
    }

    func recordSeen(device: AudioDevice) {
        if Self.isPrivateAggregate(uid: device.uid, name: device.name) {
            return
        }
        let now = Date()
        if let idx = knownDevices.firstIndex(where: { $0.uid == device.uid }) {
            var updated = knownDevices[idx]
            updated.name = device.name
            updated.transportType = device.transportType
            updated.lastSeen = now
            knownDevices[idx] = updated
        } else {
            let defaultPolicy: DevicePolicy = device.isDock ? .manualOnly : .auto
            let record = KnownInputDeviceRecord(
                uid: device.uid,
                name: device.name,
                transportType: device.transportType,
                lastSeen: now,
                policy: defaultPolicy
            )
            knownDevices.append(record)
        }
    }

    func policy(for uid: String) -> DevicePolicy? {
        knownDevices.first(where: { $0.uid == uid })?.policy
    }

    func setPolicy(_ policy: DevicePolicy, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].policy = policy
    }

    func rememberVolume(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.rememberVolume ?? false
    }

    func setRememberVolume(_ val: Bool, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].rememberVolume = val
    }

    func lastVolume(for uid: String) -> Float? {
        knownDevices.first(where: { $0.uid == uid })?.lastVolume
    }

    func setLastVolume(_ val: Float, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].lastVolume = val
    }

    func enforceVolumeLimit(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.enforceVolumeLimit ?? false
    }

    func setEnforceVolumeLimit(_ val: Bool, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].enforceVolumeLimit = val
    }

    func maxVolumeLimit(for uid: String) -> Float {
        knownDevices.first(where: { $0.uid == uid })?.maxVolumeLimit ?? 1.0
    }

    func setMaxVolumeLimit(_ val: Float, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].maxVolumeLimit = val
    }

    func triggerAECBypass(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.triggerAECBypass ?? false
    }

    func setTriggerAECBypass(_ val: Bool, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].triggerAECBypass = val
    }

    func backgroundAudioDucking(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.backgroundAudioDucking ?? false
    }

    func setBackgroundAudioDucking(_ val: Bool, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].backgroundAudioDucking = val
    }

    func monoSumming(for uid: String) -> Bool {
        knownDevices.first(where: { $0.uid == uid })?.monoSumming ?? false
    }

    func setMonoSumming(_ val: Bool, for uid: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.uid == uid }) else { return }
        knownDevices[idx].monoSumming = val
    }

    func forgetDevice(uid: String) {
        knownDevices.removeAll { $0.uid == uid }
    }
}
