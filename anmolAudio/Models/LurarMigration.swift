import Foundation
import OSLog

private let migrationLog = Logger(subsystem: "app.anmol.anmolAudio", category: "Migration")

/// Seamless one-time migration of user settings and data from Lurar (the upstream app)
/// to anmolAudio.
enum LurarMigration {
    private static let migrationFlagKey = "anmolAudio.hasMigratedFromLurar_v2"

    @MainActor
    static func migrateUserDefaultsIfNeeded() {
        let currentDefaults = UserDefaults.standard
        if currentDefaults.bool(forKey: migrationFlagKey) {
            return
        }

        guard let lurarDefaults = UserDefaults(suiteName: "app.lurar.Lurar") else {
            migrationLog.info("No legacy Lurar defaults suite found.")
            currentDefaults.set(true, forKey: migrationFlagKey)
            return
        }

        migrationLog.info("Migrating legacy Lurar preferences to anmolAudio...")

        // 1. Device preset mappings
        if let lurarPresets = lurarDefaults.dictionary(forKey: "lurar.lastPresetByDevice") as? [String: String] {
            var currentPresets = currentDefaults.dictionary(forKey: DevicePresetMemory.lastPresetKey) as? [String: String] ?? [:]
            for (k, v) in lurarPresets where currentPresets[k] == nil {
                currentPresets[k] = v
            }
            currentDefaults.set(currentPresets, forKey: DevicePresetMemory.lastPresetKey)
        }

        // 2. Dismissed suggestions
        if let lurarDismissed = lurarDefaults.stringArray(forKey: "lurar.suggestionsDismissedDevices") {
            var currentDismissed = Set(currentDefaults.stringArray(forKey: DevicePresetMemory.dismissedSuggestionsKey) ?? [])
            currentDismissed.formUnion(lurarDismissed)
            currentDefaults.set(Array(currentDismissed), forKey: DevicePresetMemory.dismissedSuggestionsKey)
        }

        // 3. Burn-in tracker
        if currentDefaults.data(forKey: BurnInTracker.defaultsKey) == nil,
           let burnInData = lurarDefaults.data(forKey: "lurar.burnInByDevice") {
            currentDefaults.set(burnInData, forKey: BurnInTracker.defaultsKey)
        }

        // 4. Excluded apps
        if currentDefaults.stringArray(forKey: "anmolAudio.excludedBundleIDs") == nil,
           let excluded = lurarDefaults.stringArray(forKey: "lurar.excludedBundleIDs") {
            currentDefaults.set(excluded, forKey: "anmolAudio.excludedBundleIDs")
        }

        // 5. Output selection preferences
        if currentDefaults.string(forKey: OutputSelectionPreferences.lastOutputUIDKey) == nil,
           let uid = lurarDefaults.string(forKey: "lurar.lastOutputDeviceUID") {
            currentDefaults.set(uid, forKey: OutputSelectionPreferences.lastOutputUIDKey)
        }
        if currentDefaults.string(forKey: OutputSelectionPreferences.switchPolicyKey) == nil,
           let policy = lurarDefaults.string(forKey: "lurar.outputSwitchPolicy") {
            currentDefaults.set(policy, forKey: OutputSelectionPreferences.switchPolicyKey)
        }
        if currentDefaults.string(forKey: OutputSelectionPreferences.legacyFollowModeKey) == nil,
           let follow = lurarDefaults.string(forKey: "lurar.followSystemDefaultMode") {
            currentDefaults.set(follow, forKey: OutputSelectionPreferences.legacyFollowModeKey)
        }

        // 6. iCloud sync setting
        if currentDefaults.object(forKey: PresetSyncSettings.defaultsKey) == nil,
           let syncVal = lurarDefaults.object(forKey: "lurar.presets.iCloudSyncEnabled") {
            currentDefaults.set(syncVal, forKey: PresetSyncSettings.defaultsKey)
        }

        // 7. Transparency and spectrum flags
        if currentDefaults.object(forKey: "disableTransparency") == nil,
           let dt = lurarDefaults.object(forKey: "disableTransparency") {
            currentDefaults.set(dt, forKey: "disableTransparency")
        }
        if currentDefaults.object(forKey: "spectrum.enabled") == nil,
           let se = lurarDefaults.object(forKey: "spectrum.enabled") {
            currentDefaults.set(se, forKey: "spectrum.enabled")
        }

        currentDefaults.set(true, forKey: migrationFlagKey)
        migrationLog.info("Lurar preference migration completed successfully.")
    }
}
