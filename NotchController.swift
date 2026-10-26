import AppKit
import Combine

/// Borderless panel that floats above the menu bar without activating the app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// An accessory app has no Edit menu, so route the usual shortcuts to the focused text field ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let selector: Selector?
        switch key {
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = shift ? Selector(("redo:")) : Selector(("undo:"))
        default: selector = nil
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class NotchController {
    let model = NotchModel()

    private var panel: NotchPanel!
    private var island: IslandView!
    private var cancellables = Set<AnyCancellable>()
    private var activity: NSObjectProtocol?
    private var monitor: ActivityMonitor?
    private var peekWork: DispatchWorkItem?

    // Pointer polling. The open/close decision is level-triggered: every tick it is recomputed from the
    // pointer position and how long the pointer has been in/out of the zone, so a missed event can't
    // leave it stuck.
    private var pollTimer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var wasPressed = false
    private var lastInside: Bool?

    // These come from Settings.
    private var openDelay: TimeInterval { model.settings.openDelay }
    private var closeDelay: TimeInterval { model.settings.closeDelay }
    private var hotZoneSidePadding: CGFloat {
        model.settings.clickToOpen ? 6 : CGFloat(model.settings.hotZonePadding)
    }

    // Diagnostics (menu bar icon → Debug Info…, and the log file)
    private var pollTicks = 0
    private var lastTick: Date?
    private var maxGap: TimeInterval = 0
    private var slowTicks = 0
    private var log: [String] = []
    private let startTime = Date()
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchIsland.log")

    private func note(_ text: String) {
        let t = String(format: "%7.2f", Date().timeIntervalSince(startTime))
        let line = "\(t)s  \(text)"
        log.append(line)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    func start() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8) // fresh log each launch

        // Keep macOS from throttling our pointer-polling timer when the app sits idle.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Track the pointer for the notch island"
        )

        if let screen = targetScreen {
            model.notchSize = notchSize(for: screen)
        }

        let island = IslandView(model: model)
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: model.openSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = island
        // The panel is always full size, but while closed it is click-through so the menu bar still works.
        panel.ignoresMouseEvents = true
        self.panel = panel
        self.island = island

        positionPanel()
        panel.orderFrontRegardless()

        model.$isOpen
            .removeDuplicates()
            .sink { [weak self] open in
                guard let self else { return }
                self.note("isOpen = \(open)")
                self.panel.ignoresMouseEvents = !open
                if open {
                    self.peekWork?.cancel()
                    self.panel.orderFrontRegardless()
                } else {
                    self.insideSince = nil // restart the dwell timer after any close
                    if self.panel.isKeyWindow { self.panel.resignKey() }
                }
                self.island.setOpen(open, animated: true)
            }
            .store(in: &cancellables)

        // Live activities: briefly widen the notch, then tuck it away again.
        model.$activity
            .compactMap { $0 }
            .sink { [weak self] activity in
                guard let self, !self.model.isOpen else { return }
                self.note("peek: \(activity.title)")
                self.island.showPeek(activity)
                self.peekWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.island.hidePeek() }
                self.peekWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + activity.duration, execute: work)
            }
            .store(in: &cancellables)

        let monitor = ActivityMonitor(model: model)
        monitor.start()
        self.monitor = monitor

        model.$isPinned
            .removeDuplicates()
            .sink { [weak self] pinned in self?.note("isPinned = \(pinned)") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, let screen = self.targetScreen else { return }
                self.model.notchSize = self.notchSize(for: screen)
                self.positionPanel()
            }
            .store(in: &cancellables)

        // Poll the pointer 20x per second. Reading NSEvent.mouseLocation needs no events and no permissions.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        note("started (AppKit UI)")
    }

    // MARK: Hover / click handling

    private func pollMouse() {
        pollTicks += 1

        // Watch for the poll itself stalling (App Nap, main thread busy, Mac under load).
        let tickNow = Date()
        if let last = lastTick {
            let gap = tickNow.timeIntervalSince(last)
            if gap > maxGap { maxGap = gap }
            if gap > 0.25 {
                slowTicks += 1
                note(String(format: "SLOW TICK: %.2fs since the last poll (should be 0.05s)", gap))
            }
        }
        lastTick = tickNow

        guard let screen = targetScreen else { return }

        let mouse = NSEvent.mouseLocation
        let inside = activeZone(on: screen).contains(mouse)

        // The panel is bigger than a short island; let clicks fall through the empty part below it.
        if model.isOpen {
            let capture = islandFrame(on: screen).contains(mouse)
            if panel.ignoresMouseEvents == capture { panel.ignoresMouseEvents = !capture }
        }

        if inside != lastInside {
            lastInside = inside
            note("pointer \(inside ? "entered" : "left") zone at (\(Int(mouse.x)), \(Int(mouse.y)))")
        }

        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = tickNow }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = tickNow }
        }

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let freshClick = pressed && !wasPressed
        wasPressed = pressed

        if !model.isOpen {
            if model.settings.clickToOpen {
                if freshClick && inside { openIsland(reason: "click") }
            } else if let since = insideSince, tickNow.timeIntervalSince(since) >= openDelay {
                openIsland(reason: "hover")
            }
        } else if !model.isPinned {
            if let since = outsideSince, tickNow.timeIntervalSince(since) >= closeDelay {
                note("closing (pointer left)")
                model.isOpen = false
            }
        }

        // A fresh left-click outside the island dismisses it, even when pinned.
        if freshClick && !inside && model.isOpen && model.settings.clickOutsideCloses {
            note("click outside → dismiss")
            model.dismiss()
        }
    }

    private func openIsland(reason: String) {
        note("opening (\(reason))")
        model.tab = model.settings.tabToOpen(lastTab: model.tab)
        if model.settings.clickToOpen { model.isPinned = true } // a click-opened island stays until dismissed
        model.isOpen = true
    }

    /// Where the pointer counts as "on the island".
    /// - Closed: a wide hot zone across the top-center of the screen, much bigger than the notch itself.
    /// - Open: the whole expanded panel plus a forgiving margin, so it doesn't close if you drift slightly.
    private func activeZone(on screen: NSScreen) -> NSRect {
        if model.isOpen {
            return islandFrame(on: screen).insetBy(dx: -12, dy: -12)
        }
        let height = model.notchSize.height
        let width = model.notchSize.width + 2 * hotZoneSidePadding
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height - 6,
            width: width,
            height: height + 10   // extends a few points above the screen edge
        )
    }

    func debugInfo() -> String {
        let screen = targetScreen
        let zone = screen.map { activeZone(on: $0) }
        let events = log.isEmpty ? "(none yet)" : log.joined(separator: "\n")
        return """
        Build: v22 (tappable now playing)
        Poll ticks: \(pollTicks)   Slow ticks (>0.25s gap): \(slowTicks)   Longest gap: \(String(format: "%.2f", maxGap))s
        Open: \(model.isOpen)   Pinned: \(model.isPinned)   Island shown open: \(island?.isShownOpen ?? false)
        Panel: visible=\(panel.isVisible) onScreen=\(panel.occlusionState.contains(.visible)) level=\(panel.level.rawValue) ignoresMouse=\(panel.ignoresMouseEvents)
        Panel frame: \(panel.frame)
        Log file: \(logURL.path)
        Notch size: \(model.notchSize)
        Screen frame: \(screen?.frame ?? .zero)
        Active hover zone: \(zone.map { "\($0)" } ?? "none")
        Mouse now: \(NSEvent.mouseLocation)

        Recent events:
        \(events)
        """
    }

    // MARK: Geometry

    private var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchSize(for screen: NSScreen) -> CGSize {
        var width: CGFloat = 190   // fallback "virtual" notch for Macs without one
        var height: CGFloat = 32
        if screen.safeAreaInsets.top > 0 {
            height = screen.safeAreaInsets.top
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = screen.frame.width - left.width - right.width
            }
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            if menuBar > 0 { height = menuBar }
        }
        return CGSize(width: width, height: height)
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let size = model.openSize
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The visible part of the open island (it can be shorter than the panel).
    private func islandFrame(on screen: NSScreen) -> NSRect {
        let width = model.openSize.width
        let height = model.islandHeight
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func positionPanel() {
        guard let screen = targetScreen else { return }
        panel.setFrame(panelFrame(on: screen), display: true)
    }
}
