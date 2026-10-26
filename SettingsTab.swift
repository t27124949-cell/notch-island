import AppKit
import Combine

/// One feature on/off cell in the Features grid.
final class FeatureCell: NSView {
    private let label: NSTextField
    let toggle = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))

    init(title: String, symbol: String) {
        label = UI.label(title, size: 12, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = UI.dim(0.06).cgColor
        let icon = NSImageView(frame: NSRect(x: 10, y: 8, width: 16, height: 16))
        icon.image = UI.symbol(symbol, size: 12, weight: .regular)
        icon.contentTintColor = UI.dim(0.7)
        addSubview(icon)
        addSubview(label)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func layoutCell() {
        label.frame = NSRect(x: 34, y: 8, width: max(bounds.width - 34 - 52, 10), height: 16)
        toggle.frame = NSRect(x: bounds.width - 36 - 10, y: 6, width: 36, height: 20)
    }
}

/// A labelled row with one control on the right, and an optional value readout.
final class SettingRow: NSView {
    private let titleLabel: NSTextField
    private let control: NSView
    private let controlWidth: CGFloat
    private let controlHeight: CGFloat
    let valueLabel = UI.label("", size: 12, color: UI.dim(0.6), alignment: .right)

    init(title: String, control: NSView, controlWidth: CGFloat, controlHeight: CGFloat = 22, showsValue: Bool = false) {
        titleLabel = UI.label(title, size: 12, weight: .medium)
        self.control = control
        self.controlWidth = controlWidth
        self.controlHeight = controlHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = UI.dim(0.06).cgColor
        addSubview(titleLabel)
        addSubview(control)
        if showsValue { addSubview(valueLabel) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func layoutRow() {
        let w = bounds.width
        let controlX = w - 12 - controlWidth
        control.frame = NSRect(x: controlX, y: (bounds.height - controlHeight) / 2,
                               width: controlWidth, height: controlHeight)
        valueLabel.frame = NSRect(x: controlX - 64, y: (bounds.height - 16) / 2, width: 58, height: 16)
        titleLabel.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(controlX - 12 - 70, 10), height: 16)
    }
}

final class ClosureSlider: NSSlider {
    var handler: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isContinuous = true
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?(doubleValue) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SettingsTabView: TabContentView, NSTextFieldDelegate {
    private let model: NotchModel
    private let settings: SettingsStore
    private let scroll = UI.scrollView(horizontal: false)
    private let doc = FlippedView()

    private var headers: [NSTextField] = []
    private var featureCells: [(tab: NotchTab, cell: FeatureCell)] = []
    private var rows: [SettingRow] = []
    private var buttons: [ClosureButton] = []
    private var refreshers: [() -> Void] = []
    private var menuHandler = MenuHandler()
    private var cancellable: AnyCancellable?

    // Controls that need to be reached after creation.
    private let hoverPill = ClosureButton(frame: .zero)
    private let clickPill = ClosureButton(frame: .zero)
    private let startTabButton = ClosureButton(frame: .zero)
    private let retentionButton = ClosureButton(frame: .zero)
    private let loginSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
    private let loginNote = UI.label("", size: 11, color: .systemOrange)
    private let featuresHeader = UI.label("FEATURES", size: 11, weight: .semibold, color: UI.dim(0.5))
    private let behaviorHeader = UI.label("BEHAVIOR", size: 11, weight: .semibold, color: UI.dim(0.5))
    private let activitiesHeader = UI.label("LIVE ACTIVITIES", size: 11, weight: .semibold, color: UI.dim(0.5))
    private let clipboardHeader = UI.label("CLIPBOARD HISTORY", size: 11, weight: .semibold, color: UI.dim(0.5))
    private let generalHeader = UI.label("GENERAL", size: 11, weight: .semibold, color: UI.dim(0.5))
    private let aboutLabel = UI.label("Notch Island · settings are saved automatically", size: 11, color: UI.dim(0.4))

    init(model: NotchModel) {
        self.model = model
        self.settings = model.settings
        super.init(frame: .zero)
        scroll.documentView = doc
        addSubview(scroll)
        buildFeatures()
        buildBehavior()
        buildActivities()
        buildClipboard()
        buildGeneral()
        for header in [featuresHeader, behaviorHeader, activitiesHeader, clipboardHeader, generalHeader] { doc.addSubview(header) }
        doc.addSubview(aboutLabel)

        cancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll() }
        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func buildFeatures() {
        for tab in NotchTab.allCases where tab != .settings {
            let cell = FeatureCell(title: tab.title, symbol: tab.symbol)
            cell.toggle.onChange = { [weak self] on in self?.settings.setEnabled(tab, on) }
            doc.addSubview(cell)
            featureCells.append((tab, cell))
        }
        refreshers.append { [weak self] in
            guard let self else { return }
            for entry in self.featureCells { entry.cell.toggle.isOn = self.settings.isEnabled(entry.tab) }
        }
    }

    private func slider(min: Double, max: Double, _ handler: @escaping (Double) -> Void) -> ClosureSlider {
        let slider = ClosureSlider(frame: .zero)
        slider.minValue = min
        slider.maxValue = max
        slider.handler = handler
        return slider
    }

    private func addRow(_ row: SettingRow) {
        doc.addSubview(row)
        rows.append(row)
    }

    private func buildBehavior() {
        // Open with hover or click
        let trigger = NSView()
        hoverPill.setText("Hover", size: 11, color: .white)
        clickPill.setText("Click", size: 11, color: .white)
        hoverPill.handler = { [weak self] in self?.settings.clickToOpen = false }
        clickPill.handler = { [weak self] in self?.settings.clickToOpen = true }
        trigger.addSubview(hoverPill)
        trigger.addSubview(clickPill)
        hoverPill.frame = NSRect(x: 0, y: 0, width: 62, height: 22)
        clickPill.frame = NSRect(x: 68, y: 0, width: 62, height: 22)
        addRow(SettingRow(title: "Open the island with", control: trigger, controlWidth: 130))
        refreshers.append { [weak self] in
            guard let self else { return }
            self.hoverPill.setFill(self.settings.clickToOpen ? UI.dim(0.1) : UI.dim(0.28), radius: 11)
            self.clickPill.setFill(self.settings.clickToOpen ? UI.dim(0.28) : UI.dim(0.1), radius: 11)
        }

        // Open delay
        let openSlider = slider(min: 0, max: 0.6) { [weak self] value in self?.settings.openDelay = value }
        let openRow = SettingRow(title: "Open delay (hover)", control: openSlider, controlWidth: 150, showsValue: true)
        addRow(openRow)
        refreshers.append { [weak self] in
            guard let self else { return }
            openSlider.doubleValue = self.settings.openDelay
            openRow.valueLabel.stringValue = String(format: "%.2f s", self.settings.openDelay)
        }

        // Close delay
        let closeSlider = slider(min: 0.05, max: 1.5) { [weak self] value in self?.settings.closeDelay = value }
        let closeRow = SettingRow(title: "Close delay", control: closeSlider, controlWidth: 150, showsValue: true)
        addRow(closeRow)
        refreshers.append { [weak self] in
            guard let self else { return }
            closeSlider.doubleValue = self.settings.closeDelay
            closeRow.valueLabel.stringValue = String(format: "%.2f s", self.settings.closeDelay)
        }

        // Hot zone width
        let zoneSlider = slider(min: 0, max: 200) { [weak self] value in self?.settings.hotZonePadding = value }
        let zoneRow = SettingRow(title: "Hover area beside the notch", control: zoneSlider, controlWidth: 150, showsValue: true)
        addRow(zoneRow)
        refreshers.append { [weak self] in
            guard let self else { return }
            zoneSlider.doubleValue = self.settings.hotZonePadding
            zoneRow.valueLabel.stringValue = "\(Int(self.settings.hotZonePadding.rounded())) pt"
        }

        // Click outside to close
        let outsideSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        outsideSwitch.onChange = { [weak self] on in self?.settings.clickOutsideCloses = on }
        addRow(SettingRow(title: "Click outside to close", control: outsideSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            outsideSwitch.isOn = self.settings.clickOutsideCloses
        }

        // Open on which tab
        startTabButton.handler = { [weak self] in self?.showStartTabMenu() }
        addRow(SettingRow(title: "Open on", control: startTabButton, controlWidth: 130))
        refreshers.append { [weak self] in
            guard let self else { return }
            var name = "Last used tab"
            if self.settings.startTab != "last", let tab = NotchTab(rawValue: self.settings.startTab) {
                name = tab.title
            }
            self.startTabButton.setText(name + " ▾", size: 11, color: .white)
            self.startTabButton.setFill(UI.dim(0.14), radius: 11)
        }

        // 24-hour clock
        let clockSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        clockSwitch.onChange = { [weak self] on in self?.settings.use24Hour = on }
        addRow(SettingRow(title: "24-hour clock", control: clockSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            clockSwitch.isOn = self.settings.use24Hour
        }

        // Fahrenheit
        let fahrenheitSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        fahrenheitSwitch.onChange = { [weak self] on in
            guard let self, self.model.weather.fahrenheit != on else { return }
            self.model.weather.toggleUnit()
        }
        addRow(SettingRow(title: "Temperature in °F", control: fahrenheitSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            fahrenheitSwitch.isOn = self.model.weather.fahrenheit
        }

        // Song lyrics
        let lyricsSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        lyricsSwitch.onChange = { [weak self] on in self?.settings.showLyrics = on }
        addRow(SettingRow(title: "Show song lyrics (looked up online)", control: lyricsSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            lyricsSwitch.isOn = self.settings.showLyrics
        }
        addKeyRow()
        addFocusRow()
    }

    private let keyField = NSSecureTextField(frame: .zero)
    private let focusField = NSTextField(frame: .zero)

    private func addFocusRow() {
        focusField.placeholderString = "Work, Sleep, …"
        focusField.font = NSFont.systemFont(ofSize: 11)
        focusField.textColor = .white
        focusField.isBordered = false
        focusField.drawsBackground = true
        focusField.backgroundColor = UI.dim(0.12)
        focusField.focusRingType = .none
        focusField.wantsLayer = true
        focusField.layer?.cornerRadius = 6
        focusField.delegate = self
        addRow(SettingRow(title: "Focus modes (comma-separated)", control: focusField, controlWidth: 200))
        refreshers.append { [weak self] in
            guard let self, self.focusField.currentEditor() == nil else { return }
            self.focusField.stringValue = self.settings.focusModes
        }
    }

    private func addKeyRow() {
        keyField.placeholderString = "optional key"
        keyField.font = NSFont.systemFont(ofSize: 11)
        keyField.textColor = .white
        keyField.isBordered = false
        keyField.drawsBackground = true
        keyField.backgroundColor = UI.dim(0.12)
        keyField.focusRingType = .none
        keyField.wantsLayer = true
        keyField.layer?.cornerRadius = 6
        keyField.delegate = self
        addRow(SettingRow(title: "Musixmatch key (more lyrics, partial)", control: keyField, controlWidth: 150))
        refreshers.append { [weak self] in
            guard let self, self.keyField.currentEditor() == nil else { return }
            self.keyField.stringValue = self.settings.musixmatchKey
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { requestPin?() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === keyField {
            settings.musixmatchKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if field === focusField {
            let cleaned = ControlsStore.parseFocusModes(focusField.stringValue).joined(separator: ", ")
            settings.focusModes = cleaned.isEmpty ? SettingsStore.defaultFocusModes : cleaned
        }
    }

    private func buildActivities() {
        func addSwitchRow(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
            let toggle = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
            toggle.onChange = { on in set(on) }
            addRow(SettingRow(title: title, control: toggle, controlWidth: 36, controlHeight: 20))
            refreshers.append { toggle.isOn = get() }
        }
        addSwitchRow("Show live previews in the notch",
                     get: { [weak self] in self?.settings.activitiesEnabled ?? true },
                     set: { [weak self] in self?.settings.activitiesEnabled = $0 })
        addSwitchRow("   Song changes",
                     get: { [weak self] in self?.settings.activityMusic ?? true },
                     set: { [weak self] in self?.settings.activityMusic = $0 })
        addSwitchRow("   Charging and low battery",
                     get: { [weak self] in self?.settings.activityBattery ?? true },
                     set: { [weak self] in self?.settings.activityBattery = $0 })
        addSwitchRow("   Timer finished",
                     get: { [weak self] in self?.settings.activityTimer ?? true },
                     set: { [weak self] in self?.settings.activityTimer = $0 })
        addSwitchRow("Music animation in the notch while playing",
                     get: { [weak self] in self?.settings.ambientMusic ?? true },
                     set: { [weak self] in self?.settings.ambientMusic = $0 })
        addSwitchRow("Battery level in the notch when idle",
                     get: { [weak self] in self?.settings.ambientBattery ?? true },
                     set: { [weak self] in self?.settings.ambientBattery = $0 })
    }

    private func buildClipboard() {
        // Save history to disk
        let persistSwitch = PillSwitch(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        persistSwitch.onChange = { [weak self] on in self?.settings.clipboardPersist = on }
        addRow(SettingRow(title: "Save history on this Mac", control: persistSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            persistSwitch.isOn = self.settings.clipboardPersist
        }

        // Keep for…
        retentionButton.handler = { [weak self] in self?.showRetentionMenu() }
        addRow(SettingRow(title: "Keep items for", control: retentionButton, controlWidth: 110))
        refreshers.append { [weak self] in
            guard let self else { return }
            self.retentionButton.setText(self.retentionTitle(self.settings.clipboardRetentionDays) + " ▾", size: 11, color: .white)
            self.retentionButton.setFill(UI.dim(0.14), radius: 11)
        }

        // Max items
        let sizeSlider = slider(min: 10, max: 500) { [weak self] value in
            self?.settings.clipboardMaxItems = Int((value / 10).rounded()) * 10
        }
        let sizeRow = SettingRow(title: "Most items to keep", control: sizeSlider, controlWidth: 150, showsValue: true)
        addRow(sizeRow)
        refreshers.append { [weak self] in
            guard let self else { return }
            sizeSlider.doubleValue = Double(self.settings.clipboardMaxItems)
            sizeRow.valueLabel.stringValue = "\(self.settings.clipboardMaxItems)"
        }

        // Clear now
        let clearButton = ClosureButton.pill("Clear all history now", size: 11, fill: UI.dim(0.14), height: 24) { [weak self] in
            self?.model.clipboard.clear()
        }
        doc.addSubview(clearButton)
        buttons.append(clearButton)
    }

    private func buildGeneral() {
        loginSwitch.onChange = { [weak self] on in
            guard let self else { return }
            if let message = self.settings.setLaunchAtLogin(on) {
                self.loginNote.stringValue = "Couldn't change this: \(message)"
            } else {
                self.loginNote.stringValue = ""
            }
            self.loginSwitch.isOn = self.settings.launchAtLogin
        }
        addRow(SettingRow(title: "Open at login", control: loginSwitch, controlWidth: 36, controlHeight: 20))
        refreshers.append { [weak self] in
            guard let self else { return }
            self.loginSwitch.isOn = self.settings.launchAtLogin
        }
        doc.addSubview(loginNote)

        let reset = ClosureButton.pill("Reset settings", size: 11, fill: UI.dim(0.14), height: 24) { [weak self] in
            self?.settings.resetToDefaults()
        }
        let quit = ClosureButton.pill("Quit Notch Island", size: 11, fill: NSColor.systemRed.withAlphaComponent(0.8), height: 24) {
            NSApp.terminate(nil)
        }
        for button in [reset, quit] {
            doc.addSubview(button)
            buttons.append(button)
        }
    }

    // MARK: Pop-up choices

    private func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    private func showRetentionMenu() {
        let handler = MenuHandler()
        menuHandler = handler
        let menu = NSMenu()
        for days in [1, 7, 30, 90, 0] {
            menu.addItem(handler.item(retentionTitle(days)) { [weak self] in self?.settings.clipboardRetentionDays = days })
        }
        let show: () -> Void = { _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.retentionButton.bounds.height + 2), in: self.retentionButton) }
        if let holdOpen { holdOpen(show) } else { show() }
    }

    private func showStartTabMenu() {
        let handler = MenuHandler()
        menuHandler = handler
        let menu = NSMenu()
        menu.addItem(handler.item("Last used tab") { [weak self] in self?.settings.startTab = "last" })
        for tab in NotchTab.allCases where settings.isEnabled(tab) {
            menu.addItem(handler.item(tab.title) { [weak self] in self?.settings.startTab = tab.rawValue })
        }
        let show: () -> Void = { _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.startTabButton.bounds.height + 2), in: self.startTabButton) }
        if let holdOpen { holdOpen(show) } else { show() }
    }

    // MARK: Layout

    override func layoutContents() {
        scroll.frame = bounds
        let width = bounds.width - 6   // leave room for the overlay scroll bar
        var y: CGFloat = 0

        func place(header: NSTextField) {
            header.frame = NSRect(x: 2, y: y, width: width, height: 14)
            y += 20
        }

        place(header: featuresHeader)
        let columns: CGFloat = 3
        let cellWidth = (width - (columns - 1) * 8) / columns
        for (index, entry) in featureCells.enumerated() {
            let column = CGFloat(index % Int(columns))
            let line = CGFloat(index / Int(columns))
            entry.cell.frame = NSRect(x: column * (cellWidth + 8), y: y + line * 38, width: cellWidth, height: 32)
            entry.cell.layoutCell()
        }
        y += CGFloat((featureCells.count + Int(columns) - 1) / Int(columns)) * 38 + 8

        // Rows are in creation order: behavior (9), clipboard (3), general (1).
        let behaviorRows = Array(rows.prefix(11))
        let activityRows = Array(rows.dropFirst(11).prefix(6))
        let clipboardRows = Array(rows.dropFirst(17).prefix(3))
        let generalRows = Array(rows.dropFirst(20))

        func layout(_ group: [SettingRow]) {
            for row in group {
                row.frame = NSRect(x: 0, y: y, width: width, height: 32)
                row.layoutRow()
                y += 36
            }
        }

        place(header: behaviorHeader)
        layout(behaviorRows)
        y += 6

        place(header: activitiesHeader)
        layout(activityRows)
        y += 6

        place(header: clipboardHeader)
        layout(clipboardRows)
        if let clearButton = buttons.first {
            clearButton.frame.origin = NSPoint(x: 0, y: y)
            y += 32
        }
        y += 6

        place(header: generalHeader)
        layout(generalRows)
        loginNote.frame = NSRect(x: 2, y: y - 2, width: width, height: 14)
        y += 18
        var x: CGFloat = 0
        for button in buttons.dropFirst() {
            button.frame.origin = NSPoint(x: x, y: y)
            x += button.frame.width + 8
        }
        y += 34
        aboutLabel.frame = NSRect(x: 2, y: y, width: width, height: 14)
        y += 24

        doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    override func activate() { refreshAll() }

    private func refreshAll() {
        for refresh in refreshers { refresh() }
    }
}
