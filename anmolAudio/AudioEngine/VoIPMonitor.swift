import CoreAudio
import Foundation
import AppKit
import Combine
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "VoIPMonitor")

final class VoIPMonitor: ObservableObject {
    @Published var isInputActive: Bool = false
    @Published var activeMicBundleIDs: Set<String> = []
    var onActiveMicChange: ((Set<String>) -> Void)?

    private let queue = DispatchQueue(label: "app.anmol.VoIPMonitor", qos: .utility)
    private var lastSeenMicTime: [String: Date] = [:]
    private let micHangoverSeconds: TimeInterval = 2.5
    private var isEngineRunning = false
    private var pendingPollItem: DispatchWorkItem?
    private var runningVoIPApps: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var inputDeviceListenerBlocks: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        setupWorkspaceObservers()
        setupCoreAudioListeners()
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        teardownCoreAudioListeners()
    }

    // MARK: - Workspace Observers (VoIP Apps)

    private func setupWorkspaceObservers() {
        // Cache running VoIP apps once at startup, then keep updated via push notifications
        // instead of polling NSWorkspace.shared.runningApplications every 2 seconds via Mach IPC.
        let voipSet = MainActor.assumeIsolated { VoIPAppsStore.shared.voipBundleIDs }
        var initialVoIPApps = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, voipSet.contains(bid) {
                initialVoIPApps.insert(bid)
            }
        }
        let initialSet = initialVoIPApps
        queue.async {
            self.runningVoIPApps = initialSet
        }

        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            let isVoIP = MainActor.assumeIsolated { VoIPAppsStore.shared.voipBundleIDs.contains(bid) }
            if isVoIP {
                self.queue.async {
                    self.runningVoIPApps.insert(bid)
                    self.checkStatus()
                }
            }
        }

        let termToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            self.queue.async {
                self.runningVoIPApps.remove(bid)
                self.checkStatus()
            }
        }

        workspaceObservers = [launchToken, termToken]
    }

    // MARK: - Core Audio Push Listeners (Zero Polling While Idle)

    private func setupCoreAudioListeners() {
        queue.async { [weak self] in
            guard let self else { return }
            self.rebindDeviceListeners()

            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async {
                    self?.rebindDeviceListeners()
                    self?.checkStatus()
                }
            }
            self.devicesListenerBlock = devBlock
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devAddr,
                self.queue,
                devBlock
            )

            var defInAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let defInBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.checkStatus() }
            }
            self.defaultInputListenerBlock = defInBlock
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defInAddr,
                self.queue,
                defInBlock
            )

            self.checkStatus()
        }
    }

    private func rebindDeviceListeners() {
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (devID, block) in inputDeviceListenerBlocks {
            AudioObjectRemovePropertyListenerBlock(devID, &runAddr, queue, block)
        }
        inputDeviceListenerBlocks.removeAll()

        let ins = CoreAudioDevices.all().filter { dev in
            dev.hasInput &&
            !dev.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
            !dev.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
            !dev.name.contains("System Tap")
        }
        for dev in ins {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.checkStatus() }
            }
            let status = AudioObjectAddPropertyListenerBlock(dev.id, &runAddr, queue, block)
            if status == noErr {
                inputDeviceListenerBlocks[dev.id] = block
            }
        }
    }

    private func teardownCoreAudioListeners() {
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (devID, block) in inputDeviceListenerBlocks {
            AudioObjectRemovePropertyListenerBlock(devID, &runAddr, queue, block)
        }
        inputDeviceListenerBlocks.removeAll()

        if let devBlock = devicesListenerBlock {
            var devAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, queue, devBlock)
            devicesListenerBlock = nil
        }
        if let defInBlock = defaultInputListenerBlock {
            var defInAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defInAddr, queue, defInBlock)
            defaultInputListenerBlock = nil
        }
    }

    // MARK: - Engine Running Gate

    /// Controls background monitoring. When audio engine is stopped, cancels any pending timers.
    func setEngineRunning(_ running: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEngineRunning = running
            if running {
                self.checkStatus()
            } else {
                self.pendingPollItem?.cancel()
                self.pendingPollItem = nil
                DispatchQueue.main.async {
                    self.isInputActive = false
                }
            }
        }
    }

    // MARK: - Status Checking

    private func checkStatus() {
        let ins = CoreAudioDevices.all().filter { dev in
            dev.hasInput &&
            !dev.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
            !dev.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
            !dev.name.contains("System Tap")
        }

        var currentlyActive = false

        for device in ins {
            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device.id, &isRunningAddress, 0, nil, &isRunningSize, &isRunning) == noErr {
                if isRunning != 0 {
                    currentlyActive = true
                    break
                }
            }
        }

        let now = Date()

        // FAST PATH: If no physical audio input device is running anywhere in macOS,
        // no application can be recording audio. Skip the heavy Mach IPC loop completely!
        if currentlyActive {
            if let procs = try? AudioProcessInfo.allProcessObjects() {
                let ownPID = getpid()
                let ownBundleID = Bundle.main.bundleIdentifier ?? "app.anmol.anmolAudio"
                for proc in procs {
                    // Critical: Ignore anmolAudio itself. anmolAudio has an active Core Audio
                    // process tap, which coreaudiod flags as running input. Never attribute our own
                    // tap input as an external microphone user!
                    if let pid = AudioProcessInfo.pid(for: proc), pid == ownPID { continue }

                    var isInputAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyIsRunningInput,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var isRunningInput: UInt32 = 0
                    var s = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(proc, &isInputAddr, 0, nil, &s, &isRunningInput) == noErr, isRunningInput != 0 {
                        if let bid = AudioProcessInfo.bundleID(for: proc),
                           !bid.isEmpty,
                           bid != ownBundleID,
                           bid != "app.anmol.anmolAudio" {
                            lastSeenMicTime[bid] = now
                        }
                    }
                }
            }
        }

        // Apply 2.5s hangover so brief pauses or mute toggles do not thrash tap rebuilds
        lastSeenMicTime = lastSeenMicTime.filter { _, lastSeen in
            now.timeIntervalSince(lastSeen) < micHangoverSeconds
        }
        let activeMicSet = Set(lastSeenMicTime.keys)
        let hasRunningVoIPApps = !runningVoIPApps.isEmpty

        // Read and update state exclusively on the main queue without blocking the utility queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let voipSet = MainActor.assumeIsolated { VoIPAppsStore.shared.voipBundleIDs }
            let isVoIPActiveInAudio = !activeMicSet.intersection(voipSet).isEmpty || !activeMicSet.isEmpty
            let isVoIPAppRunning = isVoIPActiveInAudio || hasRunningVoIPApps
            let shouldBypass = (currentlyActive && isVoIPAppRunning) || isVoIPActiveInAudio

            if self.activeMicBundleIDs != activeMicSet {
                self.activeMicBundleIDs = activeMicSet
                self.onActiveMicChange?(activeMicSet)
            }
            if shouldBypass && !self.isInputActive {
                log.info("VoIP Monitor: Input active and VoIP app running. Suspending.")
                self.isInputActive = true
            } else if !shouldBypass && self.isInputActive {
                log.info("VoIP Monitor: Input inactive or VoIP app closed. Resuming.")
                self.isInputActive = false
            }
        }

        // Schedule next poll ONLY if input is currently active or hangover has not yet drained.
        // When completely idle, we stop polling entirely — Core Audio push listeners will wake us
        // in 0 ms the instant an input device begins running.
        pendingPollItem?.cancel()
        pendingPollItem = nil

        if currentlyActive || !lastSeenMicTime.isEmpty {
            let item = DispatchWorkItem { [weak self] in
                self?.checkStatus()
            }
            self.pendingPollItem = item
            queue.asyncAfter(deadline: .now() + 2.5, execute: item)
        }
    }
}
