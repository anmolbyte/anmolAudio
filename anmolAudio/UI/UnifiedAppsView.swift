import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UnifiedAppsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var excludedAppsStore: ExcludedAppsStore
    @ObservedObject var voipAppsStore: VoIPAppsStore
    @ObservedObject var appVolumeStore: AppVolumeStore

    @State private var runningApps: [AudioProcessInfo.App] = []
    @ObservedObject private var tracker = OpenedAppsTracker.shared
    @State private var processListListener: AudioProcessListChangeListener?
    @State private var filter: String = ""
    @State private var allRows: [Row] = []
    @State private var showCallModeHelp: Bool = false
    @FocusState private var filterFocused: Bool

    fileprivate struct Row: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isRunning: Bool
    }

    private var filteredRows: [Row] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allRows }
        return allRows.filter { row in
            row.displayName.localizedCaseInsensitiveContains(needle)
                || row.bundleID.localizedCaseInsensitiveContains(needle)
        }
    }

    private func rebuildRows() {
        var seen = Set<String>()
        var result: [Row] = []

        // 1. Core Audio specific entries (like System Sounds)
        for app in runningApps where app.bundleID == "systemsoundserverd" {
            seen.insert(app.bundleID)
            result.append(Row(
                bundleID: app.bundleID,
                displayName: app.displayName,
                isRunning: true
            ))
        }

        // 2. Every single GUI application that has been opened on this Mac (excluding uninstalled apps)
        for item in tracker.openedApps {
            guard !seen.contains(item.bundleID) else { continue }
            seen.insert(item.bundleID)
            result.append(Row(
                bundleID: item.bundleID,
                displayName: item.displayName,
                isRunning: item.isRunning
            ))
        }

        // 3. Any additional previously configured apps that are still installed
        let orphans = excludedAppsStore.excludedBundleIDs
            .union(voipAppsStore.voipBundleIDs)
            .union(appVolumeStore.volumes.keys)
            .subtracting(seen)
            .filter { bid in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            .map { bundleID in
                Row(
                    bundleID: bundleID,
                    displayName: AudioProcessInfo.displayName(forBundleID: bundleID),
                    isRunning: false
                )
            }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        result.append(contentsOf: orphans)

        allRows = result
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    // Call Handling Mode section
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("During Calls (FaceTime, Zoom)")
                                .font(.headline)

                            Button {
                                showCallModeHelp.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Explain call handling modes")
                            .popover(isPresented: $showCallModeHelp, arrowEdge: .bottom) {
                                callModeHelpPopover
                            }

                            Spacer()
                            Picker("", selection: $outputPreferences.callHandlingMode) {
                                ForEach(OutputSelectionPreferences.CallHandlingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        Text(outputPreferences.callHandlingMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // App Rules table
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Applications & Volumes")
                                .font(.headline)

                            Spacer()

                            TextField("Filter apps\u{2026}", text: $filter)
                                .textFieldStyle(.roundedBorder)
                                .focused($filterFocused)
                                .frame(width: 180)

                            Button {
                                addAppViaFilePicker()
                            } label: {
                                Label("Add App\u{2026}", systemImage: "plus")
                            }
                        }

                        // Table Header
                        HStack(spacing: 12) {
                            Text("Application")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Volume")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 155, alignment: .leading)
                            Text("Bypass EQ")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .center)
                                .help("This app's audio completely bypasses EQ and plays directly to macOS")
                            Text("Call Policy")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                                .help("Policy when this app is in an active audio/video call")
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                        // List
                        LazyVStack(spacing: 4) {
                            ForEach(filteredRows) { row in
                                AppRowView(
                                    row: row,
                                    isBypassed: excludedAppsStore.contains(row.bundleID),
                                    callPolicy: voipAppsStore.callPolicy(for: row.bundleID),
                                    volume: appVolumeStore.volume(for: row.bundleID),
                                    isMuted: appVolumeStore.isMuted(for: row.bundleID),
                                    onVolumeChange: { newVol in
                                        appVolumeStore.setVolume(newVol, for: row.bundleID)
                                    },
                                    onToggleMute: {
                                        appVolumeStore.toggleMute(for: row.bundleID)
                                    },
                                    onToggleBypass: {
                                        excludedAppsStore.toggle(row.bundleID)
                                    },
                                    onCallPolicyChange: { newPolicy in
                                        voipAppsStore.setCallPolicy(newPolicy, for: row.bundleID)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .task {
            refreshRunningApps()
            rebuildRows()
            processListListener = AudioProcessListChangeListener { [self] in
                Task { @MainActor in
                    self.refreshRunningApps()
                    self.rebuildRows()
                }
            }
        }
        .onReceive(tracker.$openedApps) { _ in
            rebuildRows()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bid = app.bundleIdentifier {
                tracker.recordAppOpened(bundleID: bid)
            }
            refreshRunningApps()
            rebuildRows()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApps()
            rebuildRows()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "phone.bubble.left")
                    .foregroundStyle(.secondary)
                Text("Calls: \(outputPreferences.callHandlingMode.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(filteredRows.count) app\(filteredRows.count == 1 ? "" : "s") detected • \(excludedAppsStore.excludedBundleIDs.count) bypassed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var callModeHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Call Handling Modes")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bypass call audio (Recommended)")
                        .font(.subheadline.bold())
                    Text("Routes communication apps (FaceTime, Zoom, Teams, Slack) directly to hardware, preserving Apple's native hardware echo cancellation, noise isolation, and volume. Any background music or system sounds keep your full EQ curves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Flatten EQ & keep Preamp")
                        .font(.subheadline.bold())
                    Text("Keeps all audio routed through anmolAudio, but temporarily disables frequency boosts/cuts during calls so voice audio sounds natural and doesn't trigger feedback. Retains the preamp level of your active preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause during calls")
                        .font(.subheadline.bold())
                    Text("Completely stops anmolAudio when your microphone is active. Audio restores automatically when your call ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func refreshRunningApps() {
        runningApps = AudioProcessInfo.runningAudioApps()
    }

    private func addAppViaFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Couldn't read bundle identifier"
            alert.informativeText = "\(url.lastPathComponent) doesn't look like a standard app bundle."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        tracker.recordAppOpened(bundleID: bundleID)
        if appVolumeStore.volumes[bundleID] == nil {
            appVolumeStore.setVolume(1.0, for: bundleID)
        }
        refreshRunningApps()
        rebuildRows()
    }
}

private struct AppRowView: View {
    let row: UnifiedAppsView.Row
    let isBypassed: Bool
    let callPolicy: AppCallPolicy
    let volume: Float
    let isMuted: Bool
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onToggleBypass: () -> Void
    let onCallPolicyChange: (AppCallPolicy) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AudioProcessInfo.icon(forBundleID: row.bundleID) ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 6) {
                    Text(row.bundleID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !row.isRunning {
                        Text("• not running")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            // Volume controls
            HStack(spacing: 5) {
                Button {
                    onToggleMute()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : (volume == 0 ? "speaker.fill" : "speaker.wave.2.fill"))
                        .foregroundStyle(isMuted ? .red : (isBypassed ? .secondary : .primary))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .disabled(isBypassed)
                .help(isMuted ? "Unmute app" : "Mute app")

                Slider(value: Binding(
                    get: { Double(volume) },
                    set: { onVolumeChange(Float($0)) }
                ), in: 0...1.5)
                .frame(width: 90)
                .disabled(isBypassed)

                Text(isBypassed ? "Bypassed" : (isMuted ? "Muted" : "\(Int(round(volume * 100)))%"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isMuted ? .red : .secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 155)

            Toggle("", isOn: Binding(
                get: { isBypassed },
                set: { _ in onToggleBypass() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 60, alignment: .center)

            Menu {
                ForEach(AppCallPolicy.allCases) { policy in
                    Button {
                        onCallPolicyChange(policy)
                    } label: {
                        HStack {
                            Label(policy.title, systemImage: policy.iconName)
                            if policy == callPolicy {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: callPolicy.iconName)
                        .font(.caption2)
                        .foregroundStyle(callPolicy == .none ? Color.secondary : Color.accentColor)
                    Text(callPolicy.shortTitle)
                        .font(.caption)
                        .lineLimit(1)
                }
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 120, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
