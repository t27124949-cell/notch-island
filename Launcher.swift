import AppKit
import Combine

struct LauncherApp: Identifiable {
    let name: String
    let url: URL
    var id: String { url.path }
}

/// Finds installed apps for the quick launcher and remembers favorites.
final class LauncherStore: ObservableObject {
    @Published var apps: [LauncherApp] = []
    @Published var favorites: [String]   // app bundle paths

    private let defaults = UserDefaults.standard

    init() {
        favorites = defaults.stringArray(forKey: "launcherFavorites") ?? []
        scan()
    }

    private func scan() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fileManager = FileManager.default
            let roots = [
                "/Applications",
                "/Applications/Utilities",
                "/System/Applications",
                "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications",
            ]
            var seen = Set<String>()
            var found: [LauncherApp] = []
            for root in roots {
                guard let items = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let path = root + "/" + item
                    if seen.insert(path).inserted {
                        found.append(LauncherApp(name: String(item.dropLast(4)), url: URL(fileURLWithPath: path)))
                    }
                }
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.apps = found }
        }
    }

    var favoriteApps: [LauncherApp] {
        favorites.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            return LauncherApp(name: url.deletingPathExtension().lastPathComponent, url: url)
        }
    }

    func search(_ query: String) -> [LauncherApp] {
        let needle = query.lowercased()
        let prefix = apps.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = apps.filter { !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle) }
        return Array((prefix + contains).prefix(30))
    }

    func isFavorite(_ app: LauncherApp) -> Bool {
        favorites.contains(app.url.path)
    }

    func toggleFavorite(_ app: LauncherApp) {
        if let index = favorites.firstIndex(of: app.url.path) {
            favorites.remove(at: index)
        } else {
            favorites.append(app.url.path)
        }
        defaults.set(favorites, forKey: "launcherFavorites")
    }

    func launch(_ app: LauncherApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
