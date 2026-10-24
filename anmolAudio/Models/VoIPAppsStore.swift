import Foundation
import Combine
import AppKit

@MainActor
final class VoIPAppsStore: ObservableObject {
    private static let defaultsKey = "anmolAudio.voipBundleIDs"
    private static let legacyDefaultsKey = "lurar.voipBundleIDs"

    @Published private(set) var voipBundleIDs: Set<String>
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
    }

    func contains(_ bundleID: String) -> Bool {
        voipBundleIDs.contains(bundleID)
    }

    func set(_ bundleID: String, enabled: Bool) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasEnabled = voipBundleIDs.contains(trimmed)
        if enabled == wasEnabled { return }
        if enabled {
            voipBundleIDs.insert(trimmed)
        } else {
            voipBundleIDs.remove(trimmed)
        }
        persist()
        onChange?()
    }

    func toggle(_ bundleID: String) {
        set(bundleID, enabled: !voipBundleIDs.contains(bundleID))
    }

    private func persist() {
        UserDefaults.standard.set(Array(voipBundleIDs).sorted(), forKey: Self.defaultsKey)
    }
}
