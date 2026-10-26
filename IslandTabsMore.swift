import AppKit
import Combine

extension UI {
    static func openSystemSettings(_ identifier: String) {
        if let url = URL(string: "x-apple.systempreferences:\(identifier)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Shared widgets

/// A small on/off switch drawn by hand, so it looks the same whether or not the panel is the key window.
final class PillSwitch: ClickableView {
    var isOn = false {
        didSet { needsDisplay = true }
    }
    var onChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onClick = { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? NSColor.systemGreen : UI.dim(0.22)).setFill()
        track.fill()
        let diameter = bounds.height - 4
        let x = isOn ? bounds.width - diameter - 2 : 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: diameter, height: diameter)).fill()
    }
}

final class ToggleTile: ClickableView {
    private let iconView = NSImageView()
    private let titleLabel = UI.label("", size: 12, weight: .semibold)
    private let stateLabel = UI.label("", size: 11)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(stateLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func configure(title: String, symbol: String, on: Bool, state: String) {
        layer?.backgroundColor = (on ? NSColor.white.withAlphaComponent(0.92) : UI.dim(0.1)).cgColor
        let textColor: NSColor = on ? .black : .white
        iconView.image = UI.symbol(symbol, size: 16)
        iconView.contentTintColor = textColor
        titleLabel.stringValue = title
        titleLabel.textColor = textColor
        stateLabel.stringValue = state
        stateLabel.textColor = on ? NSColor.black.withAlphaComponent(0.6) : UI.dim(0.6)
        iconView.frame = NSRect(x: 12, y: 12, width: 22, height: 22)
        titleLabel.frame = NSRect(x: 42, y: 11, width: max(bounds.width - 50, 10), height: 16)
        stateLabel.frame = NSRect(x: 42, y: 29, width: max(bounds.width - 50, 10), height: 14)
    }
}

final class BarView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        UI.dim(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let width = max(bounds.height, bounds.width * clamped)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

final class SparklineView: NSView {
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .systemGreen

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let path = NSBezierPath()
        let step = bounds.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let clamped = CGFloat(min(max(value, 0), 1))
            let point = NSPoint(x: CGFloat(index) * step, y: clamped * (bounds.height - 2) + 1)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// Search field that tells the island to stay open while you type.
final class PinningSearchField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// Text view with a placeholder that tells the island to stay open while you type.
final class PinningTextView: NSTextView {
    var onFocus: (() -> Void)?
    var placeholder = ""

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: UI.dim(0.35),
        ]
        let padding = textContainer?.lineFragmentPadding ?? 5
        let point = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        (placeholder as NSString).draw(at: point, withAttributes: attributes)
    }
}

// MARK: - Controls

final class ControlsTabView: TabContentView {
    private let store: ControlsStore
    private let muteButton: ClosureButton
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeLabel = UI.label("", size: 12, color: UI.dim(), alignment: .right)
    private let wifiTile = ToggleTile(frame: .zero)
    private let darkTile = ToggleTile(frame: .zero)
    private let awakeTile = ToggleTile(frame: .zero)
    private let sleepTile = ToggleTile(frame: .zero)
    private let focusTile = ToggleTile(frame: .zero)
    private var menuHandler = MenuHandler()
    private let shortcutsHeader = UI.label("Open in System Settings", size: 11, weight: .semibold, color: UI.dim(0.5))
    private var shortcutButtons: [ClosureButton] = []
    private var cancellable: AnyCancellable?

