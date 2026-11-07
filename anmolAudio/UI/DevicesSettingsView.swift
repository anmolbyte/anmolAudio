import SwiftUI

struct DevicesSettingsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var engine: EQEngine
    @ObservedObject var balanceLockManager: BalanceLockManager

    @Environment(\.openWindow) private var openWindow

    private var visiblePresetsList: [EQPreset] {
        anmolAudio.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    // Global display audio rule
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Ignore Display Audio (DisplayPort / HDMI)", isOn: $outputPreferences.ignoreDisplayAudio)
                            .toggleStyle(.checkbox)
                            .onChange(of: outputPreferences.ignoreDisplayAudio) { _, _ in
                                deviceManager.refresh(initial: false)
                            }
                        Text("Monitors and TVs are automatically blocked from auto-switching and hidden from the output picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Devices list
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Audio Outputs")
                                .font(.headline)
                            Spacer()
                            Text("\(outputPreferences.knownDevices.count) known")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if outputPreferences.knownDevices.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "speaker.slash")
                                    .font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                                Text("No devices recorded yet.")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            // Column headers
                            HStack(spacing: 12) {
                                Text("Output Device")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Preset")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 170, alignment: .leading)
                                Text("Behavior")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                Text("Config")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .center)
                                Color.clear
                                    .frame(width: 20, height: 1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 4)

                            VStack(spacing: 8) {
                                ForEach(outputPreferences.knownDevices) { record in
                                    deviceRow(for: record)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Text(deviceManager.selectedOutput.map { "Active: \($0.name)" } ?? "No output selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(outputPreferences.knownDevices.count) known device\(outputPreferences.knownDevices.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func deviceRow(for record: OutputSelectionPreferences.KnownDeviceRecord) -> some View {
        let isConnected = deviceManager.outputDevices.contains(where: { $0.uid == record.uid })
        let isCurrentlySelected = deviceManager.selectedOutput?.uid == record.uid
        let effectivePolicy = outputPreferences.policy(for: record.uid) ?? record.policy

        HStack(spacing: 12) {
            Image(systemName: record.transportType.systemImage)
                .font(.title2)
                .foregroundStyle(isCurrentlySelected ? Color.accentColor : Color.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .help(record.name)

                    if isCurrentlySelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    } else if isConnected {
                        Text("Connected")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                Text(record.transportType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            // Paired EQ Preset Dropdown with "Add preset…" action
            FixedWidthPopUp(
                width: 170,
                selection: Binding(
                    get: {
                        if let last = devicePresetMemory.lastPresetID(for: record.uid),
                           visiblePresetsList.contains(where: { $0.id == last }) {
                            return last.uuidString
                        }
                        if let flat = visiblePresetsList.first(where: { $0.id == EQPreset.flatID }) {
                            return flat.id.uuidString
                        }
                        return visiblePresetsList.first?.id.uuidString ?? ""
                    },
                    set: { newUUID in
                        if let id = UUID(uuidString: newUUID) {
                            devicePresetMemory.setLastPresetID(id, for: record.uid)
                            if isCurrentlySelected, let preset = visiblePresetsList.first(where: { $0.id == id }) {
                                engine.apply(preset: preset)
                            }
                        }
                    }
                ),
                items: anmolAudio.sortedPresetItems(
                    presets: visiblePresetsList,
                    catalog: presetCatalog,
                    store: presetStore
                ),
                actions: [
                    .init(id: "new", title: "Add preset\u{2026}")
                ],
                onAction: { actionID in
                    if actionID == "new" {
                        addNewPreset(for: record)
                    }
                }
            )

            // Auto-switch Policy Picker
            Picker("", selection: Binding(
                get: { effectivePolicy },
                set: { newPolicy in
                    outputPreferences.setPolicy(newPolicy, for: record.uid)
                    deviceManager.refresh(initial: false)
                }
            )) {
                ForEach(OutputSelectionPreferences.DevicePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)

            DeviceCallConfigButton(
                record: record,
                outputPreferences: outputPreferences,
                engine: engine,
                balanceLockManager: balanceLockManager
            )
            .frame(width: 44, alignment: .center)

            // Fixed-width slot for the forget/remove button to keep all rows and columns aligned
            Group {
                if record.transportType == .builtIn {
                    // Non-removable built-in hardware (MacBook speakers, internal jack) — blank space
                    Color.clear
                        .frame(width: 20, height: 20)
                } else if isCurrentlySelected || isConnected {
                    // Plugged-in external device — greyed out with tooltip
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .frame(width: 20, height: 20)
                        .help("Plugged in")
                } else {
                    // Disconnected device — clickable button to forget
                    Button {
                        outputPreferences.forgetDevice(uid: record.uid)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Forget \(record.name)")
                }
            }
            .frame(width: 20, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if !isCurrentlySelected {
                Button(role: .destructive) {
                    outputPreferences.forgetDevice(uid: record.uid)
                } label: {
                    Label("Forget Device", systemImage: "trash")
                }
            }
        }
    }

    private func addNewPreset(for record: OutputSelectionPreferences.KnownDeviceRecord) {
        let presetName = presetStore.uniqueName(based: "\(record.name) EQ")
        let preset = EQPreset.blank(name: presetName)
        presetStore.add(preset)
        devicePresetMemory.setLastPresetID(preset.id, for: record.uid)
        if deviceManager.selectedOutput?.uid == record.uid {
            engine.apply(preset: preset)
        }
        openWindow(id: "editor")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DeviceCallConfigButton: View {
    let record: OutputSelectionPreferences.KnownDeviceRecord
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var engine: EQEngine
    @ObservedObject var balanceLockManager: BalanceLockManager
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Configuration for \(record.name)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Device Settings: \(record.name)")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        // 1. Calls & Ducking
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Calls & Ducking")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            // 1a. AEC Ducking
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("AEC Ducking", isOn: Binding(
                                    get: { outputPreferences.aecDucking(for: record.uid) },
                                    set: {
                                        outputPreferences.setAECDucking($0, for: record.uid)
                                        engine.handleCallAudioStateChanged()
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text(outputPreferences.aecDucking(for: record.uid)
                                    ? "Enabled (in EQ) — Call audio passes through EQ tap. Safe on headphones where no acoustic feedback exists."
                                    : "Disabled (Bypass to DAC) — Call audio bypasses directly to hardware to prevent Apple's echo cancellation from ducking voice on speakers.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // 1b. Enable EQ During Calls
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Enable EQ During Calls", isOn: Binding(
                                    get: { outputPreferences.enableEQDuringCalls(for: record.uid) },
                                    set: {
                                        outputPreferences.setEnableEQDuringCalls($0, for: record.uid)
                                        engine.updateProcessingConfiguration()
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Applies parametric EQ filter bands to incoming call audio. Uncheck to run flat pass-through EQ during calls.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // 1c. Enable Preamp During Calls
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Enable Preamp During Calls", isOn: Binding(
                                    get: { outputPreferences.enablePreampDuringCalls(for: record.uid) },
                                    set: {
                                        outputPreferences.setEnablePreampDuringCalls($0, for: record.uid)
                                        engine.updateProcessingConfiguration()
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Preserves the preset's preamp attenuation during calls. Keep enabled on headphones to prevent loud sudden volume blasts.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // 1d. Background Audio Ducking
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Background Audio Ducking", isOn: Binding(
                                    get: { outputPreferences.backgroundAudioDucking(for: record.uid) },
                                    set: { outputPreferences.setBackgroundAudioDucking($0, for: record.uid) }
                                ))
                                .toggleStyle(.checkbox)

                                Text("macOS dims background apps (Spotify, YouTube) by -12 dB when your microphone is open. Uncheck to keep background music at full volume.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        // 2. Audio Hardware
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audio Hardware")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Mute on sample rate change", isOn: Binding(
                                    get: { outputPreferences.muteOnRateChange(for: record.uid) },
                                    set: { outputPreferences.setMuteOnRateChange($0, for: record.uid) }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Briefly fades audio for ~300 ms when the DAC switches sample rates (e.g. 44.1 kHz → 96 kHz) to prevent digital chirps. Uncheck if your DAC has hardware muting relays.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        // 3. Channel Routing & Balance
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Channel Routing & Balance")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            // Mono downmix
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Mono downmix", isOn: Binding(
                                    get: { outputPreferences.isMonoDownmix(for: record.uid) },
                                    set: {
                                        outputPreferences.setIsMonoDownmix($0, for: record.uid)
                                        if engine.activeOutput?.uid == record.uid {
                                            engine.updateChannelRouting()
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Sums left and right channels into dual mono for single-earbud listening or checking phase.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Swap stereo channels
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Swap stereo channels", isOn: Binding(
                                    get: { outputPreferences.isChannelSwap(for: record.uid) },
                                    set: {
                                        outputPreferences.setIsChannelSwap($0, for: record.uid)
                                        if engine.activeOutput?.uid == record.uid {
                                            engine.updateChannelRouting()
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Inverts left and right channels for reverse-wired headphone cables or swapped speaker setups.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Auto-lock balance to center
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Auto-lock balance to center", isOn: Binding(
                                    get: { outputPreferences.autoLockBalance(for: record.uid) },
                                    set: {
                                        outputPreferences.setAutoLockBalance($0, for: record.uid)
                                        if engine.activeOutput?.uid == record.uid {
                                            balanceLockManager.checkAndResetBalance()
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Automatically detects macOS Core Audio volume drift and keeps hardware balance locked at 50/50.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Stereo Balance / Pan Slider
                            VStack(alignment: .leading, spacing: 4) {
                                let currentPan = outputPreferences.pan(for: record.uid)
                                HStack {
                                    Text("Stereo Balance")
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    Text(panDescription(for: currentPan))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if abs(currentPan) > 0.001 {
                                        Button("Reset") {
                                            outputPreferences.setPan(0.0, for: record.uid)
                                            if engine.activeOutput?.uid == record.uid {
                                                engine.updateChannelRouting()
                                            }
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Text("L")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)

                                    Slider(
                                        value: Binding(
                                            get: { Double(outputPreferences.pan(for: record.uid)) },
                                            set: {
                                                outputPreferences.setPan(Float($0), for: record.uid)
                                                if engine.activeOutput?.uid == record.uid {
                                                    engine.updateChannelRouting()
                                                }
                                            }
                                        ),
                                        in: -1.0...1.0
                                    )

                                    Text("R")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }

                                Text("Adjusts stereo balance for this device with zero DSP overhead.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Bauer Headphone Crossfeed
                            VStack(alignment: .leading, spacing: 4) {
                                let isCrossfeedOn = outputPreferences.isCrossfeedEnabled(for: record.uid)
                                HStack {
                                    Toggle("Headphone Crossfeed (Bauer BS2B)", isOn: Binding(
                                        get: { outputPreferences.isCrossfeedEnabled(for: record.uid) },
                                        set: {
                                            outputPreferences.setIsCrossfeedEnabled($0, for: record.uid)
                                            if engine.activeOutput?.uid == record.uid {
                                                engine.updateChannelRouting()
                                            }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)

                                    Spacer()

                                    HStack(spacing: 2) {
                                        TextField(
                                            "",
                                            value: Binding(
                                                get: { Int(round(outputPreferences.crossfeedStrength(for: record.uid) * 100)) },
                                                set: { newVal in
                                                    let clamped = max(0, min(100, newVal))
                                                    outputPreferences.setCrossfeedStrength(Float(clamped) / 100.0, for: record.uid)
                                                    if engine.activeOutput?.uid == record.uid {
                                                        engine.updateChannelRouting()
                                                    }
                                                }
                                            ),
                                            format: .number
                                        )
                                        .textFieldStyle(.plain)
                                        .font(.caption.monospacedDigit())
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 32)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .disabled(!isCrossfeedOn)

                                        Text("%")
                                            .font(.caption2)
                                            .foregroundStyle(isCrossfeedOn ? .secondary : .tertiary)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Text("Subtle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)

                                    Slider(
                                        value: Binding(
                                            get: { Double(outputPreferences.crossfeedStrength(for: record.uid)) },
                                            set: {
                                                outputPreferences.setCrossfeedStrength(Float($0), for: record.uid)
                                                if engine.activeOutput?.uid == record.uid {
                                                    engine.updateChannelRouting()
                                                }
                                            }
                                        ),
                                        in: 0.0...1.0
                                    )
                                    .disabled(!isCrossfeedOn)

                                    Text("Strong")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .opacity(isCrossfeedOn ? 1.0 : 0.4)

                                Text("Blends low-frequency spatial cues between channels to reduce headphone listening fatigue and create a natural acoustic soundstage.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .opacity(outputPreferences.isCrossfeedEnabled(for: record.uid) ? 1.0 : 0.7)
                        }

                        Divider()

                        // 4. Volume & Hearing Safety
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Volume & Hearing Safety")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            // 4a. Remember volume
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Remember volume for this device", isOn: Binding(
                                    get: { outputPreferences.rememberVolume(for: record.uid) },
                                    set: { outputPreferences.setRememberVolume($0, for: record.uid) }
                                ))
                                .toggleStyle(.checkbox)

                                if let last = outputPreferences.lastVolume(for: record.uid) {
                                    Text("Restores output volume level for this device (last saved: \(Int(round(last * 100)))%).")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Restores output volume level independently for this device.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            // 4b. Safe volume on connect
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Safe volume on connect (30% cap)", isOn: Binding(
                                    get: { outputPreferences.safeVolumeOnConnect(for: record.uid) },
                                    set: { outputPreferences.setSafeVolumeOnConnect($0, for: record.uid) }
                                ))
                                .toggleStyle(.checkbox)

                                Text("Caps initial volume to 30% if louder on connect, preventing ear-bleed blasts when plugging in sensitive IEMs.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // 4c. Volume Limit Ceiling
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Enforce maximum volume limit", isOn: Binding(
                                    get: { outputPreferences.enforceVolumeLimit(for: record.uid) },
                                    set: { outputPreferences.setEnforceVolumeLimit($0, for: record.uid) }
                                ))
                                .toggleStyle(.checkbox)

                                if outputPreferences.enforceVolumeLimit(for: record.uid) {
                                    let maxLimit = outputPreferences.maxVolumeLimit(for: record.uid)
                                    HStack {
                                        Text("Volume Ceiling")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(round(maxLimit * 100)))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 18)

                                    Slider(
                                        value: Binding(
                                            get: { Double(outputPreferences.maxVolumeLimit(for: record.uid)) },
                                            set: { outputPreferences.setMaxVolumeLimit(Float($0), for: record.uid) }
                                        ),
                                        in: 0.15...1.0,
                                        step: 0.05
                                    )
                                    .padding(.leading, 18)

                                    Text("Volume keys and apps cannot push volume past this ceiling. Protects ears and IEM drivers.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 18)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 340)
            .frame(maxHeight: 520)
        }
    }

    private func panDescription(for pan: Float) -> String {
        let percent = Int(round(abs(pan) * 100))
        if percent == 0 {
            return "Center"
        } else if pan < 0 {
            return "\(percent)% Left"
        } else {
            return "\(percent)% Right"
        }
    }
}
