import Foundation
import OSLog
import CoreAudio

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "AudioCapturePermission")

/// Wraps the private TCC SPI required to request the system-audio-capture
/// permission used by Core Audio Process Taps on macOS 14.2+. No public API
/// triggers the prompt for `kTCCServiceAudioCapture`, so we have to call into
/// `/System/Library/PrivateFrameworks/TCC.framework` directly. Pattern lifted
/// from Apple-employee sample app `AudioCap`.
enum AudioCapturePermission {
    enum Status {
        case authorized
        case denied
        case unknown
    }

    /// Tests whether Core Audio actually permits creating a process tap.
    /// This is the ground truth on macOS 14.2+ and avoids issues with SPI code drift.
    static func canCreateTap() -> Bool {
        var tapID: AudioObjectID = 0
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            return true
        }
        return false
    }

    /// Returns the current permission status without prompting the user.
    static func preflight() -> Status {
        if canCreateTap() {
            return .authorized
        }

        guard let fn = preflightSPI else {
            log.warning("TCCAccessPreflight SPI not available")
            return .unknown
        }
        let result = fn("kTCCServiceAudioCapture" as CFString, nil)
        // TCCAccessPreflight: 0 = authorized, 1 = not determined / prompt needed, 2 = denied.
        log.debug("TCCAccessPreflight(kTCCServiceAudioCapture) = \(result, privacy: .public)")
        switch result {
        case 0: return .authorized
        case 1: return .unknown
        case 2: return .denied
        default: return .unknown
        }
    }

    /// Triggers the system permission prompt for `kTCCServiceAudioCapture` if the
    /// user has not yet granted/denied it. Calls `completion` on whichever queue
    /// TCC delivers the result on (typically a background thread).
    static func request(completion: @escaping (Bool) -> Void) {
        guard let fn = requestSPI else {
            log.fault("TCCAccessRequest SPI not available")
            completion(false)
            return
        }
        fn("kTCCServiceAudioCapture" as CFString, nil) { granted in
            let tapAllowed = canCreateTap()
            log.notice("TCC audio-capture request finished: granted=\(granted, privacy: .public), tapAllowed=\(tapAllowed, privacy: .public)")
            completion(granted || tapAllowed)
        }
    }

    /// Asynchronous helper for UI actions. Returns true if authorized. Does not block the main thread.
    static func ensureAuthorizedAsync() async -> Bool {
        if canCreateTap() {
            return true
        }
        switch preflight() {
        case .authorized:
            return true
        case .denied, .unknown:
            return await withCheckedContinuation { continuation in
                request { granted in
                    continuation.resume(returning: granted || canCreateTap())
                }
            }
        }
    }

    /// Synchronous helper for engine startup. Returns true if we are (or become)
    /// authorized. Blocks the calling thread on the prompt — only call from a
    /// background queue if blocking the main thread would freeze the UI.
    static func ensureAuthorized() -> Bool {
        if canCreateTap() {
            return true
        }
        switch preflight() {
        case .authorized:
            return true
        case .denied, .unknown:
            let sem = DispatchSemaphore(value: 0)
            var result = false
            request { granted in
                result = granted || canCreateTap()
                sem.signal()
            }
            sem.wait()
            return result
        }
    }

    // MARK: - Private TCC SPI

    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        return dlopen(path, RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFuncType? = {
        guard let apiHandle else { return nil }
        guard let sym = dlsym(apiHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
        guard let apiHandle else { return nil }
        guard let sym = dlsym(apiHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFuncType.self)
    }()
}
