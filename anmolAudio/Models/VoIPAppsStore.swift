import Foundation
import Combine
import AppKit

/// Policy for how an application behaves during audio/video calls.
enum AppCallPolicy: String, Codable, CaseIterable, Identifiable {
    case inherit = "inherit"
    case alwaysBypass = "alwaysBypass"
    case alwaysEQ = "alwaysEQ"
    case none = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: return "Auto-Detect Call (Inherit Device Rule)"
        case .alwaysBypass: return "Always Treat as Call (Bypass to DAC)"
        case .alwaysEQ: return "Always Treat as Call (Apply EQ)"
        case .none: return "Never Treat as Call (Music / Media)"
        }
    }

    var shortTitle: String {
        switch self {
        case .inherit: return "Auto (Device)"
        case .alwaysBypass: return "Always Call (DAC)"
        case .alwaysEQ: return "Always Call (EQ)"
        case .none: return "Music / Media"
        }
    }

    var iconName: String {
        switch self {
        case .inherit: return "arrow.triangle.branch"
        case .alwaysBypass: return "arrow.up.forward.app"
        case .alwaysEQ: return "waveform"
        case .none: return "music.note"
        }
    }
}

@MainActor
final class VoIPAppsStore: ObservableObject {
    private static let defaultsKey = "anmolAudio.voipBundleIDs"
    private static let legacyDefaultsKey = "lurar.voipBundleIDs"
    private static let policiesDefaultsKey = "anmolAudio.appCallPolicies"

    @Published private(set) var voipBundleIDs: Set<String>
    @Published private(set) var appCallPolicies: [String: AppCallPolicy]
    var onChange: (() -> Void)?

    static let shared = VoIPAppsStore() // singleton for VoIPMonitor

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.defaultsKey)
            ?? UserDefaults.standard.stringArray(forKey: Self.legacyDefaultsKey)
            ?? [
                "com.apple.FaceTime",
                "com.apple.avconferenced",
                "com.apple.TelephonyUtilities",
                "com.apple.telephonyutilities.callservicesd",
                "us.zoom.xos",
                "com.microsoft.teams",
                "com.microsoft.teams2"
            ]
        var set = Set(raw)
        // Always ensure system call daemons and FaceTime are recognized
        set.insert("com.apple.FaceTime")
        set.insert("com.apple.avconferenced")
        set.insert("com.apple.TelephonyUtilities")
        set.insert("com.apple.telephonyutilities.callservicesd")
        self.voipBundleIDs = set

        if let data = UserDefaults.standard.data(forKey: Self.policiesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: AppCallPolicy].self, from: data) {
            self.appCallPolicies = decoded
        } else {
            var initial: [String: AppCallPolicy] = [:]
            for bid in set {
                initial[bid] = .inherit
            }
            self.appCallPolicies = initial
        }
    }

    func contains(_ bundleID: String) -> Bool {
        voipBundleIDs.contains(bundleID)
    }

    func callPolicy(for bundleID: String) -> AppCallPolicy {
        if let policy = appCallPolicies[bundleID] {
            return policy
        }
        return .inherit
    }

    func setCallPolicy(_ policy: AppCallPolicy, for bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appCallPolicies[trimmed] = policy
        if policy == .none {
            voipBundleIDs.remove(trimmed)
        } else {
            voipBundleIDs.insert(trimmed)
        }
        persist()
        onChange?()
    }

    func set(_ bundleID: String, enabled: Bool) {
        setCallPolicy(enabled ? .inherit : .none, for: bundleID)
    }

    func toggle(_ bundleID: String) {
        let current = callPolicy(for: bundleID)
        setCallPolicy(current == .none ? .inherit : .none, for: bundleID)
    }

    private func persist() {
        UserDefaults.standard.set(Array(voipBundleIDs).sorted(), forKey: Self.defaultsKey)
        if let data = try? JSONEncoder().encode(appCallPolicies) {
            UserDefaults.standard.set(data, forKey: Self.policiesDefaultsKey)
        }
    }
}
