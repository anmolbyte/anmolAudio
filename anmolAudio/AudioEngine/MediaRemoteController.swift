import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "MediaRemoteController")

/// Controls system-wide media playback (macOS Now Playing / MediaRemote) and
/// popular desktop players (Spotify, Apple Music) during incoming or active calls.
@MainActor
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    private typealias MRMediaRemoteSendCommandFunction = @convention(c) (Int32, AnyObject?) -> Bool
    private var sendCommandFunc: MRMediaRemoteSendCommandFunction?

    // MediaRemote commands:
    // 0: Play, 1: Pause, 2: TogglePlayPause, 3: Stop
    private let kMRPlay: Int32 = 0
    private let kMRPause: Int32 = 1

    /// Tracks whether anmolAudio paused media for an active call or ring so we only
    /// resume playback after the call if media was actually playing beforehand.
    private(set) var didPauseForCall: Bool = false

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFunc = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
        } else {
            log.warning("Could not dynamically load MRMediaRemoteSendCommand from MediaRemote.framework")
        }
    }

    /// Pauses any active media playback (Spotify, Apple Music, Safari/Chrome YouTube, etc.)
    func pauseForCall() {
        guard !didPauseForCall else { return }
        log.info("Pausing media playback for call")
        didPauseForCall = true
        sendPause()
    }

    /// Pauses any active media playback across macOS on device change or manual request.
    func pauseMedia() {
        log.info("Pausing media playback")
        sendPause()
    }

    /// Resumes media playback if anmolAudio paused it for a call.
    func resumeAfterCall() {
        guard didPauseForCall else { return }
        didPauseForCall = false
        log.info("Resuming media playback after call finished")
        sendResume()
    }

    /// Resets the paused state without sending a play command (e.g. if auto-resume is disabled).
    func clearCallPauseState() {
        didPauseForCall = false
    }

    private func sendPause() {
        // 1. Send system-wide Now Playing pause command
        if let sendCommand = sendCommandFunc {
            _ = sendCommand(kMRPause, nil)
        }

        // 2. Direct pause for Spotify or Apple Music if running
        pauseAppIfRunning("com.spotify.client", appName: "Spotify")
        pauseAppIfRunning("com.apple.Music", appName: "Music")
    }

    private func sendResume() {
        // 1. Send system-wide Now Playing play command
        if let sendCommand = sendCommandFunc {
            _ = sendCommand(kMRPlay, nil)
        }

        // 2. Direct play for Spotify or Apple Music if running
        playAppIfRunning("com.spotify.client", appName: "Spotify")
        playAppIfRunning("com.apple.Music", appName: "Music")
    }

    private func pauseAppIfRunning(_ bundleID: String, appName: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return }
        let script = "tell application \"\(appName)\" to pause"
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }

    private func playAppIfRunning(_ bundleID: String, appName: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return }
        let script = "tell application \"\(appName)\" to play"
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
        }
    }
}
