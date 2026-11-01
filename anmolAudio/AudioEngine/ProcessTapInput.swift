import Foundation
import AudioToolbox
import CoreAudio
import Accelerate
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "ProcessTapInput")

/// Captures system audio output via one or more Core Audio Process Taps (macOS 14.2+)
/// wrapped in a private aggregate device. We read samples by attaching an `AudioDeviceIOProc`
/// directly to the aggregate — *not* via a HAL Output AU with input enabled. That
/// distinction matters: an aggregate read through a HAL AU input is still treated as
/// microphone capture and trips the orange privacy indicator, while a direct IOProc on
/// a tap-backed aggregate is not.
///
/// Multi-Tap Per-App Volume Architecture:
///   - All applications at 100% volume / unmuted (neutral) are bundled into a single Core Audio
///     mixdown tap (Tap 0) for zero-overhead, bit-perfect capture.
///   - Any application with a custom volume slider or mute state receives a dedicated
///     tap in the aggregate. In the single real-time IOProc callback, each app's buffer is scaled
///     in-place with smooth gain ramping and summed into the EQ pipeline.
///
/// Lifetime:
///   prepare() → creates tap(s) + aggregate → returns `(deviceID, sampleRate)`
///   start()   → installs IOProc on the aggregate and starts the device
///   stop()    → stops device, destroys IOProc, destroys aggregate, destroys taps
final class ProcessTapInput {
    typealias FrameHandler = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    /// Aggregate device ID after `prepare()`. Zero before prepare / after stop.
    private(set) var deviceID: AudioDeviceID = 0

    /// The process objects the live tap was built around. A tap's target list
    /// is fixed at creation time, so `EQEngine` diffs this against the current
    /// system process list to notice apps that started producing audio after
    /// the tap was created and rebuild for them.
    private(set) var tappedProcessObjects: Set<AudioObjectID> = []

    private var tapIDs: [AudioObjectID] = []
    private var procID: AudioDeviceIOProcID?

    /// Real-time tap slot state read/written lock-free on Apple Silicon by the audio thread.
    private struct RTAppSlot {
        var targetGain: Float
        var currentGain: Float
        var isMuted: Bool
        var isNeutral: Bool
        var rampCoefficient: Float
        var peakLevel: Float
    }

    /// When false, the audio thread skips peak amplitude calculations entirely (0% overhead).
    /// Enabled only when the menu bar popover or UI meter view is active.
    var isMeteringActive: Bool = false

    private let maxSlots = 64
    private let rtSlots: UnsafeMutablePointer<RTAppSlot>
    private var slotCount: Int = 0
    private var slotBundleIDs: [String?] = []

    /// Index of the first buffer that belongs to the tap in the aggregate's input
    /// AudioBufferList. The list is laid out as
    ///   [main sub-device input streams…] + [tap streams…]
    /// so an output device that also has inputs (any audio interface) contributes
    /// its own line/mic streams first. Those must be skipped.
    private var tapBufferStartIndex: Int = 0
    private var frameHandler: FrameHandler?

    /// Per-channel scratch used to deinterleave and mix tap buffers for the
    /// EQ processor (which expects two separate Float32 channel buffers). Sized for worst-case bursts.
    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames: Int = 32_768

    init() {
        leftScratch = .allocate(capacity: scratchCapacityFrames)
        rightScratch = .allocate(capacity: scratchCapacityFrames)
        leftScratch.initialize(repeating: 0, count: scratchCapacityFrames)
        rightScratch.initialize(repeating: 0, count: scratchCapacityFrames)

        rtSlots = .allocate(capacity: maxSlots)
        rtSlots.initialize(repeating: RTAppSlot(targetGain: 1, currentGain: 1, isMuted: false, isNeutral: true, rampCoefficient: 0, peakLevel: 0), count: maxSlots)
    }

