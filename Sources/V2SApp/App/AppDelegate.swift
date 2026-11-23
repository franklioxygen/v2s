import AppKit
import Combine
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private let updaterService = UpdaterService()
    private let launchAtLoginService = LaunchAtLoginService()
    private let dockVisibilityController = DockVisibilityController()
    private lazy var transcriptWindowController = TranscriptWindowController(model: appModel)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var singleInstanceWakeObserver: NSObjectProtocol?
    private var singleInstanceLockDescriptor: Int32 = -1
    private var sourceRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if acquireSingleInstanceLock() == false {
            if handOffToExistingInstanceIfPossible() {
                return
            }

            // No other copy is left running. The lock is a flock, which the kernel
            // releases when its owner exits, so a holder that is still quitting
            // frees it shortly.
            guard waitForSingleInstanceLock(timeout: 2.0) else {
                NSApp.terminate(nil)
                return
            }
        } else if singleInstanceLockDescriptor < 0 {
            // If Application Support is unavailable we cannot keep a flock lock,
            // but a best-effort handoff still avoids opening duplicate windows.
            if handOffToExistingInstanceIfPossible() {
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)

        let settingsWindowController = SettingsWindowController(
            model: appModel,
            updaterService: updaterService,
            launchAtLoginService: launchAtLoginService,
            dockVisibilityController: dockVisibilityController,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
                NSApp.terminate(nil)
            }
        )
        let overlayWindowController = OverlayWindowController(
            model: appModel,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            }
        )
        let statusBarController = StatusBarController(
            model: appModel,
            openAdvancedSettings: { [weak settingsWindowController] in
                settingsWindowController?.showSettings()
            },
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
                NSApp.terminate(nil)
            }
        )

        self.settingsWindowController = settingsWindowController
        self.overlayWindowController = overlayWindowController
        self.statusBarController = statusBarController
        installSingleInstanceWakeObserver()

        overlayWindowController.trayIconRectProvider = { [weak self] in
            self?.statusBarController?.statusItemScreenRect
        }

        settingsWindowController.showSettings()

        appModel.$sessionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateSourceRefreshTimer(for: state)
            }
            .store(in: &cancellables)
    }

    // MARK: - Single-instance enforcement

    /// Asks a running copy to come forward. Returns true when this launch quits.
    ///
    /// This never terminates the other copy. A missing acknowledgement does not show
    /// that it is hung: distributed notifications can be delayed or dropped, the copy
    /// may be quitting, or it may be an older version with a different handoff format.
    /// Terminating it could end an active session.
    private func handOffToExistingInstanceIfPossible() -> Bool {
        let identifier = singleInstanceIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApplications = runningApplicationsForSingleInstance()
            .filter { $0.processIdentifier != currentPID && $0.isTerminated == false }
            .sorted { $0.processIdentifier < $1.processIdentifier }

        guard existingApplications.isEmpty == false else {
            return false
        }

        let requestID = UUID().uuidString
        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: identifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: identifier)
        let center = DistributedNotificationCenter.default()
        var acknowledged = false

        // The request ID travels as the notification object, not in userInfo:
        // a sandboxed app (the Mac App Store build) may not post userInfo.
        let ackObserver = center.addObserver(
            forName: wakeAcknowledgedName,
            object: nil,
            queue: .main
        ) { notification in
            if notification.object as? String == requestID {
                acknowledged = true
            }
        }

        center.postNotificationName(
            wakeRequestedName,
            object: requestID,
            userInfo: nil,
            deliverImmediately: true
        )
        existingApplications.first?.activate(options: [.activateAllWindows])

        let deadline = Date().addingTimeInterval(Self.singleInstanceWakeAcknowledgementTimeout)
        while acknowledged == false && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        center.removeObserver(ackObserver)

        if acknowledged == false {
            // The other copy may be quitting (for example during a relaunch). Give it a
            // moment, and launch normally if it is gone.
            let exitDeadline = Date().addingTimeInterval(Self.singleInstanceExitWaitTimeout)
            while existingApplications.contains(where: { $0.isTerminated == false }) && Date() < exitDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if existingApplications.allSatisfy(\.isTerminated) {
                return false
            }
            existingApplications.first { $0.isTerminated == false }?.activate(options: [.activateAllWindows])
        }

        NSApp.terminate(nil)
        return true
    }

    private func runningApplicationsForSingleInstance() -> [NSRunningApplication] {
        if let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.isEmpty == false {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }

        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == bundlePath
        }
    }

    private var singleInstanceIdentifier: String {
        if let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.isEmpty == false {
            return bundleIdentifier
        }

        let executableName = Bundle.main.executableURL?.lastPathComponent
            ?? ProcessInfo.processInfo.processName
        return "local.\(executableName)"
    }

    private func acquireSingleInstanceLock() -> Bool {
        guard let lockURL = singleInstanceLockURL() else {
            return true
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        singleInstanceLockDescriptor = descriptor
        writeSingleInstanceLockMetadata(to: descriptor)
        return true
    }

    private func waitForSingleInstanceLock(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if acquireSingleInstanceLock() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return acquireSingleInstanceLock()
    }

    private func releaseSingleInstanceLock() {
        guard singleInstanceLockDescriptor >= 0 else {
            return
        }
        flock(singleInstanceLockDescriptor, LOCK_UN)
        close(singleInstanceLockDescriptor)
        singleInstanceLockDescriptor = -1
    }

    private func singleInstanceLockURL() -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("v2s", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let sanitizedIdentifier = singleInstanceIdentifier.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return directoryURL.appendingPathComponent("\(String(sanitizedIdentifier)).lock")
    }

    private func writeSingleInstanceLockMetadata(to descriptor: Int32) {
        let metadata = [
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "identifier=\(singleInstanceIdentifier)",
            "path=\(Bundle.main.bundleURL.resolvingSymlinksInPath().path)"
        ]
        .joined(separator: "\n")
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = metadata.withCString { write(descriptor, $0, strlen($0)) }
    }

    private func installSingleInstanceWakeObserver() {
        guard singleInstanceWakeObserver == nil else {
            return
        }

        let identifier = singleInstanceIdentifier
        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: identifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: identifier)
        singleInstanceWakeObserver = DistributedNotificationCenter.default().addObserver(
            forName: wakeRequestedName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Versions up to 0.3.40 send the request ID in userInfo, with the bundle
            // identifier as the object. Current versions send it as the object.
            let legacyRequestID = notification.userInfo?["requestID"] as? String
            guard let requestID = legacyRequestID ?? (notification.object as? String),
                  requestID.isEmpty == false else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.settingsWindowController?.showSettings()
                NSApp.activate(ignoringOtherApps: true)

                if legacyRequestID != nil {
                    #if !APPSTORE
                    // Answer an older launcher in its own format so it does not time out
                    // and terminate this copy. A sandboxed app cannot post userInfo.
                    DistributedNotificationCenter.default().postNotificationName(
                        wakeAcknowledgedName,
                        object: identifier,
                        userInfo: [
                            "requestID": requestID,
                            "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier)
                        ],
                        deliverImmediately: true
                    )
                    #endif
                    return
                }

                DistributedNotificationCenter.default().postNotificationName(
                    wakeAcknowledgedName,
                    object: requestID,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        }
    }

    // MARK: - Source refresh timer

    private func installSourceRefreshTimer(interval: TimeInterval) {
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appModel.refreshSources()
            }
        }
    }

    private func updateSourceRefreshTimer(for state: SessionState) {
        guard state == .running else {
            sourceRefreshTimer?.invalidate()
            sourceRefreshTimer = nil
            return
        }

        installSourceRefreshTimer(interval: 5.0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let singleInstanceWakeObserver {
            DistributedNotificationCenter.default().removeObserver(singleInstanceWakeObserver)
            self.singleInstanceWakeObserver = nil
        }
        releaseSingleInstanceLock()
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = nil
        cancellables.removeAll()
        appModel.persistSettings()
    }
}

private extension AppDelegate {
    nonisolated static let singleInstanceWakeAcknowledgementTimeout: TimeInterval = 0.35
    /// How long a launch waits for an unanswering copy that may be quitting.
    nonisolated static let singleInstanceExitWaitTimeout: TimeInterval = 2.0

    nonisolated static func singleInstanceWakeRequestedNotificationName(
        for identifier: String
    ) -> Notification.Name {
        Notification.Name("\(identifier).singleInstanceWakeRequested")
    }

    nonisolated static func singleInstanceWakeAcknowledgedNotificationName(
        for identifier: String
    ) -> Notification.Name {
        Notification.Name("\(identifier).singleInstanceWakeAcknowledged")
    }
}
