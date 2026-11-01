import Foundation
import CoreAudio
import AppKit
import OSLog
import Darwin

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "AudioProcessInfo")

/// Helpers for enumerating the Core Audio process-object list and translating
/// process objects to user-meaningful identifiers (bundle ID, app name, icon).
enum AudioProcessInfo {
    /// One user-facing application that owns one or more Core Audio process objects.
    /// Multiple helper processes (Safari WebContent, Chrome renderers, Electron helpers)
    /// group under their parent application here.
    struct App: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isPlaying: Bool

        init(bundleID: String, displayName: String, isPlaying: Bool = false) {
            self.bundleID = bundleID
            self.displayName = displayName
            self.isPlaying = isPlaying
        }
    }

    // MARK: - Responsible process lookup

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// responsibility_get_pid_responsible_for_pid maps helper processes (browser tabs,
    /// Electron renderers) to the user-facing app that spawned them — the exact same attribution
    /// macOS TCC uses.
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }

    // MARK: - Bundle ID lookup

    /// Reads `kAudioProcessPropertyBundleID` from a Core Audio process object,
    /// resolving helper processes to their parent application bundle ID.
    static func bundleID(for processObject: AudioObjectID) -> String? {
        if let processPid = pid(for: processObject) {
            let ownerPid = responsiblePID(for: processPid)
            if let runningApp = NSRunningApplication(processIdentifier: ownerPid)
                ?? NSRunningApplication(processIdentifier: processPid),
               let bid = runningApp.bundleIdentifier, !bid.isEmpty {
                return bid
            }

            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(processPid, &buffer, UInt32(buffer.count))
            if length > 0 {
                let path = String(cString: buffer)
                let name = (path as NSString).lastPathComponent
                if name == "avconferenced" {
                    return "com.apple.avconferenced"
                } else if name == "FaceTime" {
                    return "com.apple.FaceTime"
                } else if name == "callservicesd" {
                    return "com.apple.telephonyutilities.callservicesd"
                } else if name == "TelephonyUtilities" {
                    return "com.apple.TelephonyUtilities"
                }
            }
        }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &cfRef)
        if status == noErr, let cf = cfRef?.takeRetainedValue() {
            let value = cf as String
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    /// True while the process has an IO proc running output — it is playing
    /// audio *right now*, not merely registered with Core Audio.
    static func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Reads `kAudioProcessPropertyPID` from a Core Audio process object.
    static func pid(for processObject: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    // MARK: - Process object enumeration

    /// Resolves the Core Audio process object representing the given pid.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var input = pid
        var output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &input,
            &size,
            &output
        )
        if status != noErr {
            throw CoreAudioError.osStatus(status, "TranslatePIDToProcessObject(pid=\(pid))")
        }
        return output
    }

    /// Every audio-registered process the system knows about.
    static func allProcessObjects() throws -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let s1 = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        if s1 != noErr {
            throw CoreAudioError.osStatus(s1, "kAudioHardwarePropertyProcessObjectList size")
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let s2 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        if s2 != noErr {
            throw CoreAudioError.osStatus(s2, "kAudioHardwarePropertyProcessObjectList data")
        }
        return ids
    }

    // MARK: - EarTrumpet-style user-facing app list

    /// Internal macOS daemons and services that should never show up in the user volume mixer.
    private static let blockedBundlePrefixes: [String] = [
        "com.apple.accessibility",
        "com.apple.assistant",
        "com.apple.audiomxd",
        "com.apple.cmio",
        "com.apple.CoreSpeech",
        "com.apple.mediaremote",
        "com.apple.telephonyutilities",
        "com.apple.PowerChime",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.apple.systemsoundserverd",
        "com.apple.audio.coreaudiod",
        "app.monitorcontrol"
    ]

    /// Snapshot of real, user-facing applications (e.g. Safari, Spotify, Chrome, Music).
    ///
    /// EarTrumpet-style filtering:
    /// - Resolves helper processes (e.g. WebContent, Chrome renderers, Antigravity Helper) to the parent app.
    /// - Drops system daemons, background agents, and internal OS audio plumbing.
    /// - Regular GUI apps always show; background agents only appear if they are actively playing audio.
    /// - Sorts actively playing apps to the top, followed by alphabetical order.
    static func runningAudioApps() -> [App] {
        let objects = (try? allProcessObjects()) ?? []
        let ownPID = getpid()
        var byBundleID: [String: (app: App, isPlaying: Bool)] = [:]

        for obj in objects {
            guard let processPid = pid(for: obj) else { continue }
            let ownerPid = responsiblePID(for: processPid)
            if ownerPid == ownPID || processPid == ownPID { continue }

            guard let running = NSRunningApplication(processIdentifier: ownerPid)
                ?? NSRunningApplication(processIdentifier: processPid),
                let bundleID = running.bundleIdentifier,
                bundleID != Bundle.main.bundleIdentifier
            else { continue }

            if blockedBundlePrefixes.contains(where: { bundleID.lowercased().hasPrefix($0.lowercased()) }) {
                continue
            }

            let playing = isRunningOutput(obj)

            // Real app filter: Regular GUI apps always; accessory/background
            // helpers only if they are actually producing audio right now.
            guard running.activationPolicy == .regular || playing else {
                continue
            }

            let name = running.localizedName ?? displayName(forBundleID: bundleID, processObject: obj)
            if let existing = byBundleID[bundleID] {
                let isNowPlaying = existing.isPlaying || playing
                byBundleID[bundleID] = (
                    app: App(bundleID: bundleID, displayName: name, isPlaying: isNowPlaying),
                    isPlaying: isNowPlaying
                )
            } else {
                byBundleID[bundleID] = (
                    app: App(bundleID: bundleID, displayName: name, isPlaying: playing),
                    isPlaying: playing
                )
            }
        }

        // Playing apps first, then alphabetical
        return byBundleID.values.map(\.app).sorted {
            if $0.isPlaying != $1.isPlaying {
                return $0.isPlaying && !$1.isPlaying
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Best-effort display name for a bundle ID.
    static func displayName(forBundleID bundleID: String, processObject: AudioObjectID? = nil) -> String {
        if let pid = processObject.flatMap({ pid(for: $0) }) {
            let ownerPid = responsiblePID(for: pid)
            if let app = NSRunningApplication(processIdentifier: ownerPid)
                ?? NSRunningApplication(processIdentifier: pid),
               let name = app.localizedName, !name.isEmpty {
                return name
            }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String),
           !name.isEmpty {
            return name
        }
        return bundleID
    }

    /// Resolves a Finder icon for a bundle ID.
    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - Process-list change listener

/// Fires whenever the system's audio process-object list changes.
final class AudioProcessListChangeListener {
    typealias Handler = () -> Void

    private let handler: Handler
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var block: AudioObjectPropertyListenerBlock?

    init(handler: @escaping Handler) {
        self.handler = handler
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler()
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            log.error("Failed to register process-list change listener: \(status)")
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}