    deinit {
        try? stop()
        leftScratch.deinitialize(count: scratchCapacityFrames)
        rightScratch.deinitialize(count: scratchCapacityFrames)
        leftScratch.deallocate()
        rightScratch.deallocate()

        rtSlots.deinitialize(count: maxSlots)
        rtSlots.deallocate()
    }

    // MARK: - Lifecycle

    /// Creates the process taps and a private aggregate device that wraps them. Returns the
    /// aggregate device ID and its nominal sample rate (which follows the tap).
    ///
    /// `excludedBundleIDs`: Apps that completely bypass anmolAudio (e.g. Call App or DAW).
    /// `appVolumes`: Per-app volume and mute settings. Apps with non-neutral volume receive
    /// dedicated taps with real-time gain multipliers.
    func prepare(
        excludedBundleIDs: Set<String> = [],
        appVolumes: [String: AppVolume] = [:]
    ) throws -> (deviceID: AudioDeviceID, sampleRate: Double) {
        // Remember previous taps and aggregate so we can destroy them AFTER
        // the new taps are created and active. Overlapping taps ensure Core Audio
        // never un-mutes the apps to the DAC, preventing un-attenuated volume blasts.
        let oldTapIDs = self.tapIDs
        let oldDeviceID = self.deviceID
        try stopIOProc()

        // 1. Look up our own audio process object so we can exclude ourselves from the
        //    tap targets — otherwise HALOutput's playback to the DAC would loop back
        //    into the tap.
        let ownProcessObject = try AudioProcessInfo.processObject(for: getpid())

        // 2. Enumerate every audio process the system knows about.
        let allProcesses = (try? AudioProcessInfo.allProcessObjects()) ?? []
        var excludedCount = 0
        let validProcesses = allProcesses.filter { obj in
            if obj == ownProcessObject { return false }
            if !excludedBundleIDs.isEmpty,
               let bundleID = AudioProcessInfo.bundleID(for: obj),
               excludedBundleIDs.contains(bundleID) {
                excludedCount += 1
                return false
            }
            return true
        }

        guard !validProcesses.isEmpty else {
            throw CoreAudioError.noProcessesToTap
        }

        // 3. Separate processes into custom-volume apps vs neutral apps.
        var processesByBundleID: [String: [AudioObjectID]] = [:]
        var unbundledProcesses: [AudioObjectID] = []

        for obj in validProcesses {
            if let bid = AudioProcessInfo.bundleID(for: obj) {
                processesByBundleID[bid, default: []].append(obj)
            } else {
                unbundledProcesses.append(obj)
            }
        }

        // Dedicated taps for each detected GUI app so each app has its own isolated peak meter
        // and can have its gain adjusted dynamically without rebuilding the tap.
        var customBundleIDs = Array(processesByBundleID.keys).sorted()
        if customBundleIDs.count >= maxSlots {
            customBundleIDs = Array(customBundleIDs.prefix(maxSlots - 1))
        }

        // Neutral processes: unbundled daemons + any apps beyond maxSlots
        var neutralProcesses: [AudioObjectID] = unbundledProcesses
        for (bid, procs) in processesByBundleID {
            if !customBundleIDs.contains(bid) {
                neutralProcesses.append(contentsOf: procs)
            }
        }

        log.info("Tap targets: valid=\(validProcesses.count) neutral=\(neutralProcesses.count) customApps=\(customBundleIDs.count) excludedByUser=\(excludedCount)")

        var newTapIDs: [AudioObjectID] = []
        var tapListEntries: [[String: Any]] = []
        var newSlotBundleIDs: [String?] = []
        var initialTargetGains: [Float] = []
        var initialIsMuted: [Bool] = []
        var initialIsNeutral: [Bool] = []

        // Tap 0: Neutral processes (if any exist)
        if !neutralProcesses.isEmpty {
            let tapUUID = UUID()
            let desc = CATapDescription(stereoMixdownOfProcesses: neutralProcesses)
            desc.uuid = tapUUID
            desc.name = "anmolAudio System Tap (Main)"
            desc.muteBehavior = .mutedWhenTapped
            desc.isPrivate = true
            desc.isExclusive = false
            desc.isMixdown = true
            desc.isMono = false

            var newTapID: AudioObjectID = 0
            let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
            if tapStatus != noErr {
                throw CoreAudioError.osStatus(tapStatus, "AudioHardwareCreateProcessTap (main)")
            }
            newTapIDs.append(newTapID)
            tapListEntries.append([
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: tapUUID.uuidString
            ])
            newSlotBundleIDs.append(nil)
            initialTargetGains.append(1.0)
            initialIsMuted.append(false)
            initialIsNeutral.append(true)
        }

        // Taps 1..N: Dedicated taps for custom-volume apps
        for bid in customBundleIDs {
            guard let procs = processesByBundleID[bid], !procs.isEmpty else { continue }
            guard newTapIDs.count < maxSlots else {
                log.warning("Max tap slots (\(self.maxSlots)) reached; remaining apps stay in main tap")
                break
            }
            let vol = appVolumes[bid] ?? AppVolume()
            let tapUUID = UUID()
            let desc = CATapDescription(stereoMixdownOfProcesses: procs)
            desc.uuid = tapUUID
            desc.name = "anmolAudio Tap (\(bid))"
            desc.muteBehavior = .mutedWhenTapped
            desc.isPrivate = true
            desc.isExclusive = false
            desc.isMixdown = true
            desc.isMono = false

            var newTapID: AudioObjectID = 0
            let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
            if tapStatus != noErr {
                for t in newTapIDs { AudioHardwareDestroyProcessTap(t) }
                throw CoreAudioError.osStatus(tapStatus, "AudioHardwareCreateProcessTap (\(bid))")
            }
            newTapIDs.append(newTapID)
            tapListEntries.append([
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: tapUUID.uuidString
            ])
            newSlotBundleIDs.append(bid)
            let gain = vol.isMuted ? 0.0 : VolumeTaper.gain(position: vol.volume)
            initialTargetGains.append(gain)
            initialIsMuted.append(vol.isMuted)
            initialIsNeutral.append(vol.isNeutral)
        }

        guard !newTapIDs.isEmpty else {
            throw CoreAudioError.noProcessesToTap
        }

        // 4. Build the aggregate device wrapping all taps.
        let mainSubDevice = try Self.systemDefaultOutput()
        let mainSubDeviceUID = mainSubDevice.uid
        let aggregateUID = "app.anmol.anmolAudio.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "anmolAudio System Tap (private)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: mainSubDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: mainSubDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: tapListEntries
        ]

