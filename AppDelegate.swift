import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        setUpStatusItem()
        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showWelcome() }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Welcome & Permissions…", action: #selector(showWelcome), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Debug Info…", action: #selector(showDebugInfo), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch Island", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() {
        controller.model.isPinned.toggle()
        controller.model.isOpen = controller.model.isPinned
    }

    @objc private func showDebugInfo() {
        NSApp.activate(ignoringOtherApps: true)
        let info = controller.debugInfo()
        let alert = NSAlert()
        alert.messageText = "Notch Island debug info"
        alert.informativeText = info
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }
    }

    /// First-run explainer: how it works and exactly what macOS may ask for, and why.
    @objc func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Notch Island"
        alert.informativeText = """
        Move your pointer to the notch to open the island. Click the pin to keep it open.

        macOS may ask for a few permissions, and all are optional:
        • Calendar: only for the Calendar tab.
        • Control of Music or Spotify: only for Now Playing (controls and lyrics).
        • Bluetooth: only so the notch can tell you when AirPods or headphones connect.
        Weather uses just the city you type, so it needs no location permission.

        You can switch any tab off in Settings. To start with your Mac, turn on "Open at login" in Settings (it works once the app is in your Applications folder).

        Tip: if the menu bar drops down when you touch the top of the screen, that is macOS's auto-hide menu bar. You can change it in System Settings → Control Center.
        """
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            controller.model.tab = .settings
            controller.model.isPinned = true
            controller.model.isOpen = true
        }
    }

    /// Opens a pre-filled GitHub issue with the debug info (home folder hidden).
    @objc func reportBug() {
        let info = controller.debugInfo().replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        **What happened?**


        **What did you expect?**


        Notch Island \(UpdateChecker.currentVersion) · macOS \(system)

        <details><summary>Debug info</summary>

        ```
        \(info)
        ```
        </details>
        """
        guard var parts = URLComponents(string: "https://github.com/t27124949-cell/notch-island/issues/new") else { return }
        parts.queryItems = [URLQueryItem(name: "title", value: "Bug: "),
                            URLQueryItem(name: "body", value: String(body.prefix(5000)))]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.check { result in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .upToDate(let version):
                alert.messageText = "You're up to date"
                alert.informativeText = "Notch Island \(version) is the latest version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .available(let version, let url):
                alert.messageText = "Version \(version) is available"
                alert.informativeText = "You have \(UpdateChecker.currentVersion). Download the new version, then replace Notch Island in your Applications folder."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            case .failed(let message):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
