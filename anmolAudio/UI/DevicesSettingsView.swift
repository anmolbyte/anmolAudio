import SwiftUI

struct DevicesSettingsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var inputPreferences: InputSelectionPreferences
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var engine: EQEngine
    @ObservedObject var balanceLockManager: BalanceLockManager

    @Environment(\.openWindow) private var openWindow
    @State private var expandedDeviceUID: String? = nil
    @State private var expandedInputDeviceUID: String? = nil
    @State private var deviceToForget: OutputSelectionPreferences.KnownDeviceRecord? = nil
    @State private var inputDeviceToForget: InputSelectionPreferences.KnownInputDeviceRecord? = nil
    @State private var testingInputDeviceUID: String? = nil
    @StateObject private var drawerMeter = InputMeter()

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
                                    .frame(width: 50, alignment: .center)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 4)

                            VStack(spacing: 8) {
                                ForEach(outputPreferences.knownDevices) { record in
                                    let isExpanded = (expandedDeviceUID == record.uid)
                                    VStack(spacing: 0) {
                                        deviceRow(for: record, isExpanded: isExpanded)

                                        if isExpanded {
                                            Divider()

                                            deviceConfigDrawer(for: record)
                                        }
                                    }
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isExpanded ? Color(nsColor: .separatorColor).opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Divider()

                    // Audio Inputs
                    audioInputsSection
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .onDisappear {
            drawerMeter.stop()
        }
        .alert(
            "Forget Device?",
            isPresented: Binding(
                get: { deviceToForget != nil },
                set: { if !$0 { deviceToForget = nil } }
            ),
            presenting: deviceToForget
        ) { dev in
            Button("Cancel", role: .cancel) {
                deviceToForget = nil
            }
            Button("Forget Device", role: .destructive) {
                if expandedDeviceUID == dev.uid {
                    expandedDeviceUID = nil
                }
                outputPreferences.forgetDevice(uid: dev.uid)
                deviceToForget = nil
            }
        } message: { dev in
            Text("Are you sure you want to forget “\(dev.name)”? All custom configuration, volume levels, and preset associations for this device will be removed.")
        }
        .alert(
            "Forget Input Device?",
            isPresented: Binding(
                get: { inputDeviceToForget != nil },
                set: { if !$0 { inputDeviceToForget = nil } }
            ),
            presenting: inputDeviceToForget
        ) { dev in
            Button("Cancel", role: .cancel) {
                inputDeviceToForget = nil
            }
            Button("Forget Device", role: .destructive) {
                if expandedInputDeviceUID == dev.uid {
                    expandedInputDeviceUID = nil
                    drawerMeter.stop()
                }
                inputPreferences.forgetDevice(uid: dev.uid)
                inputDeviceToForget = nil
            }
        } message: { dev in
            Text("Are you sure you want to forget “\(dev.name)”? All custom configuration, volume levels, and settings for this input will be removed.")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Text(deviceManager.selectedOutput.map { "Output: \($0.name)" } ?? "No output selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("•")
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                Text(deviceManager.selectedInput.map { "Input: \($0.name)" } ?? "No input selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(outputPreferences.knownDevices.count) out, \(inputPreferences.knownDevices.count) in")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func deviceRow(for record: OutputSelectionPreferences.KnownDeviceRecord, isExpanded: Bool) -> some View {
        let isConnected = deviceManager.outputDevices.contains(where: { $0.uid == record.uid })
        let isCurrentlySelected = deviceManager.selectedOutput?.uid == record.uid
        let effectivePolicy = outputPreferences.policy(for: record.uid) ?? record.policy

        HStack(spacing: 12) {
            Image(systemName: record.transportType.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isCurrentlySelected ? Color.accentColor : Color.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(record.name)

                    if isCurrentlySelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                            .fixedSize()
                            .layoutPriority(1)
                    } else if isConnected {
                        Text("Connected")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }

                Text(record.transportType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

            Button {
                expandedDeviceUID = (isExpanded ? nil : record.uid)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isExpanded ? Color.secondary.opacity(0.15) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Close settings for \(record.name)" : "Configure \(record.name)")
            .frame(width: 50, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contextMenu {
            if record.transportType != .builtIn && !isCurrentlySelected {
                Button(role: .destructive) {
                    deviceToForget = record
                } label: {
                    Label("Forget Device", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func deviceConfigDrawer(for record: OutputSelectionPreferences.KnownDeviceRecord) -> some View {
        let isCurrentlySelected = deviceManager.selectedOutput?.uid == record.uid

        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                // Left Column: Calls & Ducking + Volume & Hearing Safety
                VStack(alignment: .leading, spacing: 14) {
                    // Calls & Ducking
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Calls & Ducking")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Toggle("AEC Ducking", isOn: Binding(
                            get: { outputPreferences.aecDucking(for: record.uid) },
                            set: {
                                outputPreferences.setAECDucking($0, for: record.uid)
                                engine.handleCallAudioStateChanged()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("When enabled, call audio passes through EQ tap. When disabled, bypasses directly to DAC to prevent echo cancellation ducking.")

                        Toggle("Enable EQ during calls", isOn: Binding(
                            get: { outputPreferences.enableEQDuringCalls(for: record.uid) },
                            set: {
                                outputPreferences.setEnableEQDuringCalls($0, for: record.uid)
                                engine.updateProcessingConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Applies parametric EQ filter bands to incoming call audio.")

                        Toggle("Enable preamp during calls", isOn: Binding(
                            get: { outputPreferences.enablePreampDuringCalls(for: record.uid) },
                            set: {
                                outputPreferences.setEnablePreampDuringCalls($0, for: record.uid)
                                engine.updateProcessingConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Preserves the preset's preamp attenuation during calls to prevent sudden volume blasts.")

                        Toggle("Background audio ducking", isOn: Binding(
                            get: { outputPreferences.backgroundAudioDucking(for: record.uid) },
                            set: { outputPreferences.setBackgroundAudioDucking($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("macOS dims background apps by -12 dB when your microphone is open.")
                    }

                    Divider()

                    // Volume & Hearing Safety
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Volume & Hearing Safety")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Toggle("Remember volume for this device", isOn: Binding(
                            get: { outputPreferences.rememberVolume(for: record.uid) },
                            set: { outputPreferences.setRememberVolume($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help(outputPreferences.lastVolume(for: record.uid).map { "Last saved volume: \(Int(round($0 * 100)))%" } ?? "Restores output volume level independently for this device.")

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Safe volume on connect", isOn: Binding(
                                get: { outputPreferences.safeVolumeOnConnect(for: record.uid) },
                                set: { outputPreferences.setSafeVolumeOnConnect($0, for: record.uid) }
                            ))
                            .toggleStyle(.checkbox)
                            .help("Caps initial volume when connecting to protect hearing and IEMs.")

                            if outputPreferences.safeVolumeOnConnect(for: record.uid) {
                                HStack(spacing: 8) {
                                    Text("Cap")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Slider(
                                        value: Binding(
                                            get: { Double(outputPreferences.safeVolumeLevel(for: record.uid)) },
                                            set: { outputPreferences.setSafeVolumeLevel(Float($0), for: record.uid) }
                                        ),
                                        in: 0.05...1.0,
                                        step: 0.05
                                    )
                                    HStack(spacing: 1) {
                                        TextField(
                                            "",
                                            value: Binding(
                                                get: { Int(round(outputPreferences.safeVolumeLevel(for: record.uid) * 100)) },
                                                set: { newVal in
                                                    let clamped = max(1, min(100, newVal))
                                                    outputPreferences.setSafeVolumeLevel(Float(clamped) / 100.0, for: record.uid)
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
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))

                                        Text("%")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 18)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Enforce maximum volume limit", isOn: Binding(
                                get: { outputPreferences.enforceVolumeLimit(for: record.uid) },
                                set: { outputPreferences.setEnforceVolumeLimit($0, for: record.uid) }
                            ))
                            .toggleStyle(.checkbox)
                            .help("Prevents volume from exceeding this ceiling limit.")

                            if outputPreferences.enforceVolumeLimit(for: record.uid) {
                                let maxLimit = outputPreferences.maxVolumeLimit(for: record.uid)
                                HStack(spacing: 8) {
                                    Text("Ceiling")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Slider(
                                        value: Binding(
                                            get: { Double(outputPreferences.maxVolumeLimit(for: record.uid)) },
                                            set: { outputPreferences.setMaxVolumeLimit(Float($0), for: record.uid) }
                                        ),
                                        in: 0.15...1.0,
                                        step: 0.05
                                    )
                                    Text("\(Int(round(maxLimit * 100)))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 38, alignment: .trailing)
                                }
                                .padding(.leading, 18)
                            }
                        }

                        Toggle("Mute on sample rate change", isOn: Binding(
                            get: { outputPreferences.muteOnRateChange(for: record.uid) },
                            set: { outputPreferences.setMuteOnRateChange($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Briefly fades audio for ~300 ms when DAC sample rate switches to prevent digital clicks.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right Column: Channel Routing & Balance + Headphone Crossfeed
                VStack(alignment: .leading, spacing: 14) {
                    // Channel Routing & Balance
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Channel Routing & Balance")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

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
                        .help("Sums left and right channels into dual mono for single-earbud listening or checking phase.")

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
                        .help("Inverts left and right channels for reverse-wired cables or swapped speaker setups.")

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
                        .help("Detects macOS volume balance drift and keeps hardware balance locked at center.")

                        // Stereo Balance / Pan Slider
                        VStack(alignment: .leading, spacing: 3) {
                            let currentPan = outputPreferences.pan(for: record.uid)
                            HStack {
                                Text("Balance")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.tertiary)

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
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Divider()

                    // Bauer Headphone Crossfeed
                    VStack(alignment: .leading, spacing: 8) {
                        let isCrossfeedOn = outputPreferences.isCrossfeedEnabled(for: record.uid)
                        Text("Headphone Crossfeed")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Toggle("Enable Crossfeed (Bauer BS2B)", isOn: Binding(
                            get: { outputPreferences.isCrossfeedEnabled(for: record.uid) },
                            set: {
                                outputPreferences.setIsCrossfeedEnabled($0, for: record.uid)
                                if engine.activeOutput?.uid == record.uid {
                                    engine.updateChannelRouting()
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Blends low-frequency spatial cues between channels to reduce headphone listening fatigue.")

                        if isCrossfeedOn {
                            HStack(spacing: 8) {
                                Text("Strength")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

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

                                HStack(spacing: 1) {
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
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                    Text("%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if record.transportType != .builtIn {
                Divider()

                HStack {
                    Spacer()

                    Button(role: .destructive) {
                        deviceToForget = record
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Forget Device")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(isCurrentlySelected)
                    .help(isCurrentlySelected ? "Cannot forget the currently active output device" : "Remove \(record.name) and all saved preferences")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                    return NSColor(white: 0.16, alpha: 1.0)
                } else {
                    return NSColor(white: 0.93, alpha: 1.0)
                }
            }))
        )
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

    // MARK: - Audio Inputs Section

    private var audioInputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Inputs")
                    .font(.headline)
                Spacer()
                Text("\(inputPreferences.knownDevices.count) known")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if inputPreferences.knownDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No input devices recorded yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 12) {
                    Text("Input Device")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Behavior")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text("Config")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .center)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)

                VStack(spacing: 8) {
                    ForEach(inputPreferences.knownDevices) { record in
                        let isExpanded = (expandedInputDeviceUID == record.uid)
                        VStack(spacing: 0) {
                            inputDeviceRow(for: record, isExpanded: isExpanded)

                            if isExpanded {
                                Divider()
                                inputDeviceConfigDrawer(for: record)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isExpanded ? Color(nsColor: .separatorColor).opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func inputDeviceRow(for record: InputSelectionPreferences.KnownInputDeviceRecord, isExpanded: Bool) -> some View {
        let isConnected = deviceManager.inputDevices.contains(where: { $0.uid == record.uid })
        let isCurrentlySelected = deviceManager.selectedInput?.uid == record.uid
        let isLidClosedCutoff = deviceManager.isLidClosed && (record.transportType == .builtIn || record.uid == "BuiltInMicrophoneDevice")
        let effectivePolicy = inputPreferences.policy(for: record.uid) ?? record.policy

        HStack(spacing: 12) {
            Image(systemName: record.transportType == .builtIn ? "laptopcomputer" : (record.transportType == .usb ? "mic.fill" : record.transportType.systemImage))
                .font(.system(size: 18))
                .foregroundStyle(isCurrentlySelected ? Color.accentColor : Color.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(record.name)

                    if isCurrentlySelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                            .fixedSize()
                            .layoutPriority(1)
                    } else if isLidClosedCutoff {
                        Text("Lid closed")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                            .fixedSize()
                            .layoutPriority(1)
                    } else if isConnected {
                        Text("Connected")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }

                Text(record.transportType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Auto-switch Policy Picker
            Picker("", selection: Binding(
                get: { effectivePolicy },
                set: { newPolicy in
                    inputPreferences.setPolicy(newPolicy, for: record.uid)
                    deviceManager.refresh(initial: false)
                }
            )) {
                ForEach(InputSelectionPreferences.DevicePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)

            Button {
                if isExpanded {
                    expandedInputDeviceUID = nil
                    drawerMeter.stop()
                    testingInputDeviceUID = nil
                } else {
                    expandedInputDeviceUID = record.uid
                    drawerMeter.stop()
                    testingInputDeviceUID = nil
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isExpanded ? Color.secondary.opacity(0.15) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Close settings for \(record.name)" : "Configure \(record.name)")
            .frame(width: 50, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contextMenu {
            if record.transportType != .builtIn && !isCurrentlySelected {
                Button(role: .destructive) {
                    inputDeviceToForget = record
                } label: {
                    Label("Forget Device", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func inputDeviceConfigDrawer(for record: InputSelectionPreferences.KnownInputDeviceRecord) -> some View {
        let activeDevice = deviceManager.inputDevices.first(where: { $0.uid == record.uid })

        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                // Left Column: Gain, Volume Memory, Ceiling & Sample Rate
                VStack(alignment: .leading, spacing: 14) {
                    // Gain & Volume Memory
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gain & Volume")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        let currentGain = activeDevice.flatMap { CoreAudioInputVolume.scalar(for: $0.id) }
                            ?? inputPreferences.lastVolume(for: record.uid)
                            ?? 1.0

                        HStack(spacing: 8) {
                            Text("Gain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(currentGain) },
                                    set: { newVal in
                                        let clamped = Float(newVal)
                                        if let dev = activeDevice {
                                            CoreAudioInputVolume.setScalar(clamped, for: dev.id)
                                        }
                                        inputPreferences.setLastVolume(clamped, for: record.uid)
                                    }
                                ),
                                in: 0.0...1.0
                            )
                            .frame(maxWidth: .infinity)
                            Text("\(Int(round(currentGain * 100)))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }

                        Toggle("Remember input volume for this device", isOn: Binding(
                            get: { inputPreferences.rememberVolume(for: record.uid) },
                            set: { inputPreferences.setRememberVolume($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Restores hardware input volume automatically when this microphone connects.")
                    }

                    Divider()

                    // Peak Clipping Ceiling
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Peak Clipping Ceiling")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Enforce", isOn: Binding(
                                get: { inputPreferences.enforceVolumeLimit(for: record.uid) },
                                set: { inputPreferences.setEnforceVolumeLimit($0, for: record.uid) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }

                        let isEnforced = inputPreferences.enforceVolumeLimit(for: record.uid)
                        let maxLimit = inputPreferences.maxVolumeLimit(for: record.uid)

                        HStack(spacing: 8) {
                            Text("Ceiling")
                                .font(.caption)
                                .foregroundStyle(isEnforced ? .primary : .secondary)
                                .frame(width: 44, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(maxLimit) },
                                    set: { inputPreferences.setMaxVolumeLimit(Float($0), for: record.uid) }
                                ),
                                in: 0.15...1.0,
                                step: 0.05
                            )
                            .frame(maxWidth: .infinity)
                            .disabled(!isEnforced)
                            Text("\(Int(round(maxLimit * 100)))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isEnforced ? .primary : .secondary)
                                .frame(width: 38, alignment: .trailing)
                        }

                        Text("Caps maximum input volume to protect against microphone distortion and peak clipping.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Hardware Sample Rate
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hardware Sample Rate")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        if let dev = activeDevice {
                            let currentRate = CoreAudioInputVolume.nominalSampleRate(for: dev.id) ?? 48000.0
                            let availableRates = CoreAudioInputVolume.availableSampleRates(for: dev.id)

                            if availableRates.count > 1 {
                                HStack(spacing: 8) {
                                    Text("Sample Rate")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { currentRate },
                                        set: { newRate in
                                            CoreAudioInputVolume.setNominalSampleRate(newRate, for: dev.id)
                                        }
                                    )) {
                                        ForEach(availableRates, id: \.self) { rate in
                                            Text(String(format: "%.0f Hz", rate)).tag(rate)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                }
                            } else {
                                Text("Format: \(Int(currentRate)) Hz (fixed)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Connect device to view sample rate.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right Column: Calls, Ducking, Mono Summing & Live Test Meter
                VStack(alignment: .leading, spacing: 14) {
                    // Calls & Ducking
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Calls & Ducking")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Toggle("Trigger AEC Call Bypass", isOn: Binding(
                            get: { inputPreferences.triggerAECBypass(for: record.uid) },
                            set: { inputPreferences.setTriggerAECBypass($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("When this microphone becomes active, triggers AEC surgical call bypass so echo cancellation is preserved.")

                        Toggle("Background audio ducking", isOn: Binding(
                            get: { inputPreferences.backgroundAudioDucking(for: record.uid) },
                            set: { inputPreferences.setBackgroundAudioDucking($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Ducks background music by -12 dB when this microphone stream is in use.")
                    }

                    Divider()

                    // Channel Routing
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Channel Routing")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Toggle("Mono summing (L+R)", isOn: Binding(
                            get: { inputPreferences.monoSumming(for: record.uid) },
                            set: { inputPreferences.setMonoSumming($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Downmixes single-channel or stereo mic inputs to mono so audio is heard in both ears across all apps.")
                    }

                    Divider()

                    // Live Test Level Meter
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Live Test Level Meter")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if testingInputDeviceUID == record.uid {
                                    testingInputDeviceUID = nil
                                    drawerMeter.stop()
                                } else {
                                    testingInputDeviceUID = record.uid
                                    if let dev = activeDevice {
                                        drawerMeter.start(deviceID: dev.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: testingInputDeviceUID == record.uid ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 9))
                                    Text(testingInputDeviceUID == record.uid ? "Stop" : "Test")
                                        .font(.caption2.weight(.medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help(testingInputDeviceUID == record.uid ? "Stop live microphone test" : "Test microphone level (captures input only while active)")
                        }

                        let isTesting = (testingInputDeviceUID == record.uid)
                        let displayLevel = isTesting ? drawerMeter.level : 0.0

                        HStack(spacing: 8) {
                            Image(systemName: isTesting ? "mic.fill" : "mic")
                                .font(.caption)
                                .foregroundStyle(displayLevel > 0.05 ? Color.accentColor : Color.secondary)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(
                                            displayLevel > 0.85
                                                ? Color.red
                                                : (displayLevel > 0.65 ? Color.orange : Color.green)
                                        )
                                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(displayLevel))))
                                        .animation(.linear(duration: 0.08), value: displayLevel)
                                }
                            }
                            .frame(height: 8)

                            Text("\(Int(round(displayLevel * 100)))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }

                        if drawerMeter.isPermissionDenied {
                            Text("Microphone permission denied. Enable in System Settings > Privacy & Security > Microphone.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Text(isTesting ? "Listening... Speak to test level." : "Click Test to measure input responsiveness without unsolicited privacy alerts.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                    return NSColor(white: 0.16, alpha: 1.0)
                } else {
                    return NSColor(white: 0.93, alpha: 1.0)
                }
            }))
        )
        .onDisappear {
            drawerMeter.stop()
            testingInputDeviceUID = nil
        }
    }
}