        var newAggregateID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        if aggStatus != noErr {
            for t in newTapIDs { AudioHardwareDestroyProcessTap(t) }
            for t in oldTapIDs { AudioHardwareDestroyProcessTap(t) }
            if oldDeviceID != 0 { AudioHardwareDestroyAggregateDevice(oldDeviceID) }
            self.tapIDs.removeAll()
            self.deviceID = 0
            throw CoreAudioError.osStatus(aggStatus, "AudioHardwareCreateAggregateDevice")
        }

        let sampleRate = try CoreAudioSampleRate.nominal(for: newAggregateID)
        // 30 ms exponential gain smoothing coefficient
        let rampCoeff = 1.0 - exp(-1.0 / (Float(sampleRate) * 0.030))

        self.slotCount = newTapIDs.count
        self.slotBundleIDs = newSlotBundleIDs
        for i in 0..<newTapIDs.count {
            rtSlots[i] = RTAppSlot(
                targetGain: initialTargetGains[i],
                currentGain: initialTargetGains[i],
                isMuted: initialIsMuted[i],
                isNeutral: initialIsNeutral[i],
                rampCoefficient: rampCoeff,
                peakLevel: 0.0
            )
        }

        self.tapIDs = newTapIDs
        self.deviceID = newAggregateID
        self.tappedProcessObjects = Set(validProcesses)
        self.tapBufferStartIndex = Self.inputBufferCount(of: mainSubDevice.id)