    init(store: ControlsStore) {
        self.store = store
        muteButton = ClosureButton.icon(UI.symbol("speaker.wave.2.fill", size: 14)) { [weak store] in
            store?.toggleMute()
        }
        super.init(frame: .zero)

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true

        wifiTile.onClick = { [weak store] in store?.toggleWifi() }
        darkTile.onClick = { [weak store] in store?.toggleDarkMode() }
        awakeTile.onClick = { [weak store] in store?.toggleKeepAwake() }
        sleepTile.onClick = { [weak store] in store?.sleepDisplay() }
        focusTile.onClick = { [weak self] in self?.showFocusMenu() }

        let shortcuts: [(String, String)] = [
            ("Wi-Fi", "com.apple.wifi-settings-extension"),
            ("Bluetooth", "com.apple.BluetoothSettings"),
            ("Sound", "com.apple.Sound-Settings.extension"),
            ("Displays", "com.apple.Displays-Settings.extension"),
            ("Focus", "com.apple.Focus-Settings.extension"),
            ("Battery", "com.apple.Battery-Settings.extension"),
        ]
        for (title, identifier) in shortcuts {
            let button = ClosureButton.pill(title, size: 11, fill: UI.dim(0.1), height: 24) {
                UI.openSystemSettings(identifier)
            }
            shortcutButtons.append(button)
        }

        let shortcutsApp = ClosureButton.pill("Shortcuts app", size: 11, fill: UI.dim(0.1), height: 24) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        }
        shortcutButtons.append(shortcutsApp)

        for view in [muteButton, slider, volumeLabel, wifiTile, darkTile, awakeTile, sleepTile, focusTile, shortcutsHeader] as [NSView] {
            addSubview(view)
        }
        for button in shortcutButtons { addSubview(button) }

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderChanged() {
        store.setVolume(slider.doubleValue)
    }

    override func layoutContents() {
        let w = bounds.width
        muteButton.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        slider.frame = NSRect(x: 40, y: 3, width: w - 40 - 60, height: 22)
        volumeLabel.frame = NSRect(x: w - 50, y: 5, width: 50, height: 18)

        let tileWidth = (w - 4 * 8) / 5
        for (index, tile) in [focusTile, wifiTile, darkTile, awakeTile, sleepTile].enumerated() {
            tile.frame = NSRect(x: CGFloat(index) * (tileWidth + 8), y: 40, width: tileWidth, height: 56)
        }

        shortcutsHeader.frame = NSRect(x: 0, y: 112, width: w, height: 14)
        var x: CGFloat = 0
        for button in shortcutButtons {
            button.frame.origin = NSPoint(x: x, y: 132)
            x += button.frame.width + 8
        }
        update()
    }

    override func activate() { store.refresh() }

    private func showFocusMenu() {
        let handler = MenuHandler()
        menuHandler = handler
        let menu = NSMenu()
        for mode in store.focusModes {
            let item = handler.item(mode) { [weak self] in self?.store.setFocus(mode) }
            item.state = store.focusCurrent == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let off = handler.item("Off") { [weak self] in self?.store.setFocus("Off") }
        off.state = store.focusCurrent == "Off" ? .on : .off
        menu.addItem(off)
        let show: () -> Void = { _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.focusTile.bounds.height + 2), in: self.focusTile) }
        if let holdOpen { holdOpen(show) } else { show() }
    }

    private func update() {
        let focusOn = store.focusCurrent != "Off"
        focusTile.configure(title: "Focus", symbol: focusOn ? "moon.circle.fill" : "moon.circle", on: focusOn,
                            state: store.focusStatus.isEmpty ? store.focusCurrent : store.focusStatus)
        focusTile.toolTip = "Runs the Shortcut “Focus <name>” (see the README). Create one per Focus with the “Set Focus” action."
        let silent = store.muted || store.volume < 1
        muteButton.image = UI.symbol(silent ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 14)
        slider.doubleValue = store.volume
        slider.isEnabled = store.volumeAvailable
        volumeLabel.stringValue = store.volumeAvailable ? "\(Int(store.volume.rounded()))%" : "—"

        let wifiState: String
        switch store.wifiOn {
        case .some(true): wifiState = "On"
        case .some(false): wifiState = "Off"
        case .none: wifiState = "Unavailable"
        }
        wifiTile.configure(title: "Wi-Fi", symbol: "wifi", on: store.wifiOn == true, state: wifiState)
        darkTile.configure(title: "Dark Mode", symbol: "moon.fill", on: store.darkMode,
                           state: store.darkMode ? "On" : "Off")
        awakeTile.configure(title: "Keep Awake", symbol: "cup.and.saucer.fill", on: store.keepAwake,
                            state: store.keepAwake ? "On" : "Off")
        sleepTile.configure(title: "Sleep Display", symbol: "display", on: false, state: "Click to sleep")
    }
}

