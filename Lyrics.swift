import AppKit

struct LyricLine: Equatable {
    let time: Double
    let text: String
}

enum LyricsState: Equatable {
    case off
    case idle
    case loading
    case synced([LyricLine])
    case plain(String)
    case notFound
    case failed
}

/// Looks lyrics up online, trying several spellings of the song and two free sources in turn:
/// LRCLIB (https://lrclib.net, often with timed lyrics) and lyrics.ovh (plain text). No account or key.
/// Only the artist, title and track length are sent.
enum LyricsClient {
    private enum Outcome {
        case found(LyricsState)
        case miss      // the service answered but has nothing
        case offline   // no answer at all
    }

    static func fetch(title: String, artist: String, duration: Double, musixmatchKey: String = "",
                      completion: @escaping (LyricsState) -> Void) {
        let cleanTitle = clean(title: title)
        let primary = primaryArtist(artist)
        let length: Double? = duration > 0 ? duration : nil

        var steps: [(@escaping (Outcome) -> Void) -> Void] = []
        steps.append { done in lrclibGet(artist: artist, title: title, duration: length, done) }
        if cleanTitle != title || primary != artist {
            steps.append { done in lrclibGet(artist: primary, title: cleanTitle, duration: length, done) }
        }
        steps.append { done in lrclibGet(artist: primary, title: cleanTitle, duration: nil, done) }
        steps.append { done in lrclibSearch(query: "\(primary) \(cleanTitle)", duration: length, done) }
        steps.append { done in lrclibSearch(query: cleanTitle, artist: primary, duration: length, done) }
        steps.append { done in lyricsOvh(artist: primary, title: cleanTitle, done) }
        if primary != artist {
            steps.append { done in lyricsOvh(artist: artist, title: cleanTitle, done) }
        }
        if !musixmatchKey.isEmpty {
            // Last resort: the free Musixmatch plan only returns the first part of a song.
            steps.append { done in musixmatch(artist: primary, title: cleanTitle, key: musixmatchKey, done) }
        }

        func run(_ index: Int, heardBack: Bool) {
            guard index < steps.count else { return completion(heardBack ? .notFound : .failed) }
            let step = steps[index]
            step { outcome in
                switch outcome {
                case .found(let state): completion(state)
                case .miss: run(index + 1, heardBack: true)
                case .offline: run(index + 1, heardBack: heardBack)
                }
            }
        }
        run(0, heardBack: false)
    }

    // MARK: Cleaning up names

