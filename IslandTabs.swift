import AppKit
import QuickLookThumbnailing
import Combine
import QuartzCore

// MARK: - Small UI helpers

enum UI {
    static func dim(_ alpha: CGFloat = 0.6) -> NSColor {
        NSColor.white.withAlphaComponent(alpha)
    }

    static func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .white, alignment: NSTextAlignment = .left,
                      lines: Int = 1) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.drawsBackground = false
        field.backgroundColor = .clear
        return field
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func monoDigits(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func scrollView(horizontal: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = horizontal
        scroll.hasVerticalScroller = !horizontal
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = horizontal ? .allowed : .none
        scroll.verticalScrollElasticity = horizontal ? .none : .allowed
        return scroll
    }
}

/// Top-left-origin container, handy for scroll-view document views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Base class for the seven tab pages. Laid out top-down.
class TabContentView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Set by the island: ask it to stay open (while typing) or to close (after launching something).
    var requestPin: (() -> Void)?
    var requestDismiss: (() -> Void)?
    /// Keeps the island open while `body` runs (used around pop-up menus, which run their own event loop).
    var holdOpen: ((() -> Void) -> Void)?

    /// Called after the frame is set: position children using `bounds`.
    func layoutContents() {}
    /// The tab became visible while the island is open / stopped being visible.
    func activate() {}
    func deactivate() {}
}

// MARK: - Buttons, clickable rows, menus

final class ClosureButton: NSButton {
    var handler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        wantsLayer = true
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setFill(_ color: NSColor?, radius: CGFloat) {
        layer?.backgroundColor = color?.cgColor
        layer?.cornerRadius = radius
    }

    func setText(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .semibold, color: NSColor = .white) {
        imagePosition = .noImage
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    static func icon(_ image: NSImage?, tint: NSColor = .white, handler: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(frame: .zero)
        button.image = image
        button.contentTintColor = tint
        button.handler = handler
        return button
    }

    static func pill(_ title: String, size: CGFloat = 12, fill: NSColor = NSColor.white.withAlphaComponent(0.15),
                     textColor: NSColor = .white, height: CGFloat = 26,
                     handler: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(frame: .zero)
        button.setText(title, size: size, color: textColor)
        button.setFill(fill, radius: height / 2)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width + 28
        button.frame = NSRect(x: 0, y: 0, width: ceil(width), height: height)
        button.handler = handler
        return button
    }
}

/// A view that reports clicks and swallows all mouse events itself (children are decoration only).
class ClickableView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        let point = convert(event.locationInWindow, from: nil)
        if pressed && bounds.contains(point) { onClick?() }
    }
}

/// Lets NSMenuItems run Swift closures. Keep a reference to it for as long as the menu is alive.
final class MenuHandler: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count - 1
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag]()
    }
}

// MARK: - Home

final class HomeTabView: TabContentView {
    private let timeLabel = UI.label("", size: 44, weight: .semibold)
    private let dateLabel = UI.label("", size: 13, weight: .medium, color: UI.dim())
    private let batteryIcon = NSImageView()
    private let batteryLabel = UI.label("", size: 20, weight: .semibold, alignment: .right)
    private let batteryState = UI.label("", size: 12, color: UI.dim(), alignment: .right)
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private var ticker: Timer?
    private let settings: SettingsStore
    private var lastUse24Hour: Bool?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(frame: .zero)
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        timeLabel.font = UI.monoDigits(size: 44, weight: .semibold)
        batteryLabel.font = UI.monoDigits(size: 20, weight: .semibold)
        batteryIcon.imageScaling = .scaleProportionallyUpOrDown
        for view in [timeLabel, dateLabel, batteryIcon, batteryLabel, batteryState] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        let w = bounds.width
        let y0 = (bounds.height - 74) / 2
        timeLabel.frame = NSRect(x: 0, y: y0, width: 320, height: 54)
        dateLabel.frame = NSRect(x: 0, y: y0 + 56, width: 320, height: 18)
        batteryIcon.frame = NSRect(x: w - 30, y: y0 + 9, width: 30, height: 24)
        batteryLabel.frame = NSRect(x: w - 30 - 8 - 90, y: y0 + 8, width: 90, height: 26)
        batteryState.frame = NSRect(x: w - 200, y: y0 + 40, width: 200, height: 16)
    }

    override func activate() {
        refresh()
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    override func deactivate() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        let now = Date()
        if lastUse24Hour != settings.use24Hour {
            lastUse24Hour = settings.use24Hour
            timeFormatter.setLocalizedDateFormatFromTemplate(settings.use24Hour ? "Hm" : "hmma")
        }
        timeLabel.stringValue = timeFormatter.string(from: now)
        dateLabel.stringValue = dateFormatter.string(from: now)
        if let battery = readBattery() {
            batteryIcon.isHidden = false
            batteryLabel.isHidden = false
            batteryState.isHidden = false
            batteryLabel.stringValue = "\(battery.level)%"
            let time = batteryTimeText(charging: battery.charging)
            if battery.charging {
                batteryState.stringValue = time.map { "Charging · \($0) to full" } ?? "Charging"
            } else {
                batteryState.stringValue = time.map { "On battery · \($0) left" } ?? "On battery"
            }
            batteryIcon.image = UI.symbol(battery.charging ? "battery.100.bolt" : "battery.75", size: 18, weight: .regular)
            batteryIcon.contentTintColor = (battery.level <= 20 && !battery.charging) ? .systemRed : .systemGreen
        } else {
            batteryIcon.isHidden = true
            batteryLabel.isHidden = true
            batteryState.isHidden = true
        }
    }
}