// MARK: - Weather

final class DayColumnView: NSView {
    private let dayLabel = UI.label("", size: 11, weight: .semibold, color: UI.dim(0.6), alignment: .center)
    private let iconView = NSImageView()
    private let highLabel = UI.label("", size: 13, weight: .semibold, alignment: .center)
    private let lowLabel = UI.label("", size: 12, color: UI.dim(0.5), alignment: .center)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = UI.dim(0.06).cgColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        for view in [dayLabel, iconView, highLabel, lowLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func configure(day: String, symbol: String, high: String, low: String) {
        let w = bounds.width
        dayLabel.stringValue = day
        iconView.image = UI.symbol(symbol, size: 20, weight: .regular)
        iconView.contentTintColor = .white
        highLabel.stringValue = high
        lowLabel.stringValue = low
        dayLabel.frame = NSRect(x: 0, y: 8, width: w, height: 14)
        iconView.frame = NSRect(x: (w - 28) / 2, y: 30, width: 28, height: 28)
        highLabel.frame = NSRect(x: 0, y: 68, width: w, height: 16)
        lowLabel.frame = NSRect(x: 0, y: 88, width: w, height: 16)
    }
}

final class WeatherTabView: TabContentView, NSTextFieldDelegate {
    private let store: WeatherStore
    private let iconView = NSImageView()
    private let tempLabel = UI.label("", size: 44, weight: .semibold)
    private let descLabel = UI.label("", size: 14, weight: .medium)
    private let detailLabel = UI.label("", size: 12, color: UI.dim())
    private let placeLabel = UI.label("", size: 12, weight: .semibold, color: UI.dim(0.5))
    private let cityField = NSTextField()
    private let unitButton = ClosureButton(frame: .zero)
    private let refreshButton: ClosureButton
    private var dayViews: [DayColumnView] = []
    private var cancellable: AnyCancellable?

