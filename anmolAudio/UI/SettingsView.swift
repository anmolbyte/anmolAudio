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
                engine: engine
            )
            .tabItem { Label("Devices", systemImage: "headphones") }

            UnifiedAppsView(
                outputPreferences: outputPreferences,
                excludedAppsStore: excludedAppsStore,
                voipAppsStore: VoIPAppsStore.shared
            )
            .tabItem { Label("Apps", systemImage: "square.stack.3d.up") }

            SyncSettingsTab(syncSettings: syncSettings, presetStore: presetStore)
            .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(
            minWidth: 640,
            idealWidth: 660,
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
    @AppStorage("suspendDuringVoIP") private var suspendDuringVoIP: Bool = true
    @AppStorage(EQEngine.followNewAudioAppsKey) private var followNewAudioApps: Bool = true
    @AppStorage(EQEngine.muteOnDeviceRateChangeKey) private var muteOnDeviceRateChange: Bool = true
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
                        Toggle("Bypass automatically during VoIP calls", isOn: $suspendDuringVoIP)
                            .toggleStyle(.checkbox)
                            .help("Suspends anmolAudio when your microphone is active to prevent FaceTime or Zoom from ducking your audio.")
                        Text("FaceTime and Zoom aggressively lower your output volume to prevent echoes when an aggregate audio device is active. Bypassing anmolAudio when the mic is active restores hardware echo cancellation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Capture apps that start after anmolAudio", isOn: $followNewAudioApps)
                            .toggleStyle(.checkbox)
                            .help("Rebuild the audio tap when an app that launched later starts playing, so its audio goes through anmolAudio too")
                        Text("macOS fixes the list of apps an audio tap covers at the moment the tap is created, so an app you open later plays around anmolAudio until the engine restarts. With this on, anmolAudio rebuilds the tap itself — silently when nothing is playing, and with a brief fade when something is. Turn it off if you'd rather never hear that interruption.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
                        Toggle("Mute briefly on output rate change", isOn: $muteOnDeviceRateChange)
                            .toggleStyle(.checkbox)
                            .help("Fade audio out for ~150 ms when the output device's sample rate changes, to mask the resampler transient")
                        Text("Apple Music and other hi-res sources can change your DAC's sample rate between tracks. Fading briefly hides the audible pitch glitch as Core Audio's internal sample-rate converter re-tunes. Turn this off if you'd rather hear the unmasked transition.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
