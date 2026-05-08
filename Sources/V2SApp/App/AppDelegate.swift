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
    private var globalHotKeyController: GlobalHotKeyController?
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
        } else if singleInstanceLockDescriptor < 0,
                  handOffToExistingInstanceIfPossible() {
            return
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
            },
            quitApp: {
                NSApp.terminate(nil)
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

        let hotKeyController = GlobalHotKeyController { [weak self] action in
            switch action {
            case .followUp:
                self?.appModel.requestGPTFollowUp()
            case .ask:
                self?.appModel.requestGPTAsk()
            case .switchMode:
                self?.appModel.toggleOverlayViewMode()
            }
        }
        hotKeyController.update(
            followUp: appModel.hotKeyFollowUp,
            ask: appModel.hotKeyAsk,
            switchMode: appModel.hotKeySwitchMode
        )
        self.globalHotKeyController = hotKeyController

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

        appModel.$hotKeyFollowUp
            .combineLatest(appModel.$hotKeyAsk)
            .combineLatest(appModel.$hotKeySwitchMode)
            .sink { [weak self] combined, switchMode in
                let (followUp, ask) = combined
                self?.globalHotKeyController?.update(followUp: followUp, ask: ask, switchMode: switchMode)
            }
            .store(in: &cancellables)
    }

    private func handOffToExistingInstanceIfPossible() -> Bool {
        let bundleIdentifier = singleInstanceIdentifier

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID && $0.isTerminated == false }
            .sorted { $0.processIdentifier < $1.processIdentifier }

        guard existingApps.isEmpty == false else {
            return false
        }

        let requestID = UUID().uuidString
        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: bundleIdentifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: bundleIdentifier)
        var acknowledgedPID: pid_t?
        let center = DistributedNotificationCenter.default()
        let ackObserver = center.addObserver(
            forName: wakeAcknowledgedName,
            object: bundleIdentifier,
            queue: .main
        ) { notification in
            guard let receivedRequestID = notification.userInfo?["requestID"] as? String,
                  receivedRequestID == requestID else {
                return
            }
            if let pidNumber = notification.userInfo?["pid"] as? NSNumber {
                acknowledgedPID = pidNumber.int32Value
            } else {
                acknowledgedPID = existingApps.first?.processIdentifier
            }
        }

        center.postNotificationName(
            wakeRequestedName,
            object: bundleIdentifier,
            userInfo: ["requestID": requestID],
            deliverImmediately: true
        )
        existingApps.first?.activate(options: [.activateAllWindows])

        let deadline = Date().addingTimeInterval(0.9)
        while acknowledgedPID == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        center.removeObserver(ackObserver)

        if let acknowledgedPID {
            let staleApps = existingApps.filter { $0.processIdentifier != acknowledgedPID }
            terminateExistingApplications(staleApps)
            NSApp.terminate(nil)
            return true
        }

        terminateExistingApplications(existingApps)
        return false
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
        guard singleInstanceLockDescriptor >= 0 else { return }
        flock(singleInstanceLockDescriptor, LOCK_UN)
        close(singleInstanceLockDescriptor)
        singleInstanceLockDescriptor = -1
    }

    private func singleInstanceLockURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = applicationSupport.appendingPathComponent("v2s", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let sanitizedIdentifier = singleInstanceIdentifier
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "." || character == "-"
                    ? character
                    : "_"
            }
        return directory.appendingPathComponent("\(String(sanitizedIdentifier)).lock")
    }

    private func writeSingleInstanceLockMetadata(to descriptor: Int32) {
        let metadata = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        identifier=\(singleInstanceIdentifier)
        path=\(Bundle.main.bundleURL.path)
        """

        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = metadata.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }

    private func terminateSingleInstanceLockOwnerIfNeeded() {
        guard let lockURL = singleInstanceLockURL(),
              let contents = try? String(contentsOf: lockURL, encoding: .utf8),
              let pidLine = contents.split(separator: "\n").first(where: { $0.hasPrefix("pid=") }),
              let pid = Int32(pidLine.dropFirst(4)),
              pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        if let application = NSRunningApplication(processIdentifier: pid), application.isTerminated == false {
            terminateExistingApplications([application])
            return
        }

        guard kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(1.0)
        while kill(pid, 0) == 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    private func installSingleInstanceWakeObserver() {
        guard singleInstanceWakeObserver == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: bundleIdentifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: bundleIdentifier)
        singleInstanceWakeObserver = DistributedNotificationCenter.default().addObserver(
            forName: wakeRequestedName,
            object: bundleIdentifier,
            queue: .main
        ) { [weak self] notification in
            guard let requestID = notification.userInfo?["requestID"] as? String else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wakeMainWindow()
                DistributedNotificationCenter.default().postNotificationName(
                    wakeAcknowledgedName,
                    object: bundleIdentifier,
                    userInfo: [
                        "requestID": requestID,
                        "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier)
                    ],
                    deliverImmediately: true
                )
            }
        }
    }

    private func wakeMainWindow() {
        settingsWindowController?.showSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func terminateExistingApplications(_ applications: [NSRunningApplication]) {
        guard applications.isEmpty == false else { return }

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
    nonisolated static func singleInstanceWakeRequestedNotificationName(
        for bundleIdentifier: String
    ) -> Notification.Name {
        return Notification.Name("\(bundleIdentifier).singleInstanceWakeRequested")
    }

    nonisolated static func singleInstanceWakeAcknowledgedNotificationName(
        for bundleIdentifier: String
    ) -> Notification.Name {
        return Notification.Name("\(bundleIdentifier).singleInstanceWakeAcknowledged")
    }
}
