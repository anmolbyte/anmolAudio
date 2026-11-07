import Foundation
import IOKit
import AppKit
import OSLog

private let log = Logger(subsystem: "app.anmol.anmolAudio", category: "ClamshellMonitor")

final class ClamshellMonitor {
    typealias Handler = (Bool) -> Void

    private let handler: Handler
    private var notifyPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var rootDomain: io_service_t = 0
    private var screenObserver: Any?
    private var wakeObserver: Any?
    private var lastState: Bool

    init(handler: @escaping Handler) {
        self.handler = handler
        self.lastState = ClamshellMonitor.isLidClosed

        // Listen for screen parameter changes (fires when lid opens/closes with external display connected)
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkState()
        }

        // Listen for wake events
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkState()
        }

        // Register for IOKit power / clamshell notifications on IOPMrootDomain
        let port = IONotificationPortCreate(kIOMainPortDefault)
        self.notifyPort = port
        if let port = port {
            let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            self.rootDomain = service
            if service != 0 {
                let callback: IOServiceInterestCallback = { refcon, _, _, _ in
                    guard let refcon = refcon else { return }
                    let monitor = Unmanaged<ClamshellMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        monitor.checkState()
                    }
                }
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                let kr = IOServiceAddInterestNotification(
                    port,
                    service,
                    kIOGeneralInterest,
                    callback,
                    refcon,
                    &self.notification
                )
                if kr != kIOReturnSuccess {
                    log.error("Failed to register clamshell interest notification: \(kr)")
                }
            }
        }
    }

    /// Queries the current hardware lid status from IOPMrootDomain.
    /// Returns true when the laptop lid is closed (clamshell mode), false otherwise (or on desktop Macs).
    static var isLidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let val = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
        return val ?? false
    }

    func checkState() {
        let current = ClamshellMonitor.isLidClosed
        if current != lastState {
            log.info("Lid state changed: was \(self.lastState), now \(current)")
            lastState = current
            handler(current)
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if notification != 0 { IOObjectRelease(notification) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let notifyPort = notifyPort {
            let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            IONotificationPortDestroy(notifyPort)
        }
    }
}
