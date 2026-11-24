import AppKit

/// Lyrics timed by the person, saved on this Mac. They win over online lyrics for that song.
enum SyncedLyricsStorage {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchIsland/synced", isDirectory: true)
    }

    /// A stable file name for a song (Swift's own hashValue changes on every launch, so it can't be used).
    private static func file(_ key: String) -> URL {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return folder.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    static func exists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: file(key).path)
    }

    static func load(_ key: String) -> [LyricLine]? {
        guard let data = try? Data(contentsOf: file(key)),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let lines = items.compactMap { item -> LyricLine? in
            guard let time = item["t"] as? Double, let text = item["s"] as? String else { return nil }
            return LyricLine(time: time, text: text)
        }
        return lines.isEmpty ? nil : lines
    }

    static func save(_ lines: [LyricLine], key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let items = lines.map { ["t": $0.time, "s": $0.text] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: items) {
            try? data.write(to: file(key), options: .atomic)
        }
    }
}

/// Tap-to-sync: the song plays and the person taps each time a line starts. Shown in place of the lyrics.
final class LyricsSyncView: NSView {
    override var isFlipped: Bool { true }

    private let counter = UI.label("", size: 10, color: UI.dim(0.5))
    private let current = UI.label("", size: 15, weight: .bold, lines: 3)
    private let next = UI.label("", size: 12, color: UI.dim(0.45), lines: 2)
    private let undoButton = ClosureButton(frame: .zero)
    private let cancelButton = ClosureButton(frame: .zero)
    private let tapButton = ClosureButton.pill("Tap as the line starts", size: 12, fill: NSColor.systemBlue, height: 34) {}

    private var texts: [String] = []
    private var times: [Double] = []

    /// The song's current position in seconds.
    var position: () -> Double = { 0 }
    var onFinish: (([LyricLine]) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        current.cell?.truncatesLastVisibleLine = true
        next.cell?.truncatesLastVisibleLine = true
        undoButton.setText("Undo", size: 10, weight: .medium, color: UI.dim(0.6))
        cancelButton.setText("Cancel", size: 10, weight: .medium, color: UI.dim(0.6))
        undoButton.handler = { [weak self] in self?.undo() }
        cancelButton.handler = { [weak self] in self?.onCancel?() }
        tapButton.handler = { [weak self] in self?.tap() }
        for view in [counter, current, next, undoButton, cancelButton, tapButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin(texts: [String]) {
        self.texts = texts
        times = []
        refresh()
    }

    func layoutAll() {
        let w = bounds.width
        counter.frame = NSRect(x: 0, y: 0, width: max(w - 100, 10), height: 14)
        cancelButton.frame = NSRect(x: w - 44, y: 0, width: 44, height: 14)
        undoButton.frame = NSRect(x: w - 88, y: 0, width: 40, height: 14)
        current.frame = NSRect(x: 0, y: 22, width: w, height: 62)
        next.frame = NSRect(x: 0, y: 86, width: w, height: 32)
        tapButton.frame = NSRect(x: 0, y: max(bounds.height - 40, 120), width: min(w, 200), height: 34)
    }

    private func refresh() {
        let index = times.count
        guard index < texts.count else { return }
        counter.stringValue = "Line \(index + 1) of \(texts.count)"
        current.stringValue = texts[index]
        next.stringValue = index + 1 < texts.count ? texts[index + 1] : ""
        undoButton.isHidden = times.isEmpty
    }

    private func tap() {
        guard times.count < texts.count else { return }
        // People tap a moment after they hear the line, so the time is nudged earlier.
        var time = max(position() - 0.2, 0)
        if let last = times.last, time <= last { time = last + 0.05 }
        times.append(time)
        if times.count == texts.count {
            let lines = zip(times, texts).map { LyricLine(time: $0, text: $1) }
            onFinish?(lines)
        } else {
            refresh()
        }
    }

    private func undo() {
        guard !times.isEmpty else { return }
        times.removeLast()
        refresh()
    }
}
