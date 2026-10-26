import AppKit
import Combine
import IOKit.ps

enum NotchTab: String, CaseIterable {
    // The order here is the order of the tab bar.
    case home, controls, apps, launcher, nowPlaying, calendar, weather
    case shelf, timer, clipboard, notes, stats, settings

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .controls: return "slider.horizontal.3"
        case .apps: return "square.grid.2x2.fill"
        case .launcher: return "magnifyingglass"
        case .nowPlaying: return "music.note"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .shelf: return "tray.fill"
        case .timer: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        case .stats: return "cpu"
        case .settings: return "gearshape.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .controls: return "Quick Controls"
        case .apps: return "Open Apps"
        case .launcher: return "Launcher"
        case .nowPlaying: return "Now Playing"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .shelf: return "Shelf"
        case .timer: return "Timer"
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        case .stats: return "System Stats"
        case .settings: return "Settings"
        }
    }
}

/// Shared state for the notch UI.
final class NotchModel: ObservableObject {
    @Published var isOpen = false
    @Published var isPinned = false
    @Published var tab: NotchTab = .home {
        didSet { islandHeight = NotchModel.openHeight(for: tab) }
    }
    /// Height of the open island for the current tab. Short tabs get a short island.
    @Published var islandHeight: CGFloat = NotchModel.openHeight(for: .home)
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var shelf: [URL] = []
    /// The latest live-activity announcement (shown briefly in the notch).
    @Published var activity: Activity?
    /// Ambient state shown by the closed notch: what is playing, and the battery.
    @Published var ambientTrack: Track?
    @Published var ambientArtwork: NSImage?
    @Published var batteryLevel: Int?
    @Published var batteryCharging = false

    let settings = SettingsStore()
    let timer = FocusTimer()
    let nowPlaying = NowPlayingStore()
    let calendar = CalendarStore()
    let clipboard = ClipboardStore()
    let apps = AppsStore()
    let controls = ControlsStore()
    let weather = WeatherStore()
    let stats = StatsStore()
    let launcher = LauncherStore()

    /// Total size of the expanded island (height includes the notch area).
    let openSize = CGSize(width: 680, height: 230)

    /// How tall the open island is for each tab (the notch row is included). Never above `openSize.height`.
    static func openHeight(for tab: NotchTab) -> CGFloat {
        switch tab {
        case .home: return 150
        case .timer: return 170
        case .apps: return 180
        case .shelf: return 200
        case .nowPlaying: return 210
        default: return 230
        }
    }

    private var settingsObserver: AnyCancellable?

    init() {
        settingsObserver = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
        applySettings()
    }

    /// Push settings into the parts of the app that run in the background.
    func applySettings() {
        clipboard.configure(persist: settings.clipboardPersist,
                            retentionDays: settings.clipboardRetentionDays,
                            maxItems: settings.clipboardMaxItems)
        controls.focusModes = ControlsStore.parseFocusModes(settings.focusModes)
        nowPlaying.musixmatchKey = settings.musixmatchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        nowPlaying.lyricsEnabled = settings.showLyrics && settings.isEnabled(.nowPlaying)
        if settings.isEnabled(.clipboard) {
            clipboard.start() // history is captured even while the island is closed
        } else {
            clipboard.stop()
        }
        if !settings.isEnabled(tab), let first = NotchTab.allCases.first(where: { settings.isEnabled($0) }) {
            tab = first
        }
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned { isOpen = true }
    }

    /// Close immediately (used for clicks outside the island).
    func dismiss() {
        isPinned = false
        isOpen = false
    }

    // MARK: Shelf

    func addToShelf(_ urls: [URL]) {
        for url in urls where !shelf.contains(url) {
            shelf.append(url)
        }
    }

    func remove(_ url: URL) {
        shelf.removeAll { $0 == url }
    }
}

/// Simple countdown timer.
final class FocusTimer: ObservableObject {
    @Published var remaining = 25 * 60
    @Published var total = 25 * 60
    @Published var running = false
    private var timer: Timer?
    /// Called once when the countdown reaches zero.
    var onFinish: (() -> Void)?

    func set(minutes: Int) {
        stop()
        total = minutes * 60
        remaining = total
    }

    func toggle() { running ? stop() : start() }

    func start() {
        if remaining <= 0 { remaining = total }
        running = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    func reset() {
        stop()
        remaining = total
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            remaining = 0
            stop()
            NSSound.beep()
            onFinish?()
        }
    }

    var display: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    var progress: Double {
        total == 0 ? 0 : 1 - Double(remaining) / Double(total)
    }
}

/// Battery percentage + charging state, via IOKit.
func readBattery() -> (level: Int, charging: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let current = desc[kIOPSCurrentCapacityKey] as? Int,
              let maximum = desc[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        return (current * 100 / maximum, charging)
    }
    return nil
}