    init(store: WeatherStore) {
        self.store = store
        refreshButton = ClosureButton.icon(UI.symbol("arrow.clockwise", size: 12), tint: UI.dim(0.7)) { [weak store] in
            store?.refresh(force: true)
        }
        super.init(frame: .zero)

        tempLabel.font = UI.monoDigits(size: 44, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white

        cityField.placeholderString = "City"
        cityField.stringValue = store.city
        cityField.isBezeled = true
        cityField.bezelStyle = .roundedBezel
        cityField.focusRingType = .none
        cityField.font = NSFont.systemFont(ofSize: 12)
        cityField.delegate = self

        unitButton.handler = { [weak store] in store?.toggleUnit() }
        unitButton.setFill(UI.dim(0.12), radius: 12)

        for _ in 0..<5 {
            let column = DayColumnView(frame: NSRect(x: 0, y: 0, width: 58, height: 112))
            dayViews.append(column)
            addSubview(column)
        }
        for view in [iconView, tempLabel, descLabel, detailLabel, placeLabel, cityField, unitButton, refreshButton] as [NSView] {
            addSubview(view)
        }

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        let w = bounds.width
        iconView.frame = NSRect(x: 0, y: 6, width: 64, height: 64)
        tempLabel.frame = NSRect(x: 76, y: 0, width: 200, height: 54)
        descLabel.frame = NSRect(x: 76, y: 56, width: 220, height: 20)
        detailLabel.frame = NSRect(x: 76, y: 80, width: 240, height: 16)
        placeLabel.frame = NSRect(x: 0, y: 104, width: 300, height: 16)
        cityField.frame = NSRect(x: 0, y: 128, width: 150, height: 24)
        unitButton.frame = NSRect(x: 158, y: 128, width: 36, height: 24)
        refreshButton.frame = NSRect(x: 200, y: 128, width: 24, height: 24)
        for (index, column) in dayViews.enumerated() {
            column.frame = NSRect(x: w - CGFloat(5 - index) * 62 + 4, y: 8, width: 58, height: 112)
        }
        update()
    }

    override func activate() { store.refresh() }

    func controlTextDidBeginEditing(_ obj: Notification) { requestPin?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            store.setCity(cityField.stringValue)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func update() {
        unitButton.setText(store.fahrenheit ? "°F" : "°C", size: 12, color: .white)
        unitButton.setFill(UI.dim(0.12), radius: 12)
        if window?.firstResponder == nil || !(window?.firstResponder is NSTextView) {
            cityField.stringValue = store.city
        }
        placeLabel.stringValue = store.resolvedName

        switch store.state {
        case .idle, .loading:
            descLabel.stringValue = "Loading…"
            tempLabel.stringValue = "--°"
            detailLabel.stringValue = ""
            iconView.image = UI.symbol("cloud.fill", size: 40, weight: .regular)
            for column in dayViews { column.isHidden = true }
        case .failed(let message):
            descLabel.stringValue = message
            tempLabel.stringValue = "--°"
            detailLabel.stringValue = "Check the city name or your connection."
            iconView.image = UI.symbol("exclamationmark.triangle.fill", size: 36, weight: .regular)
            for column in dayViews { column.isHidden = true }
        case .loaded:
            let info = WeatherCode.info(store.code)
            iconView.image = UI.symbol(info.symbol, size: 44, weight: .regular)
            tempLabel.stringValue = store.format(store.temperature)
            descLabel.stringValue = info.text
            let windText = "\(Int(store.wind.rounded())) km/h"
            detailLabel.stringValue = "Feels \(store.format(store.feelsLike))  ·  \(store.humidity)%  ·  \(windText)"

            let weekday = DateFormatter()
            weekday.dateFormat = "EEE"
            for (index, column) in dayViews.enumerated() {
                if index < store.daily.count {
                    let day = store.daily[index]
                    column.isHidden = false
                    column.configure(day: index == 0 ? "Today" : weekday.string(from: day.date),
                                     symbol: WeatherCode.info(day.code).symbol,
                                     high: store.format(day.high), low: store.format(day.low))
                } else {
                    column.isHidden = true
                }
            }
        }
    }
}

// MARK: - System stats

final class StatCardView: NSView {
    let titleLabel = UI.label("", size: 11, weight: .semibold, color: UI.dim(0.55))
    let valueLabel = UI.label("", size: 22, weight: .semibold)
    let detailLabel = UI.label("", size: 11, color: UI.dim(0.6))
    let bar = BarView()
    let spark = SparklineView()

    init(title: String, showsBar: Bool, showsSparkline: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = UI.dim(0.08).cgColor
        titleLabel.stringValue = title
        valueLabel.font = UI.monoDigits(size: 22, weight: .semibold)
        bar.isHidden = !showsBar
        spark.isHidden = !showsSparkline
        for view in [titleLabel, valueLabel, detailLabel, bar, spark] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func layoutCard() {
        let w = bounds.width - 24
        titleLabel.frame = NSRect(x: 12, y: 10, width: w, height: 14)
        valueLabel.frame = NSRect(x: 12, y: 28, width: w, height: 28)
        detailLabel.frame = NSRect(x: 12, y: 60, width: w, height: 14)
        bar.frame = NSRect(x: 12, y: 88, width: w, height: 8)
        spark.frame = NSRect(x: 12, y: 84, width: w, height: 56)
    }
}

final class StatsTabView: TabContentView {
    private let store: StatsStore
    private let cpuCard = StatCardView(title: "CPU", showsBar: false, showsSparkline: true)
    private let memoryCard = StatCardView(title: "MEMORY", showsBar: true, showsSparkline: false)
    private let diskCard = StatCardView(title: "DISK", showsBar: true, showsSparkline: false)
    private let networkCard = StatCardView(title: "NETWORK", showsBar: false, showsSparkline: false)
    private var cancellable: AnyCancellable?

    init(store: StatsStore) {
        self.store = store
        super.init(frame: .zero)
        for card in [cpuCard, memoryCard, diskCard, networkCard] { addSubview(card) }
        memoryCard.bar.color = .systemPurple
        diskCard.bar.color = .systemOrange
        cpuCard.spark.color = .systemGreen
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        let cardWidth = (bounds.width - 3 * 8) / 4
        for (index, card) in [cpuCard, memoryCard, diskCard, networkCard].enumerated() {
            card.frame = NSRect(x: CGFloat(index) * (cardWidth + 8), y: 4, width: cardWidth, height: 150)
            card.layoutCard()
        }
        update()
    }

    override func activate() { store.start() }
    override func deactivate() { store.stop() }

    private func bytes(_ value: Double, style: ByteCountFormatter.CountStyle) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: style)
    }

    private func update() {
        cpuCard.valueLabel.stringValue = "\(Int((store.cpu * 100).rounded()))%"
        cpuCard.detailLabel.stringValue = "Last 40 seconds"
        cpuCard.spark.values = store.cpuHistory

        memoryCard.valueLabel.stringValue = bytes(store.memUsed, style: .memory)
        memoryCard.detailLabel.stringValue = "of \(bytes(store.memTotal, style: .memory)) used"
        memoryCard.bar.fraction = store.memTotal > 0 ? store.memUsed / store.memTotal : 0

        let diskUsed = max(store.diskTotal - store.diskFree, 0)
        diskCard.valueLabel.stringValue = bytes(store.diskFree, style: .file)
        diskCard.detailLabel.stringValue = "free of \(bytes(store.diskTotal, style: .file))"
        diskCard.bar.fraction = store.diskTotal > 0 ? diskUsed / store.diskTotal : 0

        networkCard.valueLabel.font = UI.monoDigits(size: 15, weight: .semibold)
        networkCard.valueLabel.stringValue = "↓ \(bytes(store.rxRate, style: .file))/s"
        networkCard.detailLabel.font = UI.monoDigits(size: 13, weight: .regular)
        networkCard.detailLabel.stringValue = "↑ \(bytes(store.txRate, style: .file))/s"
    }
}

// MARK: - Quick launcher

final class LauncherTileView: ClickableView {
    private let app: LauncherApp
    private let store: LauncherStore
    private var menuHandler = MenuHandler()

