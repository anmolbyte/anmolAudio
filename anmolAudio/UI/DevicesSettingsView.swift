import SwiftUI

struct DevicesSettingsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var engine: EQEngine

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
                                    .frame(width: 32, alignment: .center)
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
                engine: engine
            )
            .frame(width: 32, alignment: .center)

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
        .help("Audio & call settings for \(record.name)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings: \(record.name)")
                    .font(.headline)

                // 1. Audio Processing (EQ & Preamp)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio Processing")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Enable EQ", isOn: Binding(
                            get: { outputPreferences.enableEQ(for: record.uid) },
                            set: {
                                outputPreferences.setEnableEQ($0, for: record.uid)
                                engine.updateProcessingConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)

                        Text("Applies parametric EQ filter bands from the selected preset. Enabled by default.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Enable Preamp", isOn: Binding(
                            get: { outputPreferences.enablePreamp(for: record.uid) },
                            set: {
                                outputPreferences.setEnablePreamp($0, for: record.uid)
                                engine.updateProcessingConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)

                        Text("Applies the preset's gain attenuation (prevents digital clipping). Enabled by default.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // 2. Call & Ducking Rules
                VStack(alignment: .leading, spacing: 10) {
                    Text("Calls & Ducking")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

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

                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Background Audio Ducking", isOn: Binding(
                            get: { outputPreferences.backgroundAudioDucking(for: record.uid) },
                            set: { outputPreferences.setBackgroundAudioDucking($0, for: record.uid) }
                        ))
                        .toggleStyle(.checkbox)

                        Text("macOS dims background apps (Spotify, YouTube) by -12 dB when your microphone is open. Uncheck to disable ducking.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(width: 330)
        }
    }
}
