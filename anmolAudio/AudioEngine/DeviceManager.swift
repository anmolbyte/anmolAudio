import Foundation
import Combine
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "DeviceManager")

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []

    @Published var selectedOutput: AudioDevice? {
        didSet {
            guard let newOutput = selectedOutput else { return }
            guard newOutput.uid != oldValue?.uid else { return }
            preferences.lastOutputUID = newOutput.uid
            syncSystemDefaultIfNeeded(to: newOutput)
        }
    }

    @Published private(set) var inputDevices: [AudioDevice] = []

    @Published var selectedInput: AudioDevice? {
        didSet {
            guard let newInput = selectedInput else { return }
            guard newInput.uid != oldValue?.uid else { return }
            syncSystemDefaultInputIfNeeded(to: newInput)
        }
    }

    @Published private(set) var isLidClosed: Bool = ClamshellMonitor.isLidClosed

    /// Called by EQEngine to react to device topology changes (re-bind / stop / restart).
    var onTopologyChange: (() -> Void)?

    private let preferences: OutputSelectionPreferences
    private var topologyListener: DeviceChangeListener?
    private var defaultOutputListener: DefaultOutputDeviceListener?
    private var defaultInputListener: DefaultInputDeviceListener?
    private var clamshellMonitor: ClamshellMonitor?
    private var pendingSyncDeviceID: AudioObjectID?
    private var pendingSyncTimestamp: Date = .distantPast
    private var pendingSyncInputDeviceID: AudioObjectID?
    private var pendingSyncInputTimestamp: Date = .distantPast
    /// UID snapshot of the last visible device list — used to decide
    /// whether a topology notification actually changed anything the user
    /// cares about, or whether it was just our private tap aggregate
    /// churning during an engine restart.
    private var lastVisibleUIDs: [String] = []

    init(preferences: OutputSelectionPreferences) {
        self.preferences = preferences
        refresh(initial: true)
        topologyListener = DeviceChangeListener { [weak self] in
            Task { @MainActor in self?.refresh(initial: false) }
        }
        defaultOutputListener = DefaultOutputDeviceListener { [weak self] in
            Task { @MainActor in self?.handleSystemDefaultChanged() }
        }
        defaultInputListener = DefaultInputDeviceListener { [weak self] in
            Task { @MainActor in self?.handleSystemDefaultInputChanged() }
        }
        clamshellMonitor = ClamshellMonitor { [weak self] isClosed in
            Task { @MainActor in self?.handleClamshellStateChanged(isClosed: isClosed) }
        }
    }

    func refresh(initial: Bool) {
        let all = CoreAudioDevices.all()
        // anmolAudio's own private aggregate (created in ProcessTapInput) is
        // visible to its creating process even with isPrivate=true. Hide it
        // from the picker — selecting it as the output would loop the tap
        // back through itself. Also filter out ignored devices (like displays).
        let outs = all
            .filter(\.hasOutput)
            .filter {
                !$0.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
                !$0.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
                !$0.name.contains("System Tap")
            }
            .filter { device in
                let policy = preferences.effectivePolicy(for: device)
                return policy != .ignored || device.uid == selectedOutput?.uid
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // Only record genuine physical/visible output devices, never private aggregates
        preferences.recordSeen(devices: outs)

        // Snapshot the previous visible set before overwriting it — used both
        // for the material-change gate and to spot devices that just appeared.
        let previousUIDs = lastVisibleUIDs
        let newUIDs = outs.map(\.uid)
        let addedUIDs = previousUIDs.isEmpty ? [] : Set(newUIDs).subtracting(previousUIDs)

        self.outputDevices = outs

        let ins = all
            .filter(\.hasInput)
            .filter {
                !$0.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
                !$0.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
                !$0.name.contains("System Tap")
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        self.inputDevices = ins
        self.isLidClosed = ClamshellMonitor.isLidClosed

        func isUsableInput(_ device: AudioDevice) -> Bool {
            if isLidClosed && (device.transportType == .builtIn || device.uid == "BuiltInMicrophoneDevice") {
                return false
            }
            return true
        }

        let usableIns = ins.filter(isUsableInput)
        let systemDefault = CoreAudioDevices.defaultInput()
            .flatMap { def in ins.first { $0.id == def.id || $0.uid == def.uid } }

        if let sel = selectedInput, let still = ins.first(where: { $0.uid == sel.uid }), isUsableInput(still) {
            selectedInput = still
        } else if let sysDef = systemDefault, isUsableInput(sysDef) {
            selectedInput = sysDef
        } else {
            selectedInput = usableIns.first ?? systemDefault ?? ins.first
        }

        // Opt-in auto-switch: when a brand-new output device connects — e.g. a
        // USB DAC that macOS detects but doesn't promote to system default —
        // move anmolAudio's output to it if the device policy allows auto-switching.
        let newlyConnected = (!initial && preferences.switchesToNewDevices)
            ? outs.first(where: { addedUIDs.contains($0.uid) && preferences.effectivePolicy(for: $0) == .auto })
            : nil

        // Output policy: jump to a just-connected device if auto-switch claimed
        // one; otherwise keep the current selection if it's still around;
        // otherwise restore the last-used UID; otherwise fall back to the
        // current system default (if allowed); otherwise the first valid device.
        if let newlyConnected {
            selectedOutput = newlyConnected
        } else if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let remembered = preferences.lastOutputUID
                .flatMap { uid in outs.first { $0.uid == uid && preferences.effectivePolicy(for: $0) != .ignored } }
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in outs.first { $0.id == def.id && preferences.effectivePolicy(for: $0) == .auto } }
            let firstValid = outs.first(where: { preferences.effectivePolicy(for: $0) != .ignored })
            let preferred: AudioDevice?
            if preferences.followsSystemDefault {
                preferred = systemDefault ?? remembered ?? firstValid ?? outs.first
            } else {
                preferred = remembered ?? systemDefault ?? firstValid ?? outs.first
            }
            selectedOutput = preferred
        }

        // Only nudge the engine if the visible device list materially
        // changed. The tap rebuild that follows e.g. an excluded-apps
        // toggle churns aggregate devices through the system topology;
        // those changes are filtered out of the picker but the raw
        // notification still fires here, and firing `onTopologyChange`
        // would force a redundant engine restart for something the user
        // can't see.
        let materialChange = newUIDs != previousUIDs
        lastVisibleUIDs = newUIDs

        log.info("Refresh — output=\(self.selectedOutput?.name ?? "nil") initial=\(initial) materialChange=\(materialChange) autoSwitched=\(newlyConnected != nil)")

        if !initial && materialChange { onTopologyChange?() }
    }

    private func syncSystemDefaultIfNeeded(to output: AudioDevice) {
        guard let currentDefault = CoreAudioDevices.defaultOutput(), currentDefault.id != output.id else { return }
        pendingSyncDeviceID = output.id
        pendingSyncTimestamp = Date()
        do {
            try CoreAudioDevices.setDefaultOutput(id: output.id)
            log.info("Synced macOS default output to \(output.name, privacy: .public)")
        } catch {
            pendingSyncDeviceID = nil
            log.error("Failed to sync macOS default output to \(output.name, privacy: .public): \(String(describing: error))")
        }
    }

    private func handleSystemDefaultChanged() {
        guard let newDefault = CoreAudioDevices.defaultOutput() else {
            log.info("System default changed — no default device available")
            return
        }
        if let pending = pendingSyncDeviceID {
            if pending == newDefault.id {
                pendingSyncDeviceID = nil
                log.info("Ignoring echo of our own default output sync to \(newDefault.name, privacy: .public)")
                return
            } else if Date().timeIntervalSince(pendingSyncTimestamp) < 1.5 {
                log.info("Ignoring intermediate system default \(newDefault.name, privacy: .public) while waiting for sync to target device ID \(pending)")
                return
            } else {
                pendingSyncDeviceID = nil
            }
        }
        // CoreAudio fires the default-change and device-list notifications
        // independently — if a brand-new device (AirPods) just became default
        // and the topology listener hasn't run yet, outputDevices is stale.
        // Refresh inline so the new device is in the picker before we set it.
        if !outputDevices.contains(where: { $0.id == newDefault.id || $0.uid == newDefault.uid }) {
            refresh(initial: false)
        }
        guard let resolved = outputDevices.first(where: { $0.uid == newDefault.uid })
            ?? outputDevices.first(where: { $0.id == newDefault.id }) else {
            log.info("System default changed to \(newDefault.name, privacy: .public) but it isn't in the visible output list")
            return
        }
        if resolved.uid == selectedOutput?.uid { return }

        // Guard against auto-switching to blocked or manual-only devices (such as docks or monitors)
        let effectivePolicy = preferences.effectivePolicy(for: resolved)
        guard effectivePolicy == .auto else {
            log.info("System default changed to \(resolved.name, privacy: .public), but device policy is \(effectivePolicy.rawValue) — staying on current output")
            return
        }

        if preferences.followsSystemDefault {
            log.info("System default changed → \(resolved.name, privacy: .public); following")
            selectedOutput = resolved
        } else {
            log.info("System default changed → \(resolved.name, privacy: .public); policy is stay — no action")
        }
    }

    private func syncSystemDefaultInputIfNeeded(to input: AudioDevice) {
        guard let currentDefault = CoreAudioDevices.defaultInput(), currentDefault.id != input.id else { return }
        pendingSyncInputDeviceID = input.id
        pendingSyncInputTimestamp = Date()
        do {
            try CoreAudioDevices.setDefaultInput(id: input.id)
            log.info("Synced macOS default input to \(input.name, privacy: .public)")
        } catch {
            pendingSyncInputDeviceID = nil
            log.error("Failed to sync macOS default input to \(input.name, privacy: .public): \(String(describing: error))")
        }
    }

    private func handleSystemDefaultInputChanged() {
        guard let newDefault = CoreAudioDevices.defaultInput() else {
            log.info("System default input changed — no default device available")
            return
        }
        if let pending = pendingSyncInputDeviceID {
            if pending == newDefault.id {
                pendingSyncInputDeviceID = nil
                log.info("Ignoring echo of our own default input sync to \(newDefault.name, privacy: .public)")
                return
            } else if Date().timeIntervalSince(pendingSyncInputTimestamp) < 1.5 {
                log.info("Ignoring intermediate system default input \(newDefault.name, privacy: .public) while waiting for sync to target device ID \(pending)")
                return
            } else {
                pendingSyncInputDeviceID = nil
            }
        }
        if !inputDevices.contains(where: { $0.id == newDefault.id || $0.uid == newDefault.uid }) {
            refresh(initial: false)
        }
        guard let resolved = inputDevices.first(where: { $0.uid == newDefault.uid })
            ?? inputDevices.first(where: { $0.id == newDefault.id }) else {
            log.info("System default input changed to \(newDefault.name, privacy: .public) but it isn't in the visible input list")
            return
        }
        if resolved.uid == selectedInput?.uid { return }

        // If lid is closed and macOS just switched or echoed default to the dead built-in mic:
        if isLidClosed && (resolved.transportType == .builtIn || resolved.uid == "BuiltInMicrophoneDevice") {
            if let activeExternal = selectedInput, activeExternal.transportType != .builtIn && activeExternal.uid != "BuiltInMicrophoneDevice" {
                log.info("macOS tried to default to built-in mic while lid is closed. Re-asserting \(activeExternal.name, privacy: .public)")
                syncSystemDefaultInputIfNeeded(to: activeExternal)
                return
            }
        }

        log.info("System default input changed → \(resolved.name, privacy: .public); updating selectedInput")
        selectedInput = resolved
    }

    private func handleClamshellStateChanged(isClosed: Bool) {
        log.info("Clamshell state changed: isLidClosed = \(isClosed)")
        self.isLidClosed = isClosed
        refresh(initial: false)
    }
}
