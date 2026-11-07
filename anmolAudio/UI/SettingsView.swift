import SwiftUI
import ServiceManagement
import OSLog

private let settingsLog = Logger(subsystem: "app.anmol.anmolAudio", category: "Settings")

struct SettingsView: View {
    @ObservedObject var syncSettings: PresetSyncSettings
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var excludedAppsStore: ExcludedAppsStore
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var burnInTracker: BurnInTracker
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var engine: EQEngine
    @ObservedObject var appVolumeStore: AppVolumeStore
    @ObservedObject var balanceLockManager: BalanceLockManager

    @AppStorage("disableTransparency") private var disableTransparency: Bool = false

    var body: some View {
        TabView {
            GeneralSettingsTab(
                outputPreferences: outputPreferences,
                burnInTracker: burnInTracker,
                deviceManager: deviceManager,
                engine: engine
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            DevicesSettingsView(
                outputPreferences: outputPreferences,
                deviceManager: deviceManager,
                devicePresetMemory: devicePresetMemory,
                presetStore: presetStore,
                presetCatalog: presetCatalog,
                engine: engine,
                balanceLockManager: balanceLockManager
            )
            .tabItem { Label("Devices", systemImage: "headphones") }

            UnifiedAppsView(
                outputPreferences: outputPreferences,
                excludedAppsStore: excludedAppsStore,
                voipAppsStore: VoIPAppsStore.shared,
                appVolumeStore: appVolumeStore
            )
            .tabItem { Label("Apps", systemImage: "square.stack.3d.up") }

            SyncSettingsTab(syncSettings: syncSettings, presetStore: presetStore)
            .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(
            minWidth: 720,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: defaultWindowHeight,
            maxHeight: screenMaxHeight
        )
        .background(disableTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .showsInDockWhileVisible()
    }

    private var screenMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 40
    }

    private var defaultWindowHeight: CGFloat {
        // Fits General tab cleanly with no scrollbar, while clamping on small screens
        min(675, max(460, screenMaxHeight))
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var burnInTracker: BurnInTracker
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var engine: EQEngine

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @AppStorage("startEngineOnLaunch") private var startEngineOnLaunch: Bool = true
    @AppStorage("disableTransparency") private var disableTransparency: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 15) {
                    Toggle("Start at login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .help("Register anmolAudio with Login Items so it launches when you sign in")
                        .onChange(of: launchAtLogin, initial: false) { _, newValue in
                            toggleLaunchAtLogin(newValue)
                        }

                    Divider()

                    Toggle("Start engine when anmolAudio launches", isOn: $startEngineOnLaunch)
                        .toggleStyle(.checkbox)
                        .help("Begin processing audio as soon as anmolAudio boots, instead of waiting for a manual start")

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("When devices change")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { outputPreferences.switchPolicy },
                                set: { outputPreferences.switchPolicy = $0 }
                            )) {
                                ForEach(OutputSelectionPreferences.SwitchPolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help("How anmolAudio reacts when an output device connects or the system default changes")
                        }
                        Text(outputPreferences.switchPolicy.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Auto-pause media on device change", isOn: $outputPreferences.autoPauseOnDeviceChange)
                            .toggleStyle(.checkbox)
                            .help("Automatically pauses media playback whenever the audio output destination changes or disconnects")
                        Text("Pauses media players (Spotify, Apple Music, YouTube in browsers) when headphones disconnect or audio switches, preventing audio from playing unexpectedly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Auto-mute on device change", isOn: $outputPreferences.autoMuteOnDeviceChange)
                            .toggleStyle(.checkbox)
                            .help("Mutes the new audio output device when the playback destination changes or disconnects")
                        Text("Prevents audio from accidentally blasting through MacBook speakers when headphones are unplugged or Bluetooth disconnects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Safe volume on connect (30% cap)", isOn: $outputPreferences.safeVolumeOnConnect)
                            .toggleStyle(.checkbox)
                            .help("Caps initial volume to a safe 30% level when audio devices or headphones connect")
                        Text("Protects hearing and sensitive IEMs from sudden ear-bleed volume blasts if headphones were left loud or Bluetooth reconnects at 100%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Pause music while on call", isOn: $outputPreferences.pauseMusicOnCall)
                                .toggleStyle(.checkbox)
                                .help("Automatically pauses media playback when an incoming or active call is detected")
                            Text("Pauses media players (Spotify, Apple Music, Safari/Chrome YouTube, etc.) during calls.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if outputPreferences.pauseMusicOnCall {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("", selection: $outputPreferences.callPauseBehavior) {
                                    ForEach(OutputSelectionPreferences.CallPauseBehavior.allCases) { behavior in
                                        Text(behavior.title).tag(behavior)
                                    }
                                }
                                .pickerStyle(.radioGroup)
                                .padding(.leading, 18)

                                Text(outputPreferences.callPauseBehavior.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 18)
                                    .fixedSize(horizontal: false, vertical: true)

                                Toggle("Resume music after call", isOn: $outputPreferences.resumeMusicAfterCall)
                                    .toggleStyle(.checkbox)
                                    .padding(.leading, 18)
                                    .help("Automatically resumes playback when the call ends, if music was playing before")
                                Text("Resumes playback once you hang up, provided music was playing before the call.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 18)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Disable transparency", isOn: $disableTransparency)
                            .toggleStyle(.checkbox)
                            .help("Use solid opaque backgrounds instead of blurred glass effects")
                        Text("Uses solid opaque backgrounds instead of translucent blur in the menu bar popover and editor overlays. Reduces GPU load and improves contrast.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    BurnInSection(tracker: burnInTracker, deviceManager: deviceManager)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .onAppear {
            // Re-sync in case the user toggled the login item from System Settings.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(engine.isRunning ? "Engine active (\(Int(engine.activeSampleRate ?? 48000)) Hz)" : "Engine stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("anmolAudio")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settingsLog.error("Launch-at-login toggle failed: \(String(describing: error))")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Sync

private struct SyncSettingsTab: View {
    @ObservedObject var syncSettings: PresetSyncSettings
    @ObservedObject var presetStore: PresetStore

    @State private var iCloudAvailable: Bool = PresetStore.iCloudIsAvailable()
    @State private var showMigratePrompt: Bool = false
    @State private var pendingToggleValue: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Preset sync").font(.title3.weight(.semibold))

                    Toggle("Sync presets via iCloud", isOn: Binding(
                        get: { syncSettings.iCloudEnabled },
                        set: { handleToggle(newValue: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!iCloudAvailable)

                    statusBlurb

                    Divider().padding(.vertical, 4)

                    Text("Current file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: presetStore.locationKind == .iCloud ? "icloud" : "internaldrive")
                            .foregroundStyle(.secondary)
                        Text(presetStore.fileURL.path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([presetStore.fileURL])
                        }
                        .font(.caption)
                    }

                    Text("Your current presets.json will be copied to your iCloud Drive container so it syncs to your other Macs. anmolAudio on other devices will pick up changes automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .confirmationDialog(
            "Copy presets to iCloud Drive?",
            isPresented: $showMigratePrompt,
            titleVisibility: .visible
        ) {
            Button("Keep both (copy local to iCloud)") {
                applyICloudToggle(enabled: pendingToggleValue, migrateLocal: true)
            }
            Button("Use iCloud version only") {
                applyICloudToggle(enabled: pendingToggleValue, migrateLocal: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Presets will sync between your Macs signed in with the same Apple Account. Pick whether to copy your current local presets to iCloud Drive or start fresh with what's in iCloud.")
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: syncSettings.iCloudEnabled ? "icloud.fill" : "internaldrive")
                    .foregroundStyle(.secondary)
                Text(syncSettings.iCloudEnabled ? "iCloud Drive Sync Active" : "Local Storage Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(presetStore.presets.count) preset\(presetStore.presets.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusBlurb: some View {
        if !iCloudAvailable {
            Text("iCloud Drive isn't available on this Mac. Sign in to iCloud and turn on iCloud Drive in System Settings to sync presets between Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if syncSettings.iCloudEnabled {
            Text("Presets are syncing via iCloud Drive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Presets are stored locally on this Mac. Turn on to sync them between Macs via your personal iCloud Drive container.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handleToggle(newValue: Bool) {
        pendingToggleValue = newValue
        if newValue {
            showMigratePrompt = true
        } else {
            applyICloudToggle(enabled: false, migrateLocal: false)
        }
    }

    private func applyICloudToggle(enabled: Bool, migrateLocal: Bool) {
        syncSettings.iCloudEnabled = enabled
        presetStore.setSyncEnabled(enabled, migrate: migrateLocal)
    }
}

// MARK: - Burn-in

private struct BurnInSection: View {
    @ObservedObject var tracker: BurnInTracker
    @ObservedObject var deviceManager: DeviceManager

    @State private var showBurnInHelp: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Burn-in hours").font(.callout.weight(.semibold))
                Button {
                    showBurnInHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What is burn-in?")
                .popover(isPresented: $showBurnInHelp, arrowEdge: .top) {
                    burnInHelp
                }
            }

            let entries = tracker.entries()
            if entries.isEmpty {
                Text("anmolAudio will tally engine runtime per output once you start it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries, id: \.uid) { entry in
                        HStack {
                            Text(entry.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if entry.uid == tracker.activeDeviceUID {
                                Text("active")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Text(formatDuration(entry.seconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours == 0 && minutes == 0 {
            return "< 1 min"
        }
        if hours == 0 {
            return "\(minutes) min"
        }
        return "\(hours)h \(minutes)m"
    }

    private var burnInHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Burn-in tracking").font(.headline)
            Text("How many hours of audio anmolAudio has actually played through each output device \u{2014} paused or silent time doesn\u{2019}t count. It\u{2019}s just a tally \u{2014} anmolAudio doesn\u{2019}t change anything about how it processes audio based on this number.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The name is a nod to the audiophile tradition of \u{201C}burning in\u{201D} new headphones by playing audio through them for tens or hundreds of hours, in the belief that the diaphragms loosen up and the sound improves. The evidence is contested at best; anmolAudio takes no position.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
    }
}
