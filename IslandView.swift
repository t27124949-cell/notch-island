import AppKit
import Combine
import QuartzCore

/// The black island shape, drawn by a CAShapeLayer so Core Animation can morph it between the closed
/// pill and the open panel. Purely visual: it never takes mouse events.
final class ShapeView: NSView {
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }

    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shapeLayer.fillColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The whole island, built from plain AppKit views (no SwiftUI). The panel that hosts it is always the
/// full open size; when closed the panel ignores mouse events, so it never blocks the menu bar.
final class IslandView: NSView {
    private let model: NotchModel
    private let shapeView: ShapeView
    private let content = NSView()
    private let pinButton = ClosureButton(frame: .zero)
    private var tabButtons: [NotchTab: ClosureButton] = [:]
    private var tabViews: [NotchTab: TabContentView] = [:]
    private var currentTab: NotchTab?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isShownOpen = false
    private var lastOpenHeight: CGFloat = 0

    init(model: NotchModel) {
        self.model = model
        self.shapeView = ShapeView(frame: NSRect(origin: .zero, size: model.openSize))
        super.init(frame: NSRect(origin: .zero, size: model.openSize))

        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        registerForDraggedTypes([.fileURL])

        addSubview(shapeView)
        content.alphaValue = 0
        content.isHidden = true
        addSubview(content)

        buildTabBar()
        buildTabs()
        buildPeek()
        buildAmbient()
        layoutContents()
        applyShape(.closed, animated: false)
        refreshAmbient(animated: false)
        showTab(model.tab)

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshChrome()
                self?.refreshAmbient()
            }
            .store(in: &cancellables)

