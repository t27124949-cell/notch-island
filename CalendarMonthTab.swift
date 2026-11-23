import AppKit
import Combine

/// One day in the month grid: the number, a ring for today, a fill for the selected day, a dot when there are events.
final class DayCellView: ClickableView {
    var number = 1
    var inMonth = true
    var isToday = false
    var isSelected = false
    var hasEvents = false

    override var isFlipped: Bool { true }

    static let accent = NSColor(red: 0.91, green: 0.51, blue: 0.23, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let side = max(min(bounds.height - 5, 20), 10)
        let circle = NSRect(x: bounds.midX - side / 2, y: 1, width: side, height: side)

        if isToday {
            DayCellView.accent.setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else if isSelected {
            UI.dim(0.28).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        if isToday && isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -1.5, dy: -1.5))
            ring.lineWidth = 1.2
            ring.stroke()
        }

        let color: NSColor = isToday ? .white : (inMonth ? .white : UI.dim(0.3))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UI.monoDigits(size: 11, weight: isToday || isSelected ? .semibold : .regular),
            .foregroundColor: color,
        ]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)

        if hasEvents {
            (isToday ? DayCellView.accent : UI.dim(0.7)).setFill()
            let dot = NSRect(x: bounds.midX - 1.5, y: circle.maxY + 1, width: 3, height: 3)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// One event in the list beside the month: coloured bar, title, time, and a Join button when it has a meeting link.
final class DayEventRowView: NSView {
    static let rowHeight: CGFloat = 40

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init(event: CalendarEvent, width: CGFloat, join: @escaping (URL) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: DayEventRowView.rowHeight - 4))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = UI.dim(0.08).cgColor

        let bar = NSView(frame: NSRect(x: 10, y: 7, width: 4, height: 22))
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = event.color.cgColor
        addSubview(bar)

        var joinButton: ClosureButton?
        if let url = event.joinURL, event.end > Date() {
            let button = ClosureButton.pill("Join", size: 11, fill: DayCellView.accent, height: 22) { join(url) }
            button.frame.origin = NSPoint(x: width - 10 - button.frame.width, y: 7)
            addSubview(button)
            joinButton = button
        }
        let textWidth = width - 24 - (joinButton.map { $0.frame.width + 18 } ?? 10)

        let title = UI.label(event.title, size: 13, weight: .medium)
        title.frame = NSRect(x: 24, y: 3, width: textWidth, height: 17)
        addSubview(title)

        let time = UI.label(DayEventRowView.timeText(for: event), size: 11, color: UI.dim(0.6))
        time.font = UI.monoDigits(size: 11, weight: .regular)
        time.frame = NSRect(x: 24, y: 19, width: textWidth, height: 14)
        addSubview(time)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static func timeText(for event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let range = timeFormatter.string(from: event.start) + " – " + timeFormatter.string(from: event.end)
        let now = Date()
        return (event.start <= now && event.end > now) ? "Now · " + range : range
    }
}

/// Month grid on the left, the selected day's events on the right.
final class CalendarTabView: TabContentView {
    private let store: CalendarStore
    private let calendar = Calendar.current
    private var cancellable: AnyCancellable?

    // Permission / empty messages
    private let messageTitle = UI.label("", size: 15, weight: .semibold)
    private let messageDetail = UI.label("", size: 12, color: UI.dim(), lines: 3)
    private var messageButton: ClosureButton?

    // Month panel
    private let monthLabel = UI.label("", size: 14, weight: .bold)
    private let previousMonth = ClosureButton.icon(UI.symbol("chevron.left", size: 11)) {}
    private let nextMonth = ClosureButton.icon(UI.symbol("chevron.right", size: 11)) {}
    private let todayButton = ClosureButton.pill("Today", size: 10, fill: UI.dim(0.14), height: 20) {}
    private var weekdayLabels: [NSTextField] = []
    private let gridView = FlippedView()
    private var cells: [DayCellView] = []
    private let divider = NSView()