        // Seamless handoff: teardown previous taps & aggregate now that the new taps are active.
        if oldDeviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(oldDeviceID)
            if status != noErr {
                log.warning("AudioHardwareDestroyAggregateDevice(\(oldDeviceID)) returned \(status)")
            }
        }
        for t in oldTapIDs {
            let status = AudioHardwareDestroyProcessTap(t)
            if status != noErr {
                log.warning("AudioHardwareDestroyProcessTap(\(t)) returned \(status)")
            }
        }

        log.info("Process tap aggregate ready: \(newTapIDs.count) tap(s), aggregateID=\(newAggregateID), rate=\(sampleRate)")
        return (newAggregateID, sampleRate)
    }

    /// Dynamically update the live gain for a currently tapped application without restarting the engine.
    /// Threading: Called from the main actor. Modifies atomic variables read by the real-time audio thread.
    func setLiveGain(bundleID: String, gain: Float, isMuted: Bool) {
        for i in 0..<slotCount {
            if slotBundleIDs[i] == bundleID {
                rtSlots[i].targetGain = max(0.0, min(2.0, gain))
                rtSlots[i].isMuted = isMuted
                break
            }
        }
    }

    /// Read the latest smoothed peak level for an app (0.0 to 1.0+).
    /// Returns 0.0 if metering is inactive or the app is silent.
    func peakLevel(for bundleID: String) -> Float {
        guard isMeteringActive else { return 0.0 }
        for i in 0..<slotCount {
            if slotBundleIDs[i] == bundleID {
                return rtSlots[i].peakLevel
            }
        }
        // Fallback to slot 0 if slot 0 is the aggregate main tap
        if slotCount > 0 && slotBundleIDs[0] == nil {
            return rtSlots[0].peakLevel
        }
        return 0.0
    }

    /// Installs an IOProc on the aggregate device and starts it. The IOProc forwards
    /// tap-captured stereo audio to `frameHandler` on the audio thread.
    func start(frameHandler: @escaping FrameHandler) throws {
        guard deviceID != 0 else {
            throw CoreAudioError.osStatus(-1, "ProcessTapInput.start called before prepare")
        }
        try stopIOProc()

        self.frameHandler = frameHandler

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            deviceID,
            nil
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inputData: inInputData)
        }
        if createStatus != noErr {
            throw CoreAudioError.osStatus(createStatus, "AudioDeviceCreateIOProcIDWithBlock")
        }
        guard let procID = newProcID else {
            throw CoreAudioError.osStatus(-1, "IOProc ID nil")
        }
        self.procID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        if startStatus != noErr {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            throw CoreAudioError.osStatus(startStatus, "AudioDeviceStart (aggregate)")
        }

        log.info("ProcessTapInput IOProc started on aggregate \(self.deviceID)")
    }

    func stop() throws {
        try stopIOProc()
        try teardownTapAndAggregate()
    }

    private func stopIOProc() throws {
        if let procID, deviceID != 0 {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        frameHandler = nil
    }

    private func teardownTapAndAggregate() throws {
        tappedProcessObjects = []
        tapBufferStartIndex = 0
        slotCount = 0
        slotBundleIDs = []
        if deviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            if status != noErr {
                log.warning("AudioHardwareDestroyAggregateDevice(\(self.deviceID)) returned \(status)")
            }
            deviceID = 0
        }
        for tapID in tapIDs {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                log.warning("AudioHardwareDestroyProcessTap(\(tapID)) returned \(status)")
            }
        }
        tapIDs.removeAll()
    }

    // MARK: - Audio thread (Real-time path: lock-free, zero-allocation)

    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        guard let handler = frameHandler else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard abl.count > 0 else { return }

        let start = tapBufferStartIndex
        guard start < abl.count else { return }
        let count = min(abl.count - start, slotCount)
        guard count > 0 else { return }

        // Compute frame count from the first tap buffer
        let firstBuf = abl[start]
        let channels = Int(firstBuf.mNumberChannels)
        let totalFloats = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
        let frames = channels > 0 ? totalFloats / channels : 0
        guard frames > 0, frames <= scratchCapacityFrames else { return }

        // Clear scratch buffers with SIMD zeroing
        vDSP_vclr(leftScratch, 1, vDSP_Length(frames))
        vDSP_vclr(rightScratch, 1, vDSP_Length(frames))

        let l = leftScratch
        let r = rightScratch
        let isMetering = isMeteringActive

        // Sum each tap buffer into scratch with smooth gain ramping
        for s in 0..<count {
            let buffer = abl[start + s]
            guard let raw = buffer.mData else { continue }
            let interleaved = raw.assumingMemoryBound(to: Float.self)
            let bChannels = Int(buffer.mNumberChannels)
            guard bChannels >= 1 else { continue }

            let slotPtr = rtSlots.advanced(by: s)
            let isMuted = slotPtr.pointee.isMuted
            let targetGain: Float = isMuted ? 0.0 : slotPtr.pointee.targetGain
            var currentGain = slotPtr.pointee.currentGain
            let ramp = slotPtr.pointee.rampCoefficient

            // Compute peak amplitude if UI metering is currently active (0% overhead when closed)
            if isMetering {
                var rawPeak: Float = 0.0
                let sampleCount = vDSP_Length(frames * bChannels)
                vDSP_maxmgv(interleaved, 1, &rawPeak, sampleCount)
                let prev = slotPtr.pointee.peakLevel
                if rawPeak >= prev {
                    slotPtr.pointee.peakLevel = rawPeak
                } else {
                    slotPtr.pointee.peakLevel = prev * 0.82 // ~250ms decay
                }
            }

            // Fast path for muted or zero-gain taps
            if targetGain == 0.0 && currentGain == 0.0 {
                continue
            }

            // Fast path for steady-state unity gain
            if slotPtr.pointee.isNeutral && abs(targetGain - 1.0) < 1e-4 && abs(currentGain - 1.0) < 1e-4 {
                if bChannels >= 2 {
                    for i in 0..<frames {
                        l[i] += interleaved[i * bChannels]
                        r[i] += interleaved[i * bChannels + 1]
                    }
                } else {
                    for i in 0..<frames {
                        let mono = interleaved[i]
                        l[i] += mono
                        r[i] += mono
                    }
                }
                continue
            }

            // Ramped gain path for customized volume apps
            if bChannels >= 2 {
                for i in 0..<frames {
                    currentGain += ramp * (targetGain - currentGain)
                    l[i] += interleaved[i * bChannels] * currentGain
                    r[i] += interleaved[i * bChannels + 1] * currentGain
                }
            } else {
                for i in 0..<frames {
                    currentGain += ramp * (targetGain - currentGain)
                    let mono = interleaved[i] * currentGain
                    l[i] += mono
                    r[i] += mono
                }
            }

            if abs(targetGain - currentGain) < 1e-4 {
                currentGain = targetGain
            }
            slotPtr.pointee.currentGain = currentGain
        }

        handler(l, r, frames)
    }

    // MARK: - Core Audio object helpers

    /// How many *input* buffers a device contributes when used as an aggregate
    /// sub-device. Zero for a plain output device (speakers, DAC, monitor).
    private static func inputBufferCount(of deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.count
    }

    private static func systemDefaultOutput() throws -> (id: AudioDeviceID, uid: String) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s1 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        if s1 != noErr {
            throw CoreAudioError.osStatus(s1, "default output device")
        }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let s2 = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &cfRef)
        if s2 != noErr {
            throw CoreAudioError.osStatus(s2, "default output UID")
        }
        guard let cf = cfRef?.takeRetainedValue() else {
            throw CoreAudioError.osStatus(-1, "default output UID nil")
        }
        return (deviceID, cf as String)
    }
}