    /// "Song (feat. X) - Remastered 2020" -> "Song"
    static func clean(title: String) -> String {
        var text = title
        text = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let range = text.range(of: " - ") { text = String(text[..<range.lowerBound]) }
        for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            if let range = text.range(of: marker, options: .caseInsensitive) { text = String(text[..<range.lowerBound]) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "Burna Boy, Wizkid" or "Davido & Fall" -> the first artist.
    static func primaryArtist(_ artist: String) -> String {
        var first = artist
        for separator in [", ", " & ", " feat.", " feat ", " ft.", " ft ", " x ", " X ", " and ", ";", " / "] {
            if let range = first.range(of: separator, options: .caseInsensitive) { first = String(first[..<range.lowerBound]) }
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }

    // MARK: Sources

    private static func lrclibGet(artist: String, title: String, duration: Double?,
                                  _ done: @escaping (Outcome) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let duration { components.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        request(components.url) { data, status in
            if status == 0 { return done(.offline) }
            if status == 200, let data, let state = parse(object: try? JSONSerialization.jsonObject(with: data)) {
                return done(.found(state))
            }
            done(.miss)
        }
    }

    private static func lrclibSearch(query: String? = nil, artist: String? = nil, duration: Double?,
                                     _ done: @escaping (Outcome) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var items: [URLQueryItem] = []
        if let artist {
            items.append(URLQueryItem(name: "track_name", value: query ?? ""))
            items.append(URLQueryItem(name: "artist_name", value: artist))
        } else {
            items.append(URLQueryItem(name: "q", value: query ?? ""))
        }
        components.queryItems = items
        request(components.url) { data, status in
            if status == 0 { return done(.offline) }
            guard status == 200, let data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return done(.miss) }
            let close = list.filter { entry in
                guard let duration, let d = entry["duration"] as? Double else { return true }
                return abs(d - duration) < 8
            }
            let hasSynced: ([String: Any]) -> Bool = { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            for entry in close.filter(hasSynced) + close.filter({ !hasSynced($0) }) {
                if let state = parse(object: entry) { return done(.found(state)) }
            }
            done(.miss)
        }
    }

    private static func lyricsOvh(artist: String, title: String, _ done: @escaping (Outcome) -> Void) {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let a = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let t = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)") else { return done(.miss) }
        request(url, timeout: 8) { data, status in
            if status == 0 { return done(.offline) }
            guard status == 200, let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var text = object["lyrics"] as? String else { return done(.miss) }
            if text.hasPrefix("Paroles de la chanson"), let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            done(text.isEmpty ? .miss : .found(.plain(text)))
        }
    }

    private static func musixmatch(artist: String, title: String, key: String, _ done: @escaping (Outcome) -> Void) {
        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/matcher.lyrics.get")!
        components.queryItems = [
            URLQueryItem(name: "q_track", value: title),
            URLQueryItem(name: "q_artist", value: artist),
            URLQueryItem(name: "apikey", value: key),
        ]
        request(components.url) { data, status in
            if status == 0 { return done(.offline) }
            guard status == 200, let data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let body = message["body"] as? [String: Any],
                  let lyrics = body["lyrics"] as? [String: Any],
                  var text = lyrics["lyrics_body"] as? String else { return done(.miss) }
            // Drop Musixmatch's licence footer ("*******...") and say the text is partial.
            if let marker = text.range(of: "*******") { text = String(text[..<marker.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            done(text.isEmpty ? .miss : .found(.plain(text + "\n\n… (partial, from the free Musixmatch plan)")))
        }
    }

    private static func request(_ url: URL?, timeout: TimeInterval = 10, _ done: @escaping (Data?, Int) -> Void) {
        guard let url else { return done(nil, 1) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("NotchIsland/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(error == nil ? data : nil, status)
        }.resume()
    }

    private static func parse(object: Any?) -> LyricsState? {
        guard let dict = object as? [String: Any] else { return nil }
        if let synced = dict["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = dict["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain)
        }
        return nil
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        guard let tag = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#) else { return [] }
        var result: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard !matches.isEmpty else { continue }
            let lyric = tag.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: line.length),
                                                     withTemplate: "").trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(line.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(line.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                result.append(LyricLine(time: minutes * 60 + seconds, text: lyric.isEmpty ? "♪" : lyric))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

/// Shows lyrics: a five-line window that follows the song for synced lyrics, or a scrolling page for plain ones.
final class LyricsView: NSView {
    override var isFlipped: Bool { true }

    private var state: LyricsState = .idle
    private var lines: [LyricLine] = []
    private let rows: [NSTextField] = (0..<5).map { _ in UI.label("", size: 12, alignment: .center) }
    private let message = UI.label("", size: 12, color: UI.dim(0.5), alignment: .center, lines: 2)
    private let scroll = UI.scrollView(horizontal: false)
    private let plainLabel = UI.label("", size: 12, color: UI.dim(0.8), lines: 0)
    private let plainDoc = FlippedView()
    private let badge = UI.label("Not synced · estimated scroll", size: 9, color: UI.dim(0.4), alignment: .right)
    private var shownIndex = Int.min
    private var manualScrollUntil = Date.distantPast
    private var scrollObserver: NSObjectProtocol?
    private let rowHeight: CGFloat = 28

    /// Set from Settings: scroll lyrics that have no timing, based on how far through the song we are.
    var autoScrollPlain = true {
        didSet { if oldValue != autoScrollPlain { refreshBadge() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for row in rows {
            row.wantsLayer = true
            addSubview(row)
        }
        addSubview(message)
        plainDoc.addSubview(plainLabel)
        scroll.documentView = plainDoc
        addSubview(scroll)
        addSubview(badge)          // after the scroll view so it sits on top
        badge.isHidden = true
        // If the person scrolls by hand, leave the scroll position alone for a while.
        scrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                                                object: scroll, queue: .main) { [weak self] _ in
            self?.manualScrollUntil = Date().addingTimeInterval(8)
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layoutAll()
    }

    func layoutAll() {
        let rowH = rowHeight
        let top = (bounds.height - rowH * 5) / 2
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: top + CGFloat(i) * rowH, width: bounds.width, height: rowH)
            row.cell?.truncatesLastVisibleLine = true
        }
        message.frame = NSRect(x: 8, y: (bounds.height - 34) / 2, width: bounds.width - 16, height: 34)
        scroll.frame = bounds
        badge.frame = NSRect(x: 0, y: bounds.height - 14, width: bounds.width - 6, height: 12)
        layoutPlain()
    }

    private func refreshBadge() {
        var isPlain = false
        if case .plain = state { isPlain = true }
        badge.isHidden = !(isPlain && autoScrollPlain)
    }

    /// Estimated scrolling for lyrics without timing. Intros and outros are skipped over a little, but
    /// long breaks and repeated choruses will drift, which is why this is labelled as an estimate.
    /// Timing nudge in seconds from the settings slider.
    var offset: Double = 0

    func updatePlain(position: Double, duration: Double) {
        guard case .plain = state, autoScrollPlain, duration > 1 else { return }
        guard Date() >= manualScrollUntil else { return }
        let overflow = max(plainDoc.frame.height - scroll.bounds.height, 0)
        guard overflow > 0 else { return }
        let fraction = min(max(position / duration, 0), 1)
        let progress = min(max((fraction - 0.08) / 0.84, 0), 1)   // lyrics rarely start at 0:00 or run to the very end
        let target = CGFloat(progress) * overflow
        let clip = scroll.contentView
        if abs(clip.bounds.origin.y - target) < 0.5 { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        scroll.reflectScrolledClipView(clip)
    }

    private func layoutPlain() {
        let width = max(bounds.width - 12, 10)
        let text = plainLabel.stringValue as NSString
        let height = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin],
                                       attributes: [.font: plainLabel.font ?? NSFont.systemFont(ofSize: 12)]).height
        plainLabel.frame = NSRect(x: 0, y: 4, width: width, height: ceil(height) + 4)
        plainDoc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ceil(height) + 16)
    }

    func set(_ newState: LyricsState) {
        guard newState != state else { return }
        state = newState
        shownIndex = Int.min
        lines = []
        var note: String?
        switch newState {
        case .off, .idle: note = nil
        case .loading: note = "Looking for lyrics…"
        case .notFound: note = "No lyrics found for this song"
        case .failed: note = "Couldn't load lyrics (are you online?)"
        case .synced(let l): lines = l
        case .plain(let text):
            plainLabel.stringValue = text
            layoutPlain()
            scroll.contentView.scroll(to: .zero)
        }
        message.stringValue = note ?? ""
        message.isHidden = note == nil
        let isSynced: Bool = { if case .synced = newState { return true } else { return false } }()
        let isPlain: Bool = { if case .plain = newState { return true } else { return false } }()
        for row in rows { row.isHidden = !isSynced }
        scroll.isHidden = !isPlain
        refreshBadge()
        if isSynced { setPosition(0) }
    }

    /// Highlight the line being sung at `seconds`. When the song moves on by one line the rows glide up
    /// and the new line fades in; jumps (seeking, a new song) change instantly.
    func setPosition(_ rawSeconds: Double) {
        guard !lines.isEmpty else { return }
        let seconds = rawSeconds + offset   // the person's timing nudge (+ = lines appear sooner)
        var current = -1
        for (i, line) in lines.enumerated() where line.time <= seconds + 0.25 { current = i }
        guard current != shownIndex else { return }
        let animate = shownIndex != Int.min && current == shownIndex + 1 && window != nil
        shownIndex = current
        for (slot, row) in rows.enumerated() {
            let index = current + slot - 2
            let isCurrent = slot == 2
            row.stringValue = (index >= 0 && index < lines.count) ? lines[index].text : ""
            row.font = NSFont.systemFont(ofSize: isCurrent ? 15 : 12, weight: isCurrent ? .semibold : .regular)
            let distance = abs(slot - 2)
            row.textColor = isCurrent ? .white : UI.dim(distance == 1 ? 0.5 : 0.28)
        }
        guard animate else {
            for row in rows { row.alphaValue = 1 }
            layoutAll()
            return
        }
        // Start every row one row lower (this view is flipped, so a bigger y is lower on screen) and let it glide up.
        let top = (bounds.height - rowHeight * 5) / 2
        for (slot, row) in rows.enumerated() {
            let finalFrame = NSRect(x: 0, y: top + CGFloat(slot) * rowHeight, width: bounds.width, height: rowHeight)
            row.frame = finalFrame.offsetBy(dx: 0, dy: rowHeight)
            row.alphaValue = slot == 4 ? 0 : (slot == 2 ? 0.55 : 1)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            for (slot, row) in rows.enumerated() {
                row.animator().frame = NSRect(x: 0, y: top + CGFloat(slot) * rowHeight, width: bounds.width, height: rowHeight)
                row.animator().alphaValue = 1
            }
        }
    }
}
