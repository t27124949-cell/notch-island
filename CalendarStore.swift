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

        events = found.prefix(10).map { event in
            CalendarEvent(
                id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                color: event.calendar.color ?? NSColor.systemBlue
            )
        }
    }
}
