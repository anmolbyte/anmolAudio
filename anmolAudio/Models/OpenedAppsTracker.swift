import Foundation
import AppKit
import CoreServices

/// Tracks every GUI application that has ever been opened on this Mac,
/// excluding uninstalled applications.
@MainActor
final class OpenedAppsTracker: ObservableObject {
    static let shared = OpenedAppsTracker()

    struct AppItem: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isRunning: Bool
        let appURL: URL?
    }

    private static let defaultsKey = "anmolAudio.knownOpenedAppBundleIDs"
    @Published private(set) var openedApps: [AppItem] = []

    private var knownBundleIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.defaultsKey)
        }
    }

    private init() {
        refresh()
    }

    func recordAppOpened(bundleID: String) {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }
        var current = knownBundleIDs
        if !current.contains(bundleID) {
            current.insert(bundleID)
            knownBundleIDs = current
            refresh()
        }
    }

    func refresh() {
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        let runningApps = NSWorkspace.shared.runningApplications
        let runningBIDs = Set(runningApps.compactMap(\.bundleIdentifier))

        var discoveredBIDs = knownBundleIDs
        var appsByBID: [String: (name: String, isRunning: Bool, url: URL)] = [:]

        let blockedPrefixes = [
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
            "com.apple.audio.coreaudiod",
            "app.monitorcontrol"
        ]

        for dir in appDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bid = bundle.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier
                else { continue }

                if blockedPrefixes.contains(where: { bid.lowercased().hasPrefix($0.lowercased()) }) {
                    continue
                }

                // Exclude pure background-only agents / daemons
                let isAgent = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? String == "1") ||
                              (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true) ||
                              (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? String == "1") ||
                              (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true)
                if isAgent { continue }

                // Must be installed and exist on disk
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                let isRunning = runningBIDs.contains(bid)
                var wasOpened = isRunning || discoveredBIDs.contains(bid)

                if !wasOpened,
                   let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                   let _ = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate as CFString) {
                    wasOpened = true
                    discoveredBIDs.insert(bid)
                }

                if wasOpened {
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    appsByBID[bid] = (name: name, isRunning: isRunning, url: url)
                }
            }
        }

        // Also check any running regular apps that might be in non-standard paths
        for running in runningApps {
            guard running.activationPolicy == .regular,
                  let bid = running.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier,
                  appsByBID[bid] == nil,
                  !blockedPrefixes.contains(where: { bid.lowercased().hasPrefix($0.lowercased()) })
            else { continue }

            if let url = running.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
               FileManager.default.fileExists(atPath: url.path) {
                let name = running.localizedName ?? AudioProcessInfo.displayName(forBundleID: bid)
                appsByBID[bid] = (name: name, isRunning: true, url: url)
                discoveredBIDs.insert(bid)
            }
        }

        // Persist newly discovered opened bundle IDs, pruning uninstalled ones
        var validKnown = Set<String>()
        for bid in discoveredBIDs {
            if appsByBID[bid] != nil || (NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil && FileManager.default.fileExists(atPath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path ?? "")) {
                validKnown.insert(bid)
            }
        }
        knownBundleIDs = validKnown

        // Convert to AppItem list
        var items: [AppItem] = appsByBID.map { (bid, val) in
            AppItem(bundleID: bid, displayName: val.name, isRunning: val.isRunning, appURL: val.url)
        }

        // Sort: running apps first (A-Z), then stopped apps (A-Z)
        items.sort { a, b in
            if a.isRunning != b.isRunning {
                return a.isRunning && !b.isRunning
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        self.openedApps = items
    }
}