        model.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.layoutContents()
                self?.refreshAmbient()
            }
            .store(in: &cancellables)

        model.$notchSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.layoutContents()
                self.applyShape(self.shapeMode, animated: false)
                self.layoutAmbient()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Building

    private func buildTabBar() {
        for tab in NotchTab.allCases {
            let button = ClosureButton.icon(UI.symbol(tab.symbol, size: 13)) { [weak self] in
                self?.model.tab = tab
            }
            button.toolTip = tab.title
            content.addSubview(button)
            tabButtons[tab] = button
        }
        pinButton.handler = { [weak self] in self?.model.togglePin() }
        pinButton.toolTip = "Keep open"
        content.addSubview(pinButton)
    }

    private func buildTabs() {
        let views: [NotchTab: TabContentView] = [
            .home: HomeTabView(settings: model.settings),
            .controls: ControlsTabView(store: model.controls),
            .apps: AppsTabView(store: model.apps),
            .launcher: LauncherTabView(store: model.launcher),
            .nowPlaying: NowPlayingTabView(store: model.nowPlaying, settings: model.settings),
            .calendar: CalendarTabView(store: model.calendar),
            .weather: WeatherTabView(store: model.weather),
            .shelf: ShelfTabView(model: model),
            .timer: TimerTabView(timer: model.timer),
            .clipboard: ClipboardTabView(store: model.clipboard),
            .notes: NotesTabView(),
            .stats: StatsTabView(store: model.stats),
            .settings: SettingsTabView(model: model),
        ]
        for (tab, view) in views {
            view.isHidden = true
            view.requestPin = { [weak self] in self?.model.isPinned = true }
            view.requestDismiss = { [weak self] in self?.model.dismiss() }
            view.holdOpen = { [weak self] body in
                guard let self else { return body() }
                let wasPinned = self.model.isPinned
                self.model.isPinned = true
                body()
                self.model.isPinned = wasPinned
            }
            content.addSubview(view)
            tabViews[tab] = view
        }
    }

    // MARK: Layout

    private func layoutContents() {
        let size = model.openSize
        let notchH = model.notchSize.height
        content.frame = NSRect(origin: .zero, size: size)
        shapeView.frame = NSRect(origin: .zero, size: size)

        let buttonW: CGFloat = 26
        let buttonH: CGFloat = 24
        let gap: CGFloat = 2
        let pad: CGFloat = 24
        // This view is not flipped, so y counts up from the bottom; the notch row is at the very top.
        let rowY = size.height - notchH + (notchH - buttonH) / 2

        let enabled = NotchTab.allCases.filter { model.settings.isEnabled($0) }
        let leftCount = min(7, (enabled.count + 2) / 2)
        let left = Array(enabled.prefix(leftCount))
        let right = Array(enabled.dropFirst(leftCount))

        for (tab, button) in tabButtons { button.isHidden = !enabled.contains(tab) }
        for (index, tab) in left.enumerated() {
            let x = pad + CGFloat(index) * (buttonW + gap)
            tabButtons[tab]?.frame = NSRect(x: x, y: rowY, width: buttonW, height: buttonH)
        }
        // Right-hand tabs sit just left of the pin button, in tab-bar order.
        for (index, tab) in right.enumerated() {
            let x = size.width - pad - buttonW - CGFloat(right.count - index) * (buttonW + gap)
            tabButtons[tab]?.frame = NSRect(x: x, y: rowY, width: buttonW, height: buttonH)
        }
        pinButton.frame = NSRect(x: size.width - pad - buttonW, y: rowY, width: buttonW, height: buttonH)

        // Each tab has its own island height; the island hangs from the top of the panel.
        for (tab, view) in tabViews {
            let islandH = NotchModel.openHeight(for: tab)
            let bottom = size.height - islandH
            view.frame = NSRect(x: 32, y: bottom + 22, width: size.width - 64, height: islandH - notchH - 30)
            view.layoutContents()
        }
    }

    // MARK: Shape

    private enum ShapeMode { case closed, ambient, peek, open }
    private var shapeMode: ShapeMode = .closed
    private let ambientSlot: CGFloat = 30   // room on each side of the notch for the ambient icons

    private let peekWidth: CGFloat = 420
    private var peekHeight: CGFloat { model.notchSize.height + 30 }

    private func shapePath(_ mode: ShapeMode) -> CGPath {
        let bounds = CGRect(origin: .zero, size: model.openSize)
        let width: CGFloat, height: CGFloat, tr: CGFloat, br: CGFloat
        switch mode {
        case .closed:
            width = model.notchSize.width + 12; height = model.notchSize.height; tr = 6; br = 12
        case .ambient:
            width = model.notchSize.width + 12 + 2 * ambientSlot; height = model.notchSize.height; tr = 6; br = 12
        case .peek:
            width = peekWidth; height = peekHeight; tr = 8; br = 18
        case .open:
            width = model.openSize.width; height = model.islandHeight; tr = 14; br = 28
        }
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2
        let top = bounds.maxY
        let bottom = top - height

        let p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: top))
        p.addQuadCurve(to: CGPoint(x: left + tr, y: top - tr), control: CGPoint(x: left + tr, y: top))
        p.addLine(to: CGPoint(x: left + tr, y: bottom + br))
        p.addQuadCurve(to: CGPoint(x: left + tr + br, y: bottom), control: CGPoint(x: left + tr, y: bottom))
        p.addLine(to: CGPoint(x: right - tr - br, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right - tr, y: bottom + br), control: CGPoint(x: right - tr, y: bottom))
        p.addLine(to: CGPoint(x: right - tr, y: top - tr))
        p.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: right - tr, y: top))
        p.closeSubpath()
        return p
    }

    private func applyShape(_ mode: ShapeMode, animated: Bool) {
        shapeMode = mode
        let layer = shapeView.shapeLayer
        let newPath = shapePath(mode)
        if animated {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = layer.presentation()?.path ?? layer.path
            animation.toValue = newPath
            animation.duration = mode == .open ? 0.38 : (mode == .peek ? 0.3 : 0.28)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            layer.add(animation, forKey: "path")
        }
        layer.path = newPath
    }

    // MARK: Ambient (always-on, closed notch)

    private enum AmbientKind { case none, music, battery }

    private let ambientView = NSView()
    private let ambientIcon = NSImageView()
    private let ambientText = UI.label("", size: 10, weight: .semibold, alignment: .right)
    private let equalizer = EqualizerView(frame: NSRect(x: 0, y: 0, width: 14, height: 12))

    private var ambientKind: AmbientKind {
        if model.settings.ambientMusic, model.ambientTrack != nil { return .music }
        if model.settings.ambientBattery, model.batteryLevel != nil { return .battery }
        return .none
    }

    private var closedMode: ShapeMode { ambientKind == .none ? .closed : .ambient }

    private func buildAmbient() {
        ambientView.alphaValue = 0
        ambientView.isHidden = true
        ambientIcon.imageScaling = .scaleProportionallyUpOrDown
        ambientIcon.wantsLayer = true
        ambientIcon.layer?.cornerRadius = 4
        ambientIcon.layer?.masksToBounds = true
        for view in [ambientIcon, ambientText, equalizer] as [NSView] { ambientView.addSubview(view) }
        addSubview(ambientView, positioned: .above, relativeTo: content)
        layoutAmbient()
    }

    private func layoutAmbient() {
        let size = model.openSize
        let width = model.notchSize.width + 12 + 2 * ambientSlot
        let height = model.notchSize.height
        ambientView.frame = NSRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
        let iconSize: CGFloat = 16
        ambientIcon.frame = NSRect(x: 10, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        equalizer.frame = NSRect(x: width - 10 - 14, y: (height - 12) / 2, width: 14, height: 12)
        ambientText.frame = NSRect(x: width - 8 - 30, y: (height - 14) / 2, width: 30, height: 14)
    }

    private func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// Update the ambient icons and, when the island is closed, morph the pill to match.
    private func refreshAmbient(animated: Bool = true) {
        let kind = ambientKind
        switch kind {
        case .music:
            if let artwork = model.ambientArtwork {
                ambientIcon.image = artwork
                ambientIcon.contentTintColor = nil
            } else {
                ambientIcon.image = UI.symbol("music.note", size: 12)
                ambientIcon.contentTintColor = .systemPink
            }
            ambientText.isHidden = true
            equalizer.isHidden = false
            equalizer.start()
        case .battery:
            let level = model.batteryLevel ?? 0
            let charging = model.batteryCharging
            ambientIcon.image = UI.symbol(batterySymbol(level: level, charging: charging), size: 12)
            ambientIcon.contentTintColor = charging ? .systemGreen : (level <= 20 ? .systemRed : .white)
            ambientText.stringValue = "\(level)%"
            ambientText.textColor = charging ? .systemGreen : (level <= 20 ? .systemRed : .white)
            ambientText.isHidden = false
            equalizer.stop()
            equalizer.isHidden = true
        case .none:
            equalizer.stop()
        }
        syncAmbientVisibility(animated: animated)
        guard !isShownOpen, !isShownPeek else { return }
        if shapeMode != closedMode { applyShape(closedMode, animated: animated) }
    }

    private func syncAmbientVisibility(animated: Bool) {
        let visible = ambientKind != .none && !isShownOpen && !isShownPeek
        if visible { ambientView.isHidden = false }
        let target: CGFloat = visible ? 1 : 0
        guard ambientView.alphaValue != target else {
            if !visible { ambientView.isHidden = true }
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.ambientView.animator().alphaValue = target
            }, completionHandler: { [weak self] in
                guard let self else { return }
                if self.ambientView.alphaValue == 0 { self.ambientView.isHidden = true }
            })
        } else {
            ambientView.alphaValue = target
            ambientView.isHidden = !visible
        }
    }

    // MARK: Peek (live activities)

    private let peekView = NSView()
    private let peekIcon = NSImageView()
    private let peekTitle = UI.label("", size: 12, weight: .semibold)
    private let peekSubtitle = UI.label("", size: 12, color: UI.dim(0.65), alignment: .right)
    private(set) var isShownPeek = false

    private func buildPeek() {
        peekView.alphaValue = 0
        peekView.isHidden = true
        peekIcon.imageScaling = .scaleProportionallyUpOrDown
        for view in [peekIcon, peekTitle, peekSubtitle] as [NSView] { peekView.addSubview(view) }
        addSubview(peekView, positioned: .above, relativeTo: content)
        layoutPeek()
    }

    private func layoutPeek() {
        let size = model.openSize
        let inner = peekWidth - 40
        peekView.frame = NSRect(x: (size.width - peekWidth) / 2 + 20, y: size.height - peekHeight + 5,
                                width: inner, height: 22)
        peekIcon.frame = NSRect(x: 0, y: 2, width: 18, height: 18)
        let textWidth = inner - 26
        peekTitle.frame = NSRect(x: 26, y: 3, width: textWidth * 0.62, height: 16)
        peekSubtitle.frame = NSRect(x: 26 + textWidth * 0.62 + 6, y: 3, width: textWidth * 0.38 - 6, height: 16)
    }

    func showPeek(_ activity: Activity) {
        guard !isShownOpen else { return }
        peekIcon.image = UI.symbol(activity.symbol, size: 14)
        peekIcon.contentTintColor = activity.tint
        peekTitle.stringValue = activity.title
        peekSubtitle.stringValue = activity.subtitle
        layoutPeek()
        peekView.isHidden = false
        if !isShownPeek {
            isShownPeek = true
            applyShape(.peek, animated: true)
            syncAmbientVisibility(animated: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.peekView.animator().alphaValue = 1
        }
    }

    func hidePeek() {
        guard isShownPeek else { return }
        isShownPeek = false
        refreshAmbient(animated: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.peekView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShownPeek else { return }
            self.peekView.isHidden = true
        })
    }

    // MARK: Open / close

    func setOpen(_ open: Bool, animated: Bool = true) {
        guard open != isShownOpen else { return }
        isShownOpen = open
        if open && isShownPeek {
            isShownPeek = false
            peekView.alphaValue = 0
            peekView.isHidden = true
        }
        if open { lastOpenHeight = model.islandHeight }
        applyShape(open ? .open : closedMode, animated: animated)
        syncAmbientVisibility(animated: animated)

        if open {
            content.isHidden = false
            if currentTab != model.tab { showTab(model.tab) }
            if let tab = currentTab { tabViews[tab]?.activate() }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    self.content.animator().alphaValue = 1
                }
            } else {
                content.alphaValue = 1
            }
        } else {
            if let tab = currentTab { tabViews[tab]?.deactivate() }
            window?.makeFirstResponder(nil)
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.12
                    self.content.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self, !self.isShownOpen else { return }
                    self.content.isHidden = true
                })
            } else {
                content.alphaValue = 0
                content.isHidden = true
            }
        }
        refreshChrome()
    }

    private func showTab(_ tab: NotchTab) {
        if let current = currentTab, current != tab {
            tabViews[current]?.deactivate()
            tabViews[current]?.isHidden = true
        }
        currentTab = tab
        tabViews[tab]?.isHidden = false
        if isShownOpen { tabViews[tab]?.activate() }
        refreshChrome()
    }

    /// Update tab highlights and the pin icon from the model.
    private func refreshChrome() {
        if currentTab != model.tab { showTab(model.tab) }
        if isShownOpen, lastOpenHeight != model.islandHeight {
            lastOpenHeight = model.islandHeight
            applyShape(.open, animated: true)   // glide to the new tab's height
        }
        for (tab, button) in tabButtons {
            let selected = tab == model.tab
            button.setFill(selected ? UI.dim(0.18) : nil, radius: 8)
            button.contentTintColor = selected ? .white : UI.dim(0.55)
        }
        pinButton.image = UI.symbol(model.isPinned ? "pin.fill" : "pin", size: 12)
        pinButton.contentTintColor = model.isPinned ? .systemYellow : UI.dim(0.55)
    }

    // MARK: Dropping files onto the island

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        if !model.isOpen { model.isOpen = true }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        model.addToShelf(urls)
        model.tab = .shelf
        return true
    }
}