    init(app: LauncherApp, store: LauncherStore, onLaunch: @escaping () -> Void) {
        self.app = app
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 84))
        wantsLayer = true
        layer?.cornerRadius = 10

        let icon = NSImageView(frame: NSRect(x: 14, y: 8, width: 44, height: 44))
        icon.image = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let name = UI.label(app.name, size: 10, color: UI.dim(0.8), alignment: .center)
        name.frame = NSRect(x: 2, y: 58, width: 68, height: 14)
        addSubview(name)

        if store.isFavorite(app) {
            let star = NSImageView(frame: NSRect(x: 54, y: 4, width: 12, height: 12))
            star.image = UI.symbol("star.fill", size: 9, weight: .regular)
            star.contentTintColor = .systemYellow
            addSubview(star)
        }
        onClick = {
            store.launch(app)
            onLaunch()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let handler = MenuHandler()
        menuHandler = handler
        let store = self.store
        let app = self.app
        let menu = NSMenu()
        menu.addItem(handler.item("Open") { store.launch(app) })
        menu.addItem(handler.item(store.isFavorite(app) ? "Remove from favorites" : "Add to favorites") {
            store.toggleFavorite(app)
        })
        menu.addItem(handler.item("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        })
        return menu
    }
}

final class LauncherTabView: TabContentView, NSSearchFieldDelegate {
    private let store: LauncherStore
    private let field = PinningSearchField(frame: .zero)
    private let hint = UI.label("", size: 11, color: UI.dim(0.5))
    private let scroll = UI.scrollView(horizontal: true)
    private let doc = FlippedView()
    private var cancellable: AnyCancellable?

    init(store: LauncherStore) {
        self.store = store
        super.init(frame: .zero)
        field.placeholderString = "Search apps"
        field.delegate = self
        field.onFocus = { [weak self] in self?.requestPin?() }
        scroll.documentView = doc
        for view in [field, hint, scroll] as [NSView] { addSubview(view) }
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        hint.frame = NSRect(x: 0, y: 38, width: bounds.width, height: 16)
        scroll.frame = NSRect(x: 0, y: 58, width: bounds.width, height: bounds.height - 58)
        rebuild()
    }

    private var query: String {
        field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private var results: [LauncherApp] {
        query.isEmpty ? store.favoriteApps : store.search(query)
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let first = results.first {
                store.launch(first)
                requestDismiss?()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = ""
            window?.makeFirstResponder(nil)
            rebuild()
            return true
        }
        return false
    }

    private func rebuild() {
        let items = results
        if query.isEmpty {
            hint.stringValue = items.isEmpty
                ? "Type to search your apps. Right-click an app to add it to your favorites."
                : "Favorites"
        } else {
            hint.stringValue = items.isEmpty ? "No matching apps" : "Press Return to open the first result"
        }
        doc.subviews.forEach { $0.removeFromSuperview() }
        for (index, app) in items.enumerated() {
            let tile = LauncherTileView(app: app, store: store) { [weak self] in self?.requestDismiss?() }
            tile.frame.origin = NSPoint(x: CGFloat(index) * 76, y: 0)
            doc.addSubview(tile)
        }
        doc.frame = NSRect(x: 0, y: 0, width: max(CGFloat(items.count) * 76, scroll.bounds.width),
                           height: max(scroll.bounds.height, 84))
    }
}

// MARK: - Notes

final class NotesTabView: TabContentView, NSTextViewDelegate {
    private let header = UI.label("Notes", size: 12, weight: .semibold, color: UI.dim())
    private let copyButton = ClosureButton(frame: .zero)
    private let clearButton = ClosureButton(frame: .zero)
    private let scroll = NSScrollView()
    private let textView = PinningTextView(frame: .zero)

    init() {
        super.init(frame: .zero)

        copyButton.setText("Copy", size: 11, weight: .medium, color: UI.dim(0.6))
        copyButton.handler = { [weak self] in self?.copyAll() }
        clearButton.setText("Clear", size: 11, weight: .medium, color: UI.dim(0.6))
        clearButton.handler = { [weak self] in self?.clearAll() }

        textView.string = UserDefaults.standard.string(forKey: "notesText") ?? ""
        textView.placeholder = "Jot something down…"
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onFocus = { [weak self] in self?.requestPin?() }

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.backgroundColor = UI.dim(0.08).cgColor

        for view in [header, copyButton, clearButton, scroll] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        header.frame = NSRect(x: 0, y: 0, width: 200, height: 16)
        clearButton.frame = NSRect(x: bounds.width - 48, y: 0, width: 48, height: 16)
        copyButton.frame = NSRect(x: bounds.width - 100, y: 0, width: 48, height: 16)
        scroll.frame = NSRect(x: 0, y: 24, width: bounds.width, height: bounds.height - 24)
        let content = scroll.contentSize
        textView.frame = NSRect(x: 0, y: 0, width: content.width, height: content.height)
        textView.minSize = NSSize(width: 0, height: content.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: content.width, height: CGFloat.greatestFiniteMagnitude)
    }

    func textDidChange(_ notification: Notification) {
        UserDefaults.standard.set(textView.string, forKey: "notesText")
        textView.needsDisplay = true
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    private func clearAll() {
        textView.string = ""
        UserDefaults.standard.set("", forKey: "notesText")
        textView.needsDisplay = true
    }
}