// MARK: - Open Apps

final class AppTileView: ClickableView {
    private let item: RunningApp
    private let store: AppsStore
    private var menuHandler = MenuHandler()

    init(item: RunningApp, store: AppsStore) {
        self.item = item
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 68, height: 84))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = item.isFrontmost ? UI.dim(0.16).cgColor : NSColor.clear.cgColor

        let icon = NSImageView(frame: NSRect(x: 12, y: 8, width: 44, height: 44))
        icon.image = item.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = item.isHidden ? 0.45 : 1
        addSubview(icon)

        let name = UI.label(item.name, size: 10, color: UI.dim(0.8), alignment: .center)
        name.frame = NSRect(x: 2, y: 58, width: 64, height: 14)
        addSubview(name)

        onClick = { store.activate(item) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let handler = MenuHandler()
        menuHandler = handler
        let store = self.store
        let item = self.item
        let menu = NSMenu()
        menu.addItem(handler.item("Switch to \(item.name)") { store.activate(item) })
        menu.addItem(handler.item(item.isHidden ? "Show" : "Hide") { store.toggleHidden(item) })
        menu.addItem(handler.item("Show in Finder") { store.reveal(item) })
        menu.addItem(.separator())
        menu.addItem(handler.item("Quit") { store.quit(item) })
        menu.addItem(handler.item("Force Quit") { store.forceQuit(item) })
        return menu
    }
}

final class AppsTabView: TabContentView {
    private let store: AppsStore
    private let header = UI.label("", size: 12, weight: .semibold, color: UI.dim())
    private let scroll = UI.scrollView(horizontal: true)
    private let doc = FlippedView()
    private var cancellable: AnyCancellable?

    init(store: AppsStore) {
        self.store = store
        super.init(frame: .zero)
        addSubview(header)
        scroll.documentView = doc
        addSubview(scroll)
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        scroll.frame = NSRect(x: 0, y: 24, width: bounds.width, height: bounds.height - 24)
        rebuild()
    }

    override func activate() { store.refresh() }

    private func rebuild() {
        let apps = store.apps
        header.stringValue = apps.count == 1 ? "1 app open" : "\(apps.count) apps open"
        doc.subviews.forEach { $0.removeFromSuperview() }
        for (index, app) in apps.enumerated() {
            let tile = AppTileView(item: app, store: store)
            tile.frame.origin = NSPoint(x: CGFloat(index) * 72, y: 0)
            doc.addSubview(tile)
        }
        let width = max(CGFloat(apps.count) * 72, scroll.bounds.width)
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.bounds.height, 84))
    }
}

// MARK: - Now Playing

/// Progress bar you can drag to jump around the song.
/// A slim, rounded progress bar (no knob until you drag it), like the Now Playing bar in Apple's apps.
final class ThickSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 6
        let bar = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        UI.dim(0.2).setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        let range = maxValue - minValue
        let fraction = range > 0 ? CGFloat((doubleValue - minValue) / range) : 0
        guard fraction > 0 else { return }
        var filled = bar
        filled.size.width = max(bar.width * min(fraction, 1), height)
        UI.dim(0.72).setFill()
        NSBezierPath(roundedRect: filled, xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard (controlView as? SeekSlider)?.isDragging == true else { return }
        let size: CGFloat = 12
        let circle = NSRect(x: knobRect.midX - size / 2, y: knobRect.midY - size / 2, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: circle).fill()
    }
}

final class SeekSlider: NSSlider {
    var isDragging = false

    override class var cellClass: AnyClass? {
        get { ThickSliderCell.self }
        set { super.cellClass = newValue }
    }
    var onDrag: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isContinuous = true
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() { onDrag?(doubleValue) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)   // returns when the mouse is released
        isDragging = false
        onSeek?(doubleValue)
    }
}

