import AppKit
import Combine

enum MusicSource: String {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var appName: String { self == .spotify ? "Spotify" : "Music" }
}

struct Track: Equatable {
    var source: MusicSource
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkURL: URL?
    var duration: Double = 0   // seconds
}

/// Reads and controls Spotify / Apple Music through AppleScript.
///
/// Apple's private MediaRemote framework no longer works for third-party apps on recent macOS,
/// so this talks to the players directly. The first query shows the standard
/// "wants to control Spotify/Music" Automation prompt.
final class NowPlayingStore: ObservableObject {
    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var permissionDenied = false
    @Published var lyrics: LyricsState = .idle

    /// Set from Settings. When off, nothing is fetched and no request leaves the Mac.
    var lyricsEnabled = true {
        didSet {
            guard oldValue != lyricsEnabled else { return }
            lyricsKey = nil
            updateLyrics(for: track)
        }
    }

    /// Optional Musixmatch key from Settings. A new key retries songs that were "not found" before.
    var musixmatchKey = "" {
        didSet {
            guard oldValue != musixmatchKey else { return }
            lyricsCache = lyricsCache.filter { $0.value != .notFound && $0.value != .failed }
            lyricsKey = nil
            updateLyrics(for: track)
        }
    }

    /// Last known playback position, so lyrics can follow the song between polls.
    private var position: Double = 0
    private var positionDate = Date()
    private var positions: [MusicSource: Double] = [:]
    private var lyricsKey: String?
    private var lyricsCache: [String: LyricsState] = [:]

    func currentPosition() -> Double {
        let elapsed = (track?.isPlaying ?? false) ? Date().timeIntervalSince(positionDate) : 0
        return position + elapsed
    }

    private var timer: Timer?
    private var artworkKey: String?
    private var lastErrorNumber: Int?

    // MARK: Polling

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func isRunning(_ source: MusicSource) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == source.rawValue }
    }

    func refresh() {
        var found: Track?
        var denied = false
        for source in [MusicSource.spotify, MusicSource.music] where isRunning(source) {
            lastErrorNumber = nil
            if let t = query(source) {
                if t.isPlaying { found = t; break }
                if found == nil { found = t }
            } else if lastErrorNumber == -1743 {
                denied = true
            }
        }
        if found != nil { denied = false }
        if permissionDenied != denied { permissionDenied = denied }
        if let found {
            position = positions[found.source] ?? 0
            positionDate = Date()
        }
        if found != track { track = found }
        updateArtwork(for: found)
        updateLyrics(for: found)
    }

    // MARK: Queries

    private func query(_ source: MusicSource) -> Track? {
        let script: String
        switch source {
        case .spotify:
            script = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                return (player state as string) & "||" & (name of current track) & "||" & (artist of current track) & "||" & (artwork url of current track) & "||" & ((player position as real) as string) & "||" & (((duration of current track) / 1000) as string)
            end tell
            """
        case .music:
            script = """
            tell application "Music"
                if player state is stopped then return "stopped"
                return (player state as string) & "||" & (name of current track) & "||" & (artist of current track) & "||" & "" & "||" & ((player position as real) as string) & "||" & ((duration of current track as real) as string)
            end tell
            """
        }
        guard let output = run(script) else { return nil }
        let parts = output.components(separatedBy: "||")
        guard parts.count >= 3 else { return nil }
        func number(_ index: Int) -> Double {
            guard parts.count > index else { return 0 }
            return Double(parts[index].replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        positions[source] = number(4)
        return Track(
            source: source,
            title: parts[1],
            artist: parts[2],
            isPlaying: parts[0] == "playing",
            artworkURL: parts.count > 3 ? URL(string: parts[3]) : nil,
            duration: number(5)
        )
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            lastErrorNumber = error[NSAppleScript.errorNumber] as? Int
            return nil
        }
        return result.stringValue ?? ""
    }

    // MARK: Controls

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    /// Jump to a point in the current song (both Spotify and Music support this).
    func seek(to seconds: Double) {
        guard let track else { return }
        var target = max(0, seconds)
        if track.duration > 0 { target = min(target, track.duration) }
        run("tell application \"\(track.source.appName)\" to set player position to \(Int(target.rounded()))")
        position = target
        positionDate = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    private func control(_ command: String) {
        guard let source = track?.source else { return }
        run("tell application \"\(source.appName)\" to \(command)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    // MARK: Artwork

    private func updateArtwork(for track: Track?) {
        guard let track else {
            artworkKey = nil
            if artwork != nil { artwork = nil }
            return
        }
        let key = "\(track.source.rawValue)|\(track.title)|\(track.artist)|\(track.artworkURL?.absoluteString ?? "")"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        switch track.source {
        case .spotify:
            guard let url = track.artworkURL else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    if self?.artworkKey == key { self?.artwork = image }
                }
            }.resume()
        case .music:
            // Best effort: raw artwork bytes from the current track. Falls back to the placeholder icon.
            let script = NSAppleScript(source: "tell application \"Music\" to return raw data of artwork 1 of current track")
            var error: NSDictionary?
            if let result = script?.executeAndReturnError(&error), error == nil,
               let image = NSImage(data: result.data), image.isValid {
                artwork = image
            }
        }
    }

    // MARK: Lyrics

    private func updateLyrics(for track: Track?) {
        guard lyricsEnabled else {
            lyricsKey = nil
            if lyrics != .off { lyrics = .off }
            return
        }
        guard let track else {
            lyricsKey = nil
            if lyrics != .idle { lyrics = .idle }
            return
        }
        let key = "\(track.artist)|\(track.title)|\(Int(track.duration.rounded()))"
        guard key != lyricsKey else { return }
        lyricsKey = key

        if let cached = lyricsCache[key] {
            lyrics = cached
            return
        }
        // Apple Music: lyrics stored in the song file itself (library songs) are read locally first.
        if track.source == .music,
           let embedded = run("tell application \"Music\" to return lyrics of current track"),
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let state = LyricsState.plain(embedded.trimmingCharacters(in: .whitespacesAndNewlines))
            lyricsCache[key] = state
            lyrics = state
            return
        }
        lyrics = .loading
        LyricsClient.fetch(title: track.title, artist: track.artist, duration: track.duration,
                           musixmatchKey: musixmatchKey) { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.lyricsKey == key, self.lyricsEnabled else { return }
                if state != .failed { self.lyricsCache[key] = state }
                self.lyrics = state
            }
        }
    }
}
