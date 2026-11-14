import Foundation
import AVFoundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "InputMeter")

/// Ultra-lightweight, on-demand microphone audio meter for testing input levels and VU display.
/// Consumes 0% background CPU when stopped.
@MainActor
final class InputMeter: ObservableObject {
    @Published var level: Float = 0.0
    @Published var isPermissionDenied: Bool = false
    @Published var isRunning: Bool = false

    private var engine: AVAudioEngine?
    private var activeDeviceID: AudioDeviceID?

    func start(deviceID: AudioDeviceID? = nil) {
        stop()
        activeDeviceID = deviceID

        let status = AVAudioApplication.shared.recordPermission
        if status == .undetermined {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startEngine()
                    } else {
                        self?.isPermissionDenied = true
                    }
                }
            }
            return
        } else if status == .denied {
            isPermissionDenied = true
            return
        }
        isPermissionDenied = false
        startEngine()
    }

    private func startEngine() {
        guard !isRunning else { return }
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode

        if let devID = activeDeviceID, let au = inputNode.audioUnit {
            var dID = devID
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            log.info("Input format not valid for metering")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var peak: Float = 0.0
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for f in 0..<frameLength {
                    let val = abs(ptr[f])
                    if val > peak { peak = val }
                }
            }

            let normalized = min(1.0, peak)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.level = self.level * 0.35 + normalized * 0.65
            }
        }

        do {
            try eng.start()
            self.engine = eng
            self.isRunning = true
        } catch {
            log.error("Failed to start InputMeter AVAudioEngine: \(String(describing: error))")
        }
    }

    func stop() {
        guard isRunning || engine != nil else { return }
        isRunning = false
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        level = 0.0
    }

    deinit {
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
    }
}
