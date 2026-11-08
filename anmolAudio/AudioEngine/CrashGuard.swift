import Foundation
import CoreAudio
import OSLog
import AppKit

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "CrashGuard")

/// Protects the listener's hearing by immediately muting hardware volume
/// and/or pausing media playback if anmolAudio terminates unexpectedly.
public final class CrashGuard {
    public static let shared = CrashGuard()

    private var watchdogProcess: Process?
    private var writePipe: Pipe?
    private let queue = DispatchQueue(label: "app.anmol.anmolAudio.CrashGuardQueue")

    // State cached for fast signal handler access
    public static var muteOnCrashActive: Bool = false
    public static var pauseOnCrashActive: Bool = false

    private init() {
        installSignalHandlers()
    }

    /// Synchronizes the watchdog companion process with the user's General settings.
    public func syncWithPreferences(muteOnCrash: Bool, pauseOnCrash: Bool) {
        Self.muteOnCrashActive = muteOnCrash
        Self.pauseOnCrashActive = pauseOnCrash

        queue.async { [weak self] in
            guard let self else { return }
            if !muteOnCrash && !pauseOnCrash {
                self.terminateWatchdog()
            } else {
                self.spawnOrUpdateWatchdog(muteOnCrash: muteOnCrash, pauseOnCrash: pauseOnCrash)
            }
        }
    }

    /// Informs the watchdog that this is an intentional, planned shutdown so it exits quietly.
    public func signalCleanExit() {
        queue.sync {
            guard let pipe = writePipe else { return }
            var token = UInt8(ascii: "Q")
            try? pipe.fileHandleForWriting.write(contentsOf: Data([token]))
            try? pipe.fileHandleForWriting.close()
            writePipe = nil
            watchdogProcess = nil
            log.info("Signaled clean exit to crash guard watchdog")
        }
    }

    private func terminateWatchdog() {
        if let pipe = writePipe {
            var token = UInt8(ascii: "Q")
            try? pipe.fileHandleForWriting.write(contentsOf: Data([token]))
            try? pipe.fileHandleForWriting.close()
            writePipe = nil
        }
        if let proc = watchdogProcess, proc.isRunning {
            proc.terminate()
        }
        watchdogProcess = nil
        log.info("Crash guard watchdog stopped")
    }

    private func spawnOrUpdateWatchdog(muteOnCrash: Bool, pauseOnCrash: Bool) {
        terminateWatchdog()

        guard let executableURL = Bundle.main.executableURL else {
            log.error("Could not locate executable URL for crash guard")
            return
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        var args = [
            "--crash-guard",
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        if muteOnCrash { args.append("--mute") }
        if pauseOnCrash { args.append("--pause") }
        process.arguments = args
        process.standardInput = pipe

        do {
            try process.run()
            self.watchdogProcess = process
            self.writePipe = pipe
            log.info("Spawned crash guard watchdog (PID: \(process.processIdentifier), mute=\(muteOnCrash), pause=\(pauseOnCrash))")
        } catch {
            log.error("Failed to spawn crash guard watchdog: \(error)")
        }
    }

    // MARK: - Watchdog Execution (Subprocess Entry Point)

    /// Blocks on STDIN waiting for parent pipe closure or clean quit token.
    /// Runs with 0% CPU in the background companion process.
    public static func runWatchdogLoop(parentPID: pid_t, muteOnCrash: Bool, pauseOnCrash: Bool) {
        var token: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &token, 1)

        // If 'Q' was read, parent performed a clean, planned shutdown (Cmd+Q).
        if bytesRead == 1 && token == UInt8(ascii: "Q") {
            exit(0)
        }

        // Pipe broke / closed without clean token — PARENT CRASHED OR DIED!
        if muteOnCrash {
            performHardwareMute()
        }
        if pauseOnCrash {
            performMediaPause()
        }

        // Small grace period for hardware CoreAudio and MediaRemote IPC to complete
        usleep(150_000) // 150 ms
        exit(0)
    }

    // MARK: - Safety Actions

    public static func performHardwareMute() {
        var defaultOut: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultOut) == noErr,
              defaultOut != 0 else { return }

        // 1. Mute output
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteVal: UInt32 = 1
        AudioObjectSetPropertyData(defaultOut, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)

        // 2. Set scalar volume to 0.0 as secondary safeguard
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var zeroVol: Float32 = 0.0
        AudioObjectSetPropertyData(defaultOut, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &zeroVol)
    }

    public static func performMediaPause() {
        // Dynamic invocation of MediaRemote pause command
        typealias SendCommandFunc = @convention(c) (Int32, AnyObject?) -> Bool
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            let sendCommand = unsafeBitCast(sym, to: SendCommandFunc.self)
            _ = sendCommand(1 /* kMRPause */, nil)
        }

        // Also issue standard AppleScript pause for Spotify and Music
        let script = """
        if application "Spotify" is running then tell application "Spotify" to pause
        if application "Music" is running then tell application "Music" to pause
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - In-Process Signal Handlers (Tier 1 Defense)

    private func installSignalHandlers() {
        let signals = [SIGSEGV, SIGBUS, SIGABRT, SIGILL]
        for sig in signals {
            signal(sig) { signum in
                if CrashGuard.muteOnCrashActive {
                    CrashGuard.performHardwareMute()
                }
                if CrashGuard.pauseOnCrashActive {
                    CrashGuard.performMediaPause()
                }
                // Re-raise signal with default handler to allow standard crash report generation
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }
}
