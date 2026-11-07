import CoreAudio
import Foundation
import AppKit
import Combine
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "VoIPMonitor")

final class VoIPMonitor: ObservableObject {
    @Published var isInputActive: Bool = false
    @Published var isRinging: Bool = false
    @Published var activeMicBundleIDs: Set<String> = []
    var onActiveMicChange: ((Set<String>) -> Void)?
    var onCallStateChange: ((_ isCallActive: Bool, _ isRinging: Bool) -> Void)?

    private let queue = DispatchQueue(label: "app.anmol.VoIPMonitor", qos: .utility)
    private var lastSeenMicTime: [String: Date] = [:]
    private let micHangoverSeconds: TimeInterval = 2.5
    private var isEngineRunning = false
    private var pendingPollItem: DispatchWorkItem?
    private var runningVoIPApps: Set<String> = []
    private var cachedVoIPBundleIDs: Set<String> = []
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
            self.cachedVoIPBundleIDs = voipSet
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

    // MARK: - VoIP Bundle IDs Update

    func updateVoIPBundleIDs(_ bundleIDs: Set<String>) {
        queue.async { [weak self] in
            self?.cachedVoIPBundleIDs = bundleIDs
        }
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

        let allDevs = CoreAudioDevices.all().filter { dev in
            (dev.hasInput || dev.hasOutput) &&
            !dev.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
            !dev.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
            !dev.name.contains("System Tap")
        }
        for dev in allDevs {
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

        let outs = CoreAudioDevices.all().filter { dev in
            dev.hasOutput &&
            !dev.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") &&
            !dev.uid.hasPrefix("app.lurar.Lurar.aggregate.") &&
            !dev.name.contains("System Tap")
        }
        var isOutputRunning = false
        for device in outs {
            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device.id, &isRunningAddress, 0, nil, &isRunningSize, &isRunning) == noErr {
                if isRunning != 0 {
                    isOutputRunning = true
                    break
                }
            }
        }

        let now = Date()
        var ringingVoIPApps: Set<String> = []

        if currentlyActive || isOutputRunning {
            if let procs = try? AudioProcessInfo.allProcessObjects() {
                let ownPID = getpid()
                let ownBundleID = Bundle.main.bundleIdentifier ?? "app.anmol.anmolAudio"
                let voipSet = self.cachedVoIPBundleIDs
                let dedicatedTelephonyRingingIDs: Set<String> = [
                    "com.apple.telephonyutilities.callservicesd",
                    "com.apple.TelephonyUtilities",
                    "com.apple.mobilephone",
                    "com.apple.FaceTime"
                ]
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
                    let hasInput = (AudioObjectGetPropertyData(proc, &isInputAddr, 0, nil, &s, &isRunningInput) == noErr && isRunningInput != 0)

                    if let bid = AudioProcessInfo.bundleID(for: proc),
                       !bid.isEmpty,
                       bid != ownBundleID,
                       bid != "app.anmol.anmolAudio" {
                        if hasInput {
                            lastSeenMicTime[bid] = now
                        } else if dedicatedTelephonyRingingIDs.contains(bid) && AudioProcessInfo.isRunningOutput(proc) {
                            ringingVoIPApps.insert(bid)
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
        let isRingingNow = !ringingVoIPApps.isEmpty

        // Read and update state exclusively on the main queue without blocking the utility queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let voipSet = MainActor.assumeIsolated { VoIPAppsStore.shared.voipBundleIDs }
            let isVoIPActiveInAudio = !activeMicSet.intersection(voipSet).isEmpty || !activeMicSet.isEmpty
            let isVoIPAppRunning = isVoIPActiveInAudio || hasRunningVoIPApps
            let shouldBypass = (currentlyActive && isVoIPAppRunning) || isVoIPActiveInAudio

            if self.isRinging != isRingingNow {
                self.isRinging = isRingingNow
                log.info("VoIP Monitor: Ringing state changed to \(isRingingNow) (apps: \(ringingVoIPApps.joined(separator: ", ")))")
            }

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
            self.onCallStateChange?(self.isInputActive, isRingingNow)
        }

        // Schedule next poll ONLY if input is currently active, hangover has not yet drained, or ringing.
        pendingPollItem?.cancel()
        pendingPollItem = nil

        if currentlyActive || isRingingNow || !lastSeenMicTime.isEmpty {
            let item = DispatchWorkItem { [weak self] in
                self?.checkStatus()
            }
            self.pendingPollItem = item
            queue.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }
}
