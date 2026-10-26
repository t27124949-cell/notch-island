import AppKit
import Combine

struct RunningApp: Identifiable {
    let id: pid_t
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    let isFrontmost: Bool
    let isHidden: Bool
}

/// The apps you currently have open (regular Dock apps), kept up to date from NSWorkspace notifications.
final class AppsStore: ObservableObject {
    @Published var apps: [RunningApp] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    func refresh() {
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fallbackIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()

        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .map { app in
                RunningApp(
                    id: app.processIdentifier,
                    app: app,
                    name: app.localizedName ?? app.bundleIdentifier ?? "App",
                    icon: app.icon ?? fallbackIcon,
                    isFrontmost: app.processIdentifier == front,
                    isHidden: app.isHidden
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Actions

    /// Bring the app to the front (un-hiding it first if needed).
    func activate(_ item: RunningApp) {
        if item.isHidden { item.app.unhide() }
        guard let url = item.app.bundleURL else { return }
        // Opening an already-running app's bundle brings it forward; more reliable than
        // NSRunningApplication.activate from a menu-bar app that isn't itself active.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    func toggleHidden(_ item: RunningApp) {
        if item.isHidden { item.app.unhide() } else { item.app.hide() }
    }

    func quit(_ item: RunningApp) { item.app.terminate() }

    func forceQuit(_ item: RunningApp) { item.app.forceTerminate() }

    func reveal(_ item: RunningApp) {
        guard let url = item.app.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