/// A transparent, clickable area with a hand cursor.
final class LinkOverlay: ClickableView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class NowPlayingTabView: TabContentView {
    private let store: NowPlayingStore
    private let settings: SettingsStore
    private let artwork = NSImageView()
    private let titleLabel = UI.label("", size: 17, weight: .bold)
    private let artistLabel = UI.label("", size: 14, color: UI.dim())
    private let albumLabel = UI.label("", size: 11, color: UI.dim(0.5))
    private let appBadge = NSImageView()
    private static var iconCache: [MusicSource: NSImage] = [:]
    // Invisible tap targets laid over the artwork and labels.
    private let artworkLink = LinkOverlay()
    private let titleLink = LinkOverlay()
    private let artistLink = LinkOverlay()
    private let albumLink = LinkOverlay()
    private let messageLabel = UI.label("", size: 11, color: UI.dim(), lines: 3)
    private let lyricsView = LyricsView(frame: .zero)
    private let controls: ControlsStore
    private let volumeSlider = SeekSlider(frame: .zero)
    private let volumeLow = NSImageView()
    private let volumeHigh = NSImageView()
    private let outputButton = ClosureButton.icon(UI.symbol("airplayaudio", size: 11)) {}
    private var outputMenuHandler = MenuHandler()
    private var lastVolumeSend = Date.distantPast
    private let syncView = LyricsSyncView(frame: .zero)
    private let syncPill = ClosureButton(frame: .zero)
    private var syncing = false
    private var syncTitle = ""
    private let seekSlider = SeekSlider(frame: .zero)
    private let elapsedLabel = UI.label("0:00", size: 10, color: UI.dim(0.6), alignment: .left)
    private let remainingLabel = UI.label("0:00", size: 10, color: UI.dim(0.6), alignment: .right)
    private let previousButton: ClosureButton
    private let playButton: ClosureButton
    private let nextButton: ClosureButton
    private let settingsButton: ClosureButton
    private var cancellables = Set<AnyCancellable>()
    private var lyricsTimer: Timer?

    /// Width of the player column; the rest of the tab is lyrics.
    private let playerColumn: CGFloat = 316

    init(store: NowPlayingStore, settings: SettingsStore, controls: ControlsStore) {
        self.store = store
        self.settings = settings
        self.controls = controls
        previousButton = ClosureButton.icon(UI.symbol("backward.fill", size: 18)) { [weak store] in store?.previous() }
        playButton = ClosureButton.icon(UI.symbol("play.fill", size: 26)) { [weak store] in store?.playPause() }
        nextButton = ClosureButton.icon(UI.symbol("forward.fill", size: 18)) { [weak store] in store?.next() }
        settingsButton = ClosureButton.pill("Open Settings") { UI.openSettings("Privacy_Automation") }
        super.init(frame: .zero)

        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 16
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = UI.dim(0.1).cgColor

        appBadge.imageScaling = .scaleProportionallyUpOrDown
        appBadge.wantsLayer = true
        appBadge.layer?.shadowColor = NSColor.black.cgColor
        appBadge.layer?.shadowOpacity = 0.5
        appBadge.layer?.shadowRadius = 4
        appBadge.layer?.shadowOffset = CGSize(width: 0, height: -2)

        artworkLink.toolTip = "Open in the player"
        titleLink.toolTip = "Open in the player"
        artistLink.toolTip = "Search this artist"
        albumLink.toolTip = "Search this album"
        artworkLink.onClick = { [weak self] in self?.store.openInPlayer(); self?.requestDismiss?() }
        titleLink.onClick = { [weak self] in self?.store.openInPlayer(); self?.requestDismiss?() }
        artistLink.onClick = { [weak self] in
            guard let artist = self?.store.track?.artist, !artist.isEmpty else { return }
            self?.store.search(artist)
            self?.requestDismiss?()
        }
        albumLink.onClick = { [weak self] in
            guard let track = self?.store.track, !track.album.isEmpty else { return }
            self?.store.search("\(track.album) \(track.artist)")
            self?.requestDismiss?()
        }

        for view in [artwork, appBadge, titleLabel, artistLabel, albumLabel, artworkLink, titleLink, artistLink, albumLink, messageLabel, lyricsView,
                     seekSlider, elapsedLabel, remainingLabel, volumeSlider, volumeLow, volumeHigh, outputButton, syncView, syncPill,
                     previousButton, playButton, nextButton, settingsButton] as [NSView] {
            addSubview(view)
        }
        elapsedLabel.font = UI.monoDigits(size: 10, weight: .regular)
        remainingLabel.font = UI.monoDigits(size: 10, weight: .regular)
        seekSlider.minValue = 0
        seekSlider.onDrag = { [weak self] value in
            guard let self else { return }
            self.elapsedLabel.stringValue = Self.format(value)
            self.remainingLabel.stringValue = Self.format(self.seekSlider.maxValue)
            if self.showingLyrics {
                self.lyricsView.setPosition(value)
                self.lyricsView.updatePlain(position: value, duration: self.seekSlider.maxValue)
            }
        }
        seekSlider.onSeek = { [weak store] value in store?.seek(to: value) }

        // Volume
        volumeLow.image = UI.symbol("speaker.fill", size: 9, weight: .regular)
        volumeHigh.image = UI.symbol("speaker.wave.3.fill", size: 9, weight: .regular)
        volumeLow.contentTintColor = UI.dim(0.55)
        volumeHigh.contentTintColor = UI.dim(0.55)
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.onDrag = { [weak self] value in
            guard let self, Date().timeIntervalSince(self.lastVolumeSend) > 0.12 else { return }
            self.lastVolumeSend = Date()
            self.controls.setVolume(value)
        }
        volumeSlider.onSeek = { [weak self] value in self?.controls.setVolume(value) }
        outputButton.toolTip = "Sound output"
        outputButton.handler = { [weak self] in self?.showOutputMenu() }
        controls.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.volumeSlider.isDragging else { return }
                self.volumeSlider.doubleValue = self.controls.volume
                self.update()
            }
            .store(in: &cancellables)

