// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: ".",
            exclude: ["README.md", "LICENSE", "docs", "Resources", "build_app.sh", "RELEASE_NOTES.md", "NotchIsland.app"],
            sources: [
                "main.swift",
                "AppDelegate.swift",
                "NotchModel.swift",
                "NotchController.swift",
                "IslandView.swift",
                "IslandTabs.swift",
                "NowPlaying.swift",
                "CalendarStore.swift",
                "ClipboardStore.swift",
                "AppsStore.swift",
                "Controls.swift",
                "Weather.swift",
                "SystemStats.swift",
                "Launcher.swift",
                "Settings.swift",
                "IslandTabsMore.swift",
                "SettingsTab.swift",
                "Lyrics.swift",
                "Activities.swift",
                "CalendarMonthTab.swift",
                "Updater.swift",
            ]
        )
    ]
)
