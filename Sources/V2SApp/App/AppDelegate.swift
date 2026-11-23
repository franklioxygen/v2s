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

            terminateSingleInstanceLockOwnerIfNeeded()
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
        var acknowledgedPID: pid_t?

        // The request ID and PID travel in the notification's object string, not in
        // userInfo: a sandboxed app (the Mac App Store build) may not post userInfo.
        let ackObserver = center.addObserver(
            forName: wakeAcknowledgedName,
            object: nil,
            queue: .main
        ) { notification in
            guard let payload = notification.object as? String,
                  let acknowledgement = Self.parseSingleInstanceWakeAcknowledgement(payload),
                  acknowledgement.requestID == requestID else {
                return
            }

            acknowledgedPID = acknowledgement.pid ?? existingApplications.first?.processIdentifier
        }

        center.postNotificationName(
            wakeRequestedName,
            object: requestID,
            userInfo: nil,
            deliverImmediately: true
        )
        existingApplications.first?.activate(options: [.activateAllWindows])

        let deadline = Date().addingTimeInterval(Self.singleInstanceWakeAcknowledgementTimeout)
        while acknowledgedPID == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        center.removeObserver(ackObserver)

        if let acknowledgedPID {
            let staleApplications = existingApplications.filter { $0.processIdentifier != acknowledgedPID }
            terminateExistingApplications(staleApplications)
            NSApp.terminate(nil)
            return true
        }

        terminateExistingApplications(existingApplications)
        return false
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

    private func terminateSingleInstanceLockOwnerIfNeeded() {
        guard let lockURL = singleInstanceLockURL(),
              let metadata = singleInstanceLockMetadata(at: lockURL),
              let pid = metadata.pid,
              pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid),
              application.isTerminated == false,
              matchesSingleInstanceIdentity(application, metadata: metadata) else {
            return
        }

        terminateExistingApplications([application])
    }

    private func singleInstanceLockMetadata(at lockURL: URL) -> SingleInstanceLockMetadata? {
        guard let contents = try? String(contentsOf: lockURL, encoding: .utf8) else {
            return nil
        }

        var pid: Int32?
        var identifier: String?
        var path: String?

        for line in contents.split(separator: "\n") {
            if line.hasPrefix("pid=") {
                pid = Int32(line.dropFirst(4))
            } else if line.hasPrefix("identifier=") {
                identifier = String(line.dropFirst("identifier=".count))
            } else if line.hasPrefix("path=") {
                path = String(line.dropFirst("path=".count))
            }
        }

        return SingleInstanceLockMetadata(pid: pid, identifier: identifier, path: path)
    }

    private func matchesSingleInstanceIdentity(
        _ application: NSRunningApplication,
        metadata: SingleInstanceLockMetadata
    ) -> Bool {
        if let metadataIdentifier = metadata.identifier,
           let bundleIdentifier = application.bundleIdentifier,
           bundleIdentifier == metadataIdentifier {
            return true
        }

        if let metadataPath = metadata.path,
           application.bundleURL?.resolvingSymlinksInPath().path == metadataPath {
            return true
        }

        return false
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
            guard let requestID = notification.object as? String, requestID.isEmpty == false else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.settingsWindowController?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                DistributedNotificationCenter.default().postNotificationName(
                    wakeAcknowledgedName,
                    object: Self.singleInstanceWakeAcknowledgementPayload(
                        requestID: requestID,
                        pid: ProcessInfo.processInfo.processIdentifier
                    ),
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        }
    }

    private func terminateExistingApplications(_ applications: [NSRunningApplication]) {
        guard applications.isEmpty == false else {
            return
        }

        for application in applications where application.isTerminated == false {
            application.terminate()
        }

        let deadline = Date().addingTimeInterval(1.2)
        while applications.contains(where: { $0.isTerminated == false }) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        for application in applications where application.isTerminated == false {
            application.forceTerminate()
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

private struct SingleInstanceLockMetadata {
    let pid: Int32?
    let identifier: String?
    let path: String?
}

private extension AppDelegate {
    nonisolated static let singleInstanceWakeAcknowledgementTimeout: TimeInterval = 0.35

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

    /// "<requestID>|<pid>", sent as the acknowledgement's object.
    nonisolated static func singleInstanceWakeAcknowledgementPayload(requestID: String, pid: pid_t) -> String {
        "\(requestID)|\(pid)"
    }

    nonisolated static func parseSingleInstanceWakeAcknowledgement(
        _ payload: String
    ) -> (requestID: String, pid: pid_t?)? {
        let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let requestID = parts.first, requestID.isEmpty == false else {
            return nil
        }
        let pid = parts.count > 1 ? pid_t(parts[1]) : nil
        return (String(requestID), pid)
    }
}