        // Tap to sync
        syncView.isHidden = true
        syncView.position = { [weak store] in store?.currentPosition() ?? 0 }
        syncView.onFinish = { [weak self] lines in
            self?.syncing = false
            self?.store.saveUserSynced(lines)
            self?.update()
        }
        syncView.onCancel = { [weak self] in
            self?.syncing = false
            self?.update()
        }
        syncPill.handler = { [weak self] in self?.startSync() }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var showingLyrics: Bool { settings.showLyrics && store.track != nil }
    private var showingSeek: Bool { (store.track?.duration ?? 0) > 0 }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Move the progress bar and time labels to the current playback position.
    private func updateSeek(_ position: Double) {
        guard showingSeek, let duration = store.track?.duration else { return }
        let clamped = min(max(position, 0), duration)
        if !seekSlider.isDragging {
            seekSlider.maxValue = duration
            seekSlider.doubleValue = clamped
            elapsedLabel.stringValue = Self.format(clamped)
            remainingLabel.stringValue = Self.format(duration)
        }
    }

    override func layoutContents() {
        let columnW = showingLyrics ? playerColumn : bounds.width
        let art: CGFloat = 112
        let infoX = art + 18
        let infoW = max(columnW - infoX, 60)
        let block: CGFloat = showingSeek ? 144 : 122
        let top = max((bounds.height - block) / 2 + 4, 0)

        artwork.frame = NSRect(x: 0, y: top + 5, width: art, height: art)
        let badge: CGFloat = 32
        appBadge.frame = NSRect(x: art - badge + 8, y: top + 5 + art - badge + 8, width: badge, height: badge)

        titleLabel.frame = NSRect(x: infoX, y: top, width: infoW, height: 22)
        artistLabel.frame = NSRect(x: infoX, y: top + 23, width: infoW, height: 18)
        albumLabel.frame = NSRect(x: infoX, y: top + 41, width: infoW, height: 14)

        let seekY = top + 62
        seekSlider.frame = NSRect(x: infoX, y: seekY, width: infoW, height: 14)
        elapsedLabel.frame = NSRect(x: infoX, y: seekY + 15, width: 48, height: 12)
        remainingLabel.frame = NSRect(x: infoX + infoW - 48, y: seekY + 15, width: 48, height: 12)

        let controlsY = showingSeek ? top + 88 : top + 66
        let centerX = infoX + infoW / 2
        previousButton.frame = NSRect(x: centerX - 66, y: controlsY, width: 40, height: 34)
        playButton.frame = NSRect(x: centerX - 20, y: controlsY - 1, width: 40, height: 36)
        nextButton.frame = NSRect(x: centerX + 26, y: controlsY, width: 40, height: 34)

        artworkLink.frame = artwork.frame
        titleLink.frame = titleLabel.frame
        artistLink.frame = artistLabel.frame
        let volumeY = controlsY + 38
        volumeLow.frame = NSRect(x: infoX, y: volumeY + 1, width: 14, height: 12)
        volumeHigh.frame = NSRect(x: infoX + infoW - 38, y: volumeY + 1, width: 16, height: 12)
        outputButton.frame = NSRect(x: infoX + infoW - 18, y: volumeY - 2, width: 18, height: 18)
        volumeSlider.frame = NSRect(x: infoX + 20, y: volumeY, width: max(infoW - 62, 20), height: 14)
        albumLink.frame = albumLabel.frame
        messageLabel.frame = NSRect(x: infoX, y: top + 26, width: max(infoW - 10, 10), height: 44)
        settingsButton.frame.origin = NSPoint(x: infoX, y: top + 82)
        lyricsView.frame = NSRect(x: columnW + 16, y: 0, width: max(bounds.width - columnW - 16, 0), height: bounds.height)
        lyricsView.layoutAll()
        syncView.frame = lyricsView.frame
        syncView.layoutAll()
        syncPill.frame = NSRect(x: lyricsView.frame.minX, y: bounds.height - 14, width: lyricsView.frame.width, height: 14)
    }

    // MARK: Sound output

