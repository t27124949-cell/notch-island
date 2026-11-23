import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        setUpStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
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
