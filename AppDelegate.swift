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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