    private func showOutputMenu() {
        let handler = MenuHandler()
        outputMenuHandler = handler
        let menu = NSMenu()
        let current = AudioOutputs.currentID()
        for output in AudioOutputs.list() {
            let item = handler.item(output.name) { [weak self] in
                AudioOutputs.setDefault(output.id)
                self?.controls.refresh()   // each output has its own volume
            }
            item.state = output.id == current ? .on : .off
            menu.addItem(item)
        }
        let show: () -> Void = { _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.outputButton.bounds.height + 2), in: self.outputButton) }
        if let holdOpen { holdOpen(show) } else { show() }
    }

    // MARK: Tap to sync

    private func startSync() {
        let texts: [String]
        switch store.lyrics {
        case .plain(let text):
            texts = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .synced(let lines):
            texts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return
        }
        guard texts.count >= 2 else { return }
        syncing = true
        syncTitle = store.track?.title ?? ""
        store.seek(to: 0)   // start from the top of the song
        syncView.begin(texts: texts)
        requestPin?()       // stay open while syncing
        update()
        layoutContents()
    }

    private static func appIcon(for source: MusicSource) -> NSImage? {
        if let cached = iconCache[source] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.rawValue) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[source] = icon
        return icon
    }

    override func activate() {
        store.startPolling()
        controls.refresh()
        update()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let position = self.store.currentPosition()
            if self.showingLyrics && !self.seekSlider.isDragging {
                self.lyricsView.setPosition(position)
                self.lyricsView.updatePlain(position: position, duration: self.store.track?.duration ?? 0)
            }
            self.updateSeek(position)
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricsTimer = timer
    }

    override func deactivate() {
        store.stopPolling()
        lyricsTimer?.invalidate()
        lyricsTimer = nil
    }

    private func update() {
        let hasTrack = store.track != nil
        for link in [artworkLink, titleLink, artistLink, albumLink] { link.isHidden = !hasTrack }
        albumLink.isHidden = !hasTrack || (store.track?.album.isEmpty ?? true)
        let denied = !hasTrack && store.permissionDenied
        messageLabel.isHidden = hasTrack
        for button in [previousButton, playButton, nextButton] { button.isHidden = !hasTrack }
        settingsButton.isHidden = !denied
        if syncing, store.track?.title != syncTitle { syncing = false }   // the song changed
        lyricsView.isHidden = !showingLyrics || syncing
        syncView.isHidden = !syncing
        var pillText: String?
        if showingLyrics && !syncing {
            switch store.lyrics {
            case .plain: pillText = "Not synced · tap to sync ›"
            case .synced where store.hasUserSync: pillText = "Your timing · redo ›"
            default: break
            }
        }
        syncPill.isHidden = pillText == nil
        if let pillText {
            syncPill.setText(pillText, size: 10, weight: .medium, color: UI.dim(0.55))
            syncPill.alignment = .right
        }
        lyricsView.suppressBadge = pillText != nil
        let showVolume = hasTrack && controls.volumeAvailable
        for view in [volumeSlider, volumeLow, volumeHigh, outputButton] as [NSView] { view.isHidden = !showVolume }
        if !volumeSlider.isDragging { volumeSlider.doubleValue = controls.volume }
        for view in [seekSlider, elapsedLabel, remainingLabel] as [NSView] { view.isHidden = !(hasTrack && showingSeek) }
        updateSeek(store.currentPosition())
        lyricsView.autoScrollPlain = settings.autoScrollLyrics
        lyricsView.offset = settings.lyricsOffset
        lyricsView.set(showingLyrics ? store.lyrics : .idle)
        if showingLyrics {
            lyricsView.setPosition(store.currentPosition())
            lyricsView.updatePlain(position: store.currentPosition(), duration: store.track?.duration ?? 0)
        }

        if let image = store.artwork {
            artwork.image = image
            artwork.contentTintColor = nil
        } else {
            artwork.image = UI.symbol("music.note", size: 28, weight: .regular)
            artwork.contentTintColor = UI.dim(0.5)
        }

        if let source = store.track?.source, let icon = Self.appIcon(for: source) {
            appBadge.image = icon
            appBadge.isHidden = false
        } else {
            appBadge.isHidden = true
        }

        if let track = store.track {
            titleLabel.stringValue = track.title
            artistLabel.stringValue = track.artist
            artistLabel.isHidden = false
            albumLabel.stringValue = track.album
            albumLabel.isHidden = track.album.isEmpty
            playButton.image = UI.symbol(track.isPlaying ? "pause.fill" : "play.fill", size: 26)
        } else if denied {
            titleLabel.stringValue = "Allow automation access"
            artistLabel.isHidden = true
            albumLabel.isHidden = true
            messageLabel.stringValue = "Let Notch Island control Spotify / Music in System Settings → Privacy & Security → Automation."
        } else {
            titleLabel.stringValue = "Nothing playing"
            artistLabel.isHidden = true
            albumLabel.isHidden = true
            messageLabel.stringValue = "Start playback in Spotify or Music."
        }
        layoutContents()
    }
}

// MARK: - Shelf

