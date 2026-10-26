import AppKit
import Combine

struct ClipItem: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let date: Date
    var pinned: Bool

    enum CodingKeys: String, CodingKey { case id, text, date, pinned }

    init(text: String, date: Date = Date(), id: UUID = UUID(), pinned: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.pinned = pinned
    }

    // Older saved history has no "pinned" field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// Keeps the text you copy. With "save history" on, it is written to
/// ~/Library/Application Support/NotchIsland/clipboard.json so it survives restarts, and old items are
/// dropped after the retention period you choose. Clear wipes memory and the file.
final class ClipboardStore: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var lastCopiedID: UUID?

    private var maxItems = 200
    private var persist = true
    private var retentionDays = 30          // 0 = keep forever
    private let maxLength = 2000
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NotchIsland", isDirectory: true)
            .appendingPathComponent("clipboard.json")
    }()

    // MARK: Configuration (from Settings)

    func configure(persist: Bool, retentionDays: Int, maxItems: Int) {
        let persistChanged = persist != self.persist
        self.persist = persist
        self.retentionDays = retentionDays
        self.maxItems = max(1, maxItems)

        if persistChanged {
            if persist {
                // Merge anything saved earlier with what is in memory, then save.
                mergeFromDisk()
            } else {
                deleteFile()
            }
        }
        prune()
        scheduleSave()
    }

    // MARK: Watching the pasteboard

    func start() {
        guard timer == nil else { return }
        if persist && items.isEmpty { mergeFromDisk() }
        prune()
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Respect password managers and other apps that flag sensitive/temporary copies.
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return
        }
        guard let raw = pasteboard.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        add(String(text.prefix(maxLength)))
    }

    private func add(_ text: String) {
        let wasPinned = items.first(where: { $0.text == text })?.pinned ?? false
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text, pinned: wasPinned), at: 0)
        prune()
        scheduleSave()
    }

    // MARK: Actions

    /// Put an item back on the system clipboard.
    func copy(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount // don't re-capture our own write

        items.removeAll { $0.id == item.id }
        items.insert(ClipItem(text: item.text, date: Date(), id: item.id, pinned: item.pinned), at: 0)
        scheduleSave()

        lastCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.lastCopiedID == item.id { self?.lastCopiedID = nil }
        }
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        prune()
        scheduleSave()
    }

    /// Forget everything except pinned items.
    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        if items.isEmpty { deleteFile() } else { scheduleSave() }
    }

    /// Forget everything (pinned too), including the copy on disk.
    func clear() {
        items.removeAll()
        deleteFile()
    }

    // MARK: Retention

    private func prune() {
        // Pinned items are never expired. Items are newest first.
        let cutoff: Date? = retentionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) : nil
        var unpinnedKept = 0
        let kept = items.filter { item in
            if item.pinned { return true }
            if let cutoff, item.date < cutoff { return false }
            unpinnedKept += 1
            return unpinnedKept <= maxItems
        }
        if kept != items { items = kept }
    }

    // MARK: Disk

    private func mergeFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([ClipItem].self, from: data) else { return }
        var merged = items
        for item in saved where !merged.contains(where: { $0.text == item.text }) {
            merged.append(item)
        }
        merged.sort { $0.date > $1.date }
        items = merged
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard persist else { return }
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeToDisk() {
        guard persist else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func deleteFile() {
        saveWork?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
