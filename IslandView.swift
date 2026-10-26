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
        layoutContents()
        applyShape(open: false, animated: false)
        showTab(model.tab)

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
            .store(in: &cancellables)

        model.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutContents() }
            .store(in: &cancellables)

        model.$notchSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.layoutContents()
                self.applyShape(open: self.isShownOpen, animated: false)
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

        let tabRect = NSRect(x: 32, y: 22, width: size.width - 64, height: size.height - notchH - 30)
        for view in tabViews.values {
            view.frame = tabRect
            view.layoutContents()
        }
    }

    // MARK: Shape

    private func shapePath(open: Bool) -> CGPath {
        let bounds = CGRect(origin: .zero, size: model.openSize)
        let width = open ? model.openSize.width : model.notchSize.width + 12
        let height = open ? model.openSize.height : model.notchSize.height
        let tr: CGFloat = open ? 14 : 6      // flare at the top corners
        let br: CGFloat = open ? 28 : 12     // rounding at the bottom corners
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

    private func applyShape(open: Bool, animated: Bool) {
        let layer = shapeView.shapeLayer
        let newPath = shapePath(open: open)
        if animated {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = layer.presentation()?.path ?? layer.path
            animation.toValue = newPath
            animation.duration = open ? 0.38 : 0.28
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            layer.add(animation, forKey: "path")
        }
        layer.path = newPath
    }

    // MARK: Open / close

    func setOpen(_ open: Bool, animated: Bool = true) {
        guard open != isShownOpen else { return }
        isShownOpen = open
        applyShape(open: open, animated: animated)

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