final class DashedBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [6, 5]
        path.setLineDash(pattern, count: 2, phase: 0)
        UI.dim(0.3).setStroke()
        path.stroke()
    }
}

/// Picture thumbnails for shelf files (pictures, PDFs, documents), kept so tiles don't flicker when rebuilt.
enum ShelfThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL, completion: @escaping (NSImage) -> Void) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                cache.setObject(image, forKey: url as NSURL)
                completion(image)
            }
        }
    }
}

final class ShelfItemView: NSView, NSDraggingSource {
    private let url: URL
    private let onRemove: () -> Void
    private let onToggle: () -> Void
    private var mouseDownEvent: NSEvent?
    private var menuHandler = MenuHandler()
    private let icon = NSImageView(frame: NSRect(x: 16, y: 8, width: 48, height: 48))
    private let check = NSImageView(frame: NSRect(x: 56, y: 4, width: 20, height: 20))

    init(url: URL, selected: Bool, onToggle: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.url = url
        self.onRemove = onRemove
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 84))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = UI.dim(0.08).cgColor

        icon.image = ShelfThumbnails.cached(url) ?? NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        if ShelfThumbnails.cached(url) == nil {
            ShelfThumbnails.load(url) { [weak self] image in self?.icon.image = image }
        }

        check.image = UI.symbol("checkmark.circle.fill", size: 16, weight: .semibold)
        check.contentTintColor = .systemBlue
        addSubview(check)
        setSelected(selected)

        let name = UI.label(url.lastPathComponent, size: 10, color: UI.dim(0.75), alignment: .center)
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 4, y: 62, width: 72, height: 14)
        addSubview(name)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A selected tile gets a blue outline and a tick. Selected files are the ones AirDrop sends.
    func setSelected(_ selected: Bool) {
        check.isHidden = !selected
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.backgroundColor = (selected ? NSColor.systemBlue.withAlphaComponent(0.18) : UI.dim(0.08)).cgColor
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            mouseDownEvent = nil
            NSWorkspace.shared.open(url)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click (no drag, not a double-click) selects or deselects the file.
        if mouseDownEvent != nil && event.clickCount == 1 { onToggle() }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        // Drag the file back out into Finder, Mail, etc.
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        dragItem.setDraggingFrame(NSRect(x: 16, y: 8, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let handler = MenuHandler()
        menuHandler = handler
        let url = self.url
        let onRemove = self.onRemove
        let menu = NSMenu()
        menu.addItem(handler.item("Open") { NSWorkspace.shared.open(url) })
        menu.addItem(handler.item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        menu.addItem(handler.item("Remove from shelf") { onRemove() })
        return menu
    }
}

final class ShelfTabView: TabContentView {
    private let model: NotchModel
    private let box = DashedBox()
    private let boxIcon = NSImageView()
    private let boxLabel = UI.label("Drop files here to park them", size: 12, color: UI.dim(0.55), alignment: .center)
    private let scroll = UI.scrollView(horizontal: true)
    private let doc = FlippedView()
    private let countLabel = UI.label("", size: 11, weight: .medium, color: UI.dim(0.55))
    private let airDropButton = ClosureButton.pill("AirDrop all", size: 11, height: 22) {}
    private var selected = Set<URL>()
    private var tiles: [URL: ShelfItemView] = [:]
    private var cancellable: AnyCancellable?

    init(model: NotchModel) {
        self.model = model
        super.init(frame: .zero)
        boxIcon.image = UI.symbol("arrow.down.doc", size: 20, weight: .regular)
        boxIcon.contentTintColor = UI.dim(0.55)
        scroll.documentView = doc
        airDropButton.handler = { [weak self] in
            guard let self, !self.model.shelf.isEmpty else { return }
            // Selected files only; with nothing selected, everything on the shelf.
            let chosen = self.selected.isEmpty ? self.model.shelf : self.model.shelf.filter { self.selected.contains($0) }
            self.requestPin?()   // keep the island open while the AirDrop picker is up
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: chosen)
        }
        for view in [box, boxIcon, boxLabel, scroll, countLabel, airDropButton] as [NSView] { addSubview(view) }
        cancellable = model.$shelf
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        box.frame = bounds
        boxIcon.frame = NSRect(x: bounds.midX - 14, y: bounds.midY - 30, width: 28, height: 28)
        boxLabel.frame = NSRect(x: 0, y: bounds.midY + 4, width: bounds.width, height: 16)
        scroll.frame = NSRect(x: 0, y: 28, width: bounds.width, height: max(bounds.height - 28, 10))
        countLabel.frame = NSRect(x: 2, y: 5, width: max(bounds.width - 110, 10), height: 16)
        updateHeader()
        rebuild()
    }

    /// The count text and the AirDrop button follow the selection.
    private func updateHeader() {
        let total = model.shelf.count
        let chosen = selected.count
        if chosen == 0 {
            countLabel.stringValue = total == 1 ? "1 item on the shelf · click to select" : "\(total) items on the shelf · click to select"
        } else {
            countLabel.stringValue = "\(chosen) of \(total) selected"
        }
        let title = chosen == 0 ? "AirDrop all" : "AirDrop \(chosen)"
        airDropButton.setText(title, size: 11)
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width + 28)
        airDropButton.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: 22)
    }

    private func rebuild() {
        let urls = model.shelf
        selected = selected.intersection(urls)   // forget files that left the shelf
        countLabel.isHidden = urls.isEmpty
        airDropButton.isHidden = urls.isEmpty
        updateHeader()
        let empty = urls.isEmpty
        box.isHidden = !empty
        boxIcon.isHidden = !empty
        boxLabel.isHidden = !empty
        scroll.isHidden = empty
        doc.subviews.forEach { $0.removeFromSuperview() }
        tiles = [:]
        for (index, url) in urls.enumerated() {
            let tile = ShelfItemView(url: url, selected: selected.contains(url), onToggle: { [weak self] in
                guard let self else { return }
                if self.selected.contains(url) { self.selected.remove(url) } else { self.selected.insert(url) }
                self.tiles[url]?.setSelected(self.selected.contains(url))
                self.updateHeader()
            }, onRemove: { [weak model] in model?.remove(url) })
            tile.frame.origin = NSPoint(x: CGFloat(index) * 90, y: 4)
            doc.addSubview(tile)
            tiles[url] = tile
        }
        doc.frame = NSRect(x: 0, y: 0, width: max(CGFloat(urls.count) * 90, scroll.bounds.width),
                           height: max(scroll.bounds.height, 92))
    }
}