    // Day panel
    private let dayTitle = UI.label("", size: 14, weight: .bold)
    private let daySubtitle = UI.label("", size: 11, color: UI.dim())
    private let emptyLabel = UI.label("Nothing planned. Enjoy the free time.", size: 12, color: UI.dim(0.5))
    private let scroll = UI.scrollView(horizontal: false)
    private let doc = FlippedView()

    private var shownMonth: Date
    private var selectedDay: Date

    private let panelWidth: CGFloat = 266
    private let gridTop: CGFloat = 42

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    init(store: CalendarStore) {
        self.store = store
        let today = Calendar.current.startOfDay(for: Date())
        selectedDay = today
        shownMonth = Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        super.init(frame: .zero)

        previousMonth.handler = { [weak self] in self?.shiftMonth(-1) }
        nextMonth.handler = { [weak self] in self?.shiftMonth(1) }
        todayButton.handler = { [weak self] in self?.goToToday() }

        divider.wantsLayer = true
        divider.layer?.backgroundColor = UI.dim(0.12).cgColor
        scroll.documentView = doc

        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        for i in 0..<7 {
            let index = (calendar.firstWeekday - 1 + i) % 7
            weekdayLabels.append(UI.label(symbols[index], size: 10, weight: .medium, color: UI.dim(0.45), alignment: .center))
        }

        var views: [NSView] = [messageTitle, messageDetail, monthLabel, previousMonth, nextMonth, todayButton,
                               gridView, divider, dayTitle, daySubtitle, emptyLabel, scroll]
        views.append(contentsOf: weekdayLabels)
        for view in views { addSubview(view) }

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var calendarViews: [NSView] {
        var views: [NSView] = [monthLabel, previousMonth, nextMonth, todayButton, gridView, divider,
                               dayTitle, daySubtitle, emptyLabel, scroll]
        views.append(contentsOf: weekdayLabels)
        return views
    }

    // MARK: Layout

    private var cellHeight: CGFloat {
        max(15, min(23, floor((bounds.height - gridTop) / 6)))
    }

    override func layoutContents() {
        messageTitle.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 20)
        messageDetail.frame = NSRect(x: 0, y: 48, width: bounds.width - 40, height: 48)
        messageButton?.frame.origin = NSPoint(x: 0, y: 102)

        monthLabel.frame = NSRect(x: 0, y: 0, width: panelWidth - 120, height: 20)
        nextMonth.frame = NSRect(x: panelWidth - 22, y: -1, width: 22, height: 22)
        previousMonth.frame = NSRect(x: panelWidth - 46, y: -1, width: 22, height: 22)
        todayButton.frame.origin = NSPoint(x: panelWidth - 46 - 8 - todayButton.frame.width, y: 0)

        let cellW = panelWidth / 7
        for (i, label) in weekdayLabels.enumerated() {
            label.frame = NSRect(x: CGFloat(i) * cellW, y: 24, width: cellW, height: 13)
        }
        gridView.frame = NSRect(x: 0, y: gridTop, width: panelWidth, height: cellHeight * 6)

        let rightX = panelWidth + 26
        divider.frame = NSRect(x: panelWidth + 12, y: 0, width: 1, height: bounds.height)
        dayTitle.frame = NSRect(x: rightX, y: 0, width: max(bounds.width - rightX, 10), height: 20)
        daySubtitle.frame = NSRect(x: rightX, y: 21, width: max(bounds.width - rightX, 10), height: 14)
        emptyLabel.frame = NSRect(x: rightX, y: 50, width: max(bounds.width - rightX, 10), height: 16)
        scroll.frame = NSRect(x: rightX, y: 42, width: max(bounds.width - rightX, 10), height: max(bounds.height - 42, 10))
        update()
    }

    override func activate() {
        goToToday()
        store.refresh()
    }

    // MARK: State

    private func setButton(_ title: String?, action: @escaping () -> Void = {}) {
        messageButton?.removeFromSuperview()
        messageButton = nil
        guard let title else { return }
        let button = ClosureButton.pill(title, handler: action)
        button.frame.origin = NSPoint(x: 0, y: 102)
        addSubview(button)
        messageButton = button
    }

