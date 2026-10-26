import AppKit
import Combine

/// A short announcement shown in a widened notch ("peek") without opening the island.
struct Activity: Equatable {
    let id = UUID()
    var symbol: String
    var tint: NSColor
    var title: String
    var subtitle: String
    var duration: TimeInterval = 3.5
}

/// Animated bars that dance while music plays. Pure Core Animation, so they keep moving on their own.
final class EqualizerView: NSView {
    private var bars: [CALayer] = []
    private(set) var running = false
    private let barWidth: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemPink.cgColor
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let gap = max((bounds.width - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1), 1)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (barWidth + gap) + barWidth / 2, y: bounds.midY)
        }
    }

    func start() {
        guard !running else { return }
        running = true
        for (index, bar) in bars.enumerated() {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.2
            animation.toValue = 0.65 + Double((index * 37) % 35) / 100
            animation.duration = 0.32 + Double((index * 53) % 40) / 100
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "dance")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for bar in bars { bar.removeAllAnimations() }
    }
}

/// Watches the Mac for things worth showing in the notch:
/// - ambient state (what is playing, battery level) that the closed notch can display all the time,
/// - one-off announcements (song change, charging, low battery, timer finished) shown as a peek.
/// It never opens the island.
final class ActivityMonitor {
    private weak var model: NotchModel?
    private var timer: Timer?

    private var sampledOnce = false
    private var lastCharging: Bool?
    private var announcedLow: Set<Int> = []
    private var lastTrackKey: String?

    init(model: NotchModel) {
        self.model = model
    }

    func start() {
        guard timer == nil else { return }
        model?.timer.onFinish = { [weak self] in self?.timerFinished() }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func post(_ activity: Activity) {
        guard let model, model.settings.activitiesEnabled else { return }
        model.activity = activity
    }

    private func tick() {
        guard let model else { return }
        let s = model.settings
        checkBattery(wantsAmbient: s.ambientBattery, wantsPeek: s.activitiesEnabled && s.activityBattery)
        checkMusic(wantsAmbient: s.ambientMusic, wantsPeek: s.activitiesEnabled && s.activityMusic)
        sampledOnce = true
    }

    // MARK: Battery

    private func checkBattery(wantsAmbient: Bool, wantsPeek: Bool) {
        guard let model else { return }
        guard wantsAmbient || wantsPeek, let battery = readBattery() else {
            if model.batteryLevel != nil { model.batteryLevel = nil }
            return
        }
        if model.batteryLevel != battery.level { model.batteryLevel = battery.level }
        if model.batteryCharging != battery.charging { model.batteryCharging = battery.charging }
        defer { lastCharging = battery.charging }
        guard wantsPeek else { return }

        if let was = lastCharging, was != battery.charging {
            if battery.charging {
                post(Activity(symbol: "bolt.fill", tint: .systemGreen, title: "Charging", subtitle: "\(battery.level)%"))
            } else {
                post(Activity(symbol: "battery.75", tint: .white, title: "On battery", subtitle: "\(battery.level)%"))
            }
        }

        if battery.charging || battery.level > 25 {
            announcedLow.removeAll()
            return
        }
        for threshold in [20, 10] where battery.level <= threshold && !announcedLow.contains(threshold) {
            announcedLow.insert(threshold)
            post(Activity(symbol: "battery.25", tint: .systemRed, title: "Low battery",
                          subtitle: "\(battery.level)% left", duration: 5))
            break
        }
    }

    // MARK: Music

    private func checkMusic(wantsAmbient: Bool, wantsPeek: Bool) {
        guard let model else { return }
        guard wantsAmbient || wantsPeek else {
            if model.ambientTrack != nil { model.ambientTrack = nil }
            if model.ambientArtwork != nil { model.ambientArtwork = nil }
            lastTrackKey = nil
            return
        }
        let track = model.nowPlaying.quickTrack()
        let key = track.map { "\($0.source.rawValue)|\($0.artist)|\($0.title)" }
        defer { lastTrackKey = key }

        if model.ambientTrack != track { model.ambientTrack = track }
        guard let track else {
            if model.ambientArtwork != nil { model.ambientArtwork = nil }
            return
        }

        if key != lastTrackKey {
            model.ambientArtwork = nil
            if let url = track.artworkURL {
                URLSession.shared.dataTask(with: url) { [weak self, weak model] data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard self?.lastTrackKey == key else { return }
                        model?.ambientArtwork = image
                    }
                }.resume()
            }
            // Don't announce whatever was already playing when the app started.
            if wantsPeek && sampledOnce {
                post(Activity(symbol: "music.note", tint: .systemPink, title: track.title, subtitle: track.artist))
            }
        }
    }

    // MARK: Timer

    private func timerFinished() {
        guard let model, model.settings.activityTimer else { return }
        let minutes = max(1, model.timer.total / 60)
        post(Activity(symbol: "timer", tint: .systemOrange, title: "Timer finished",
                      subtitle: "\(minutes) min", duration: 5))
    }
}