// MARK: - Timer

final class RingView: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 4

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 6
        UI.dim(0.15).setStroke()
        track.stroke()

        if progress > 0 {
            let arc = NSBezierPath()
            // Start at the top, sweep clockwise.
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(progress, 1)), clockwise: true)
            arc.lineWidth = 6
            arc.lineCapStyle = .round
            NSColor.systemOrange.setStroke()
            arc.stroke()
        }
    }
}

final class TimerTabView: TabContentView {
    private let timer: FocusTimer
    private let ring = RingView()
    private let timeLabel = UI.label("", size: 18, weight: .semibold, alignment: .center)
    private var presets: [(minutes: Int, button: ClosureButton)] = []
    private let startButton = ClosureButton(frame: .zero)
    private let resetButton = ClosureButton(frame: .zero)
    private var cancellable: AnyCancellable?

    init(timer: FocusTimer) {
        self.timer = timer
        super.init(frame: .zero)
        timeLabel.font = UI.monoDigits(size: 18, weight: .semibold)
        addSubview(ring)
        addSubview(timeLabel)

        for minutes in [5, 15, 25, 45] {
            let button = ClosureButton.pill("\(minutes)m", fill: UI.dim(0.09)) { [weak timer] in
                timer?.set(minutes: minutes)
            }
            presets.append((minutes, button))
            addSubview(button)
        }

        startButton.handler = { [weak timer] in timer?.toggle() }
        resetButton.image = UI.symbol("arrow.counterclockwise", size: 13)
        resetButton.contentTintColor = .white
        resetButton.setFill(UI.dim(0.12), radius: 16)
        resetButton.handler = { [weak timer] in timer?.reset() }
        addSubview(startButton)
        addSubview(resetButton)

        cancellable = timer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContents() {
        let ringY = (bounds.height - 92) / 2
        ring.frame = NSRect(x: 0, y: ringY, width: 92, height: 92)
        timeLabel.frame = NSRect(x: 0, y: ringY + 35, width: 92, height: 22)
        for (index, preset) in presets.enumerated() {
            preset.button.frame = NSRect(x: 116 + CGFloat(index) * 52, y: ringY + 8, width: 44, height: 26)
        }
        startButton.frame = NSRect(x: 116, y: ringY + 48, width: 104, height: 32)
        resetButton.frame = NSRect(x: 230, y: ringY + 48, width: 32, height: 32)
    }

    private func update() {
        timeLabel.stringValue = timer.display
        ring.progress = timer.progress
        for preset in presets {
            preset.button.setFill(timer.total == preset.minutes * 60 ? UI.dim(0.22) : UI.dim(0.09), radius: 13)
        }
        startButton.setText(timer.running ? "Pause" : "Start", size: 13, color: .black)
        startButton.setFill(.systemOrange, radius: 16)
    }
}

// MARK: - Clipboard

final class ClipRowView: ClickableView {
    private let item: ClipItem
    private let store: ClipboardStore
    private var menuHandler = MenuHandler()
    private var pressedHere = false
    private let pinZone: CGFloat = 30