    private func showMessage(_ title: String, _ detail: String, button: String? = nil,
                             action: @escaping () -> Void = {}) {
        for view in calendarViews { view.isHidden = true }
        messageTitle.isHidden = false
        messageDetail.isHidden = false
        messageTitle.stringValue = title
        messageDetail.stringValue = detail
        setButton(button, action: action)
    }

    private func update() {
        switch store.access {
        case .unknown:
            showMessage("See your calendar here",
                        "Calendar access is needed to show your month and events.",
                        button: "Allow Calendar Access") { [weak self] in self?.store.requestAccess() }
        case .denied:
            showMessage("Calendar access is off",
                        "Turn it on in System Settings → Privacy & Security → Calendars.",
                        button: "Open Settings") { UI.openSettings("Privacy_Calendars") }
        case .granted:
            setButton(nil)
            messageTitle.isHidden = true
            messageDetail.isHidden = true
            for view in calendarViews { view.isHidden = false }
            rebuild()
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let month = calendar.date(byAdding: .month, value: delta, to: shownMonth) else { return }
        shownMonth = month
        let today = calendar.startOfDay(for: Date())
        if calendar.isDate(month, equalTo: today, toGranularity: .month) {
            selectedDay = today
        } else {
            selectedDay = month
        }
        rebuild()
    }

    private func goToToday() {
        let today = calendar.startOfDay(for: Date())
        selectedDay = today
        shownMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        if store.access == .granted { rebuild() }
    }

    private func select(_ day: Date) {
        selectedDay = calendar.startOfDay(for: day)
        if !calendar.isDate(day, equalTo: shownMonth, toGranularity: .month) {
            shownMonth = calendar.dateInterval(of: .month, for: day)?.start ?? shownMonth
        }
        rebuild()
    }

    /// The 42 days shown in the grid, starting on the locale's first weekday.
    private func gridDates() -> [Date] {
        let weekday = calendar.component(.weekday, from: shownMonth)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: shownMonth) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func rebuild() {
        monthLabel.stringValue = CalendarTabView.monthFormatter.string(from: shownMonth)

        let dates = gridDates()
        guard let first = dates.first, let last = dates.last else { return }
        let marked = store.daysWithEvents(from: first, to: last)

        cells.forEach { $0.removeFromSuperview() }
        cells.removeAll()
        let cellW = panelWidth / 7
        let cellH = cellHeight
        for (i, date) in dates.enumerated() {
            let cell = DayCellView(frame: NSRect(x: CGFloat(i % 7) * cellW, y: CGFloat(i / 7) * cellH,
                                                 width: cellW, height: cellH))
            cell.number = calendar.component(.day, from: date)
            cell.inMonth = calendar.isDate(date, equalTo: shownMonth, toGranularity: .month)
            cell.isToday = calendar.isDateInToday(date)
            cell.isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
            cell.hasEvents = marked.contains(calendar.startOfDay(for: date))
            cell.onClick = { [weak self] in self?.select(date) }
            gridView.addSubview(cell)
            cells.append(cell)
        }
        rebuildDayList()
    }

    private func rebuildDayList() {
        let events = store.events(on: selectedDay)
        let title = CalendarTabView.dayFormatter.string(from: selectedDay)
        dayTitle.stringValue = calendar.isDateInToday(selectedDay) ? "Today · " + title : title
        daySubtitle.stringValue = events.isEmpty ? "No events"
            : (events.count == 1 ? "1 event" : "\(events.count) events")
        emptyLabel.isHidden = !events.isEmpty

        doc.subviews.forEach { $0.removeFromSuperview() }
        let width = max(scroll.bounds.width, 1)
        for (index, event) in events.enumerated() {
            let row = DayEventRowView(event: event, width: width) { url in NSWorkspace.shared.open(url) }
            row.frame.origin = NSPoint(x: 0, y: CGFloat(index) * DayEventRowView.rowHeight)
            doc.addSubview(row)
        }
        doc.frame = NSRect(x: 0, y: 0, width: width,
                           height: max(CGFloat(events.count) * DayEventRowView.rowHeight, scroll.bounds.height))
    }
}
