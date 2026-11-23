import AppKit
import EventKit
import Combine

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    var joinURL: URL? = nil   // Zoom / Meet / Teams link found in the event
}

enum CalendarAccess {
    case unknown, granted, denied
}

/// Upcoming events (now through the end of tomorrow) from the user's calendars, via EventKit.
final class CalendarStore: ObservableObject {
    @Published var events: [CalendarEvent] = []
    @Published var access: CalendarAccess = .unknown

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        updateAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: access = .unknown
        case .denied, .restricted: access = .denied
        default: access = .granted // fullAccess (macOS 14+) / authorized (macOS 13)
        }
    }

    func requestAccess() {
        // Menu-bar-only apps aren't frontmost, so bring the app forward for the permission prompt.
        NSApp.activate(ignoringOtherApps: true)
        let handler: (Bool, Error?) -> Void = { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                if granted { self?.refresh() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    func refresh() {
        updateAccess()
        guard access == .granted else {
            events = []
            return
        }
        let now = Date()
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        events = found.prefix(10).map(makeEvent)
    }

    private func makeEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            color: event.calendar.color ?? NSColor.systemBlue,
            joinURL: CalendarStore.joinLink(in: event)
        )
    }

    /// A video-call link in the event's location, notes or URL.
    private static func joinLink(in event: EKEvent) -> URL? {
        let texts = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        let pattern = #"https?://[^\s<>"']*(zoom\.us|zoomgov\.com|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com)[^\s<>"']*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                let link = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))
                return URL(string: link)
            }
        }
        return nil
    }

    /// Everything on one calendar day, all-day events first.
    func events(on day: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .map(makeEvent)
    }

    /// The days between `first` and `last` (inclusive) that have at least one event, as start-of-day dates.
    func daysWithEvents(from first: Date, to last: Date) -> Set<Date> {
        guard access == .granted else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: first)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var days = Set<Date>()
        for event in store.events(matching: predicate) {
            var day = max(calendar.startOfDay(for: event.startDate), start)
            // An event that ends exactly at midnight does not belong to the next day.
            let lastMoment = event.endDate > event.startDate ? event.endDate.addingTimeInterval(-1) : event.startDate
            while day <= lastMoment && day < end {
                days.insert(calendar.startOfDay(for: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }
}