    init(item: ClipItem, copied: Bool, width: CGFloat, store: ClipboardStore) {
        self.item = item
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = (item.pinned ? NSColor.systemYellow.withAlphaComponent(0.12) : UI.dim(0.08)).cgColor

        let right: NSTextField
        if copied {
            right = UI.label("✓ Copied", size: 11, weight: .semibold, color: .systemGreen, alignment: .right)
        } else {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .abbreviated
            right = UI.label(relative.localizedString(for: item.date, relativeTo: Date()),
                             size: 11, color: UI.dim(0.45), alignment: .right)
        }
        right.frame = NSRect(x: width - pinZone - 80, y: 6, width: 80, height: 16)
        addSubview(right)

        let pin = NSImageView(frame: NSRect(x: width - 24, y: 6, width: 16, height: 16))
        pin.image = UI.symbol(item.pinned ? "pin.fill" : "pin", size: 11, weight: .regular)
        pin.contentTintColor = item.pinned ? .systemYellow : UI.dim(0.35)
        pin.imageScaling = .scaleProportionallyDown
        addSubview(pin)

        let text = UI.label(item.text.replacingOccurrences(of: "\n", with: " "), size: 12)
        text.frame = NSRect(x: 10, y: 5, width: width - 20 - pinZone - 80, height: 18)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { pressedHere = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressedHere = false }
        let point = convert(event.locationInWindow, from: nil)
        guard pressedHere, bounds.contains(point) else { return }
        if point.x >= bounds.width - pinZone {
            store.togglePin(item)
        } else {
            store.copy(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let handler = MenuHandler()
        menuHandler = handler
        let store = self.store
        let item = self.item
        let menu = NSMenu()
        menu.addItem(handler.item("Copy") { store.copy(item) })
        menu.addItem(handler.item(item.pinned ? "Unpin" : "Pin to top") { store.togglePin(item) })
        menu.addItem(handler.item("Remove") { store.remove(item) })
        return menu
    }
}

final class ClipboardTabView: TabContentView, NSSearchFieldDelegate {
    private let store: ClipboardStore
    private let header = UI.label("Clipboard", size: 12, weight: .semibold, color: UI.dim())
    private let search = PinningSearchField(frame: .zero)
    private let clearButton = ClosureButton(frame: .zero)
    private let emptyIcon = NSImageView()
    private let emptyLabel = UI.label("Copy some text and it shows up here", size: 12, color: UI.dim(0.55), alignment: .center)
    private let scroll = UI.scrollView(horizontal: false)
    private let doc = FlippedView()
    private var cancellable: AnyCancellable?

    init(store: ClipboardStore) {
        self.store = store
        super.init(frame: .zero)
        clearButton.handler = { [weak store] in store?.clearUnpinned() }
        search.placeholderString = "Search clipboard"
        search.controlSize = .small
        search.font = NSFont.systemFont(ofSize: 11)
        search.delegate = self
        search.onFocus = { [weak self] in self?.requestPin?() }
        emptyIcon.image = UI.symbol("doc.on.clipboard", size: 20, weight: .regular)
        emptyIcon.contentTintColor = UI.dim(0.55)
        scroll.documentView = doc
        for view in [header, search, clearButton, emptyIcon, emptyLabel, scroll] as [NSView] { addSubview(view) }
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    override func layoutContents() {
        header.frame = NSRect(x: 0, y: 2, width: 80, height: 16)
        clearButton.frame = NSRect(x: bounds.width - 84, y: 2, width: 84, height: 16)
        search.frame = NSRect(x: 84, y: 0, width: max(bounds.width - 84 - 92, 80), height: 20)
        scroll.frame = NSRect(x: 0, y: 28, width: bounds.width, height: bounds.height - 28)
        emptyIcon.frame = NSRect(x: bounds.midX - 14, y: bounds.midY - 26, width: 28, height: 28)
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY + 6, width: bounds.width, height: 16)
        rebuild()
    }

    override func deactivate() {
        window?.makeFirstResponder(nil)
    }

    private var query: String {
        search.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func rebuild() {
        let all = store.items
        let matches = query.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(query) }
        // Pinned items first, each group newest first.
        let items = matches.filter { $0.pinned } + matches.filter { !$0.pinned }

        let hasPinned = all.contains { $0.pinned }
        clearButton.setText(hasPinned ? "Clear unpinned" : "Clear", size: 11, weight: .medium, color: UI.dim(0.5))
        clearButton.alignment = .right
        clearButton.isHidden = all.isEmpty
        search.isHidden = all.isEmpty

        let empty = items.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue = all.isEmpty ? "Copy some text and it shows up here" : "Nothing matches “\(query)”"
        scroll.isHidden = empty

        doc.subviews.forEach { $0.removeFromSuperview() }
        let width = max(scroll.bounds.width, 1)
        for (index, item) in items.enumerated() {
            let row = ClipRowView(item: item, copied: store.lastCopiedID == item.id, width: width, store: store)
            row.frame.origin = NSPoint(x: 0, y: CGFloat(index) * 32)
            doc.addSubview(row)
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(items.count) * 32, scroll.bounds.height))
    }
}
