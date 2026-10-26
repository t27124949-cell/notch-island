import AppKit
import Combine
import ServiceManagement

/// User preferences, saved in UserDefaults. Every tab can be switched off except Settings itself.
final class SettingsStore: ObservableObject {
    static let defaultOpenDelay = 0.08
    static let defaultCloseDelay = 0.25
    static let defaultHotZonePadding = 80.0
    static let defaultClipboardItems = 200
    static let defaultClipboardDays = 30
    static let defaultFocusModes = "Do Not Disturb, Work, Personal, Sleep"

    @Published var disabledTabs: Set<String> { didSet { save() } }
    @Published var clickToOpen: Bool { didSet { save() } }
    @Published var openDelay: Double { didSet { save() } }
    @Published var closeDelay: Double { didSet { save() } }
    @Published var hotZonePadding: Double { didSet { save() } }
    @Published var clickOutsideCloses: Bool { didSet { save() } }
    @Published var startTab: String { didSet { save() } }          // "last" or a NotchTab raw value
    @Published var use24Hour: Bool { didSet { save() } }
    @Published var showLyrics: Bool { didSet { save() } }
    @Published var activitiesEnabled: Bool { didSet { save() } }   // live previews in the notch
    @Published var activityMusic: Bool { didSet { save() } }
    @Published var activityBattery: Bool { didSet { save() } }
    @Published var activityTimer: Bool { didSet { save() } }
    @Published var ambientMusic: Bool { didSet { save() } }        // equalizer in the closed notch while playing
    @Published var ambientBattery: Bool { didSet { save() } }      // battery level in the closed notch when idle
    @Published var focusModes: String { didSet { save() } }        // comma-separated Focus names
    @Published var musixmatchKey: String { didSet { save() } }     // optional; kept even on reset
    @Published var clipboardMaxItems: Int { didSet { save() } }
    @Published var clipboardPersist: Bool { didSet { save() } }     // keep history on disk between launches
    @Published var clipboardRetentionDays: Int { didSet { save() } } // 0 = keep forever

    init() {
        let d = UserDefaults.standard
        disabledTabs = Set(d.stringArray(forKey: "disabledTabs") ?? [])
        clickToOpen = d.bool(forKey: "clickToOpen")
        openDelay = d.object(forKey: "openDelay") as? Double ?? SettingsStore.defaultOpenDelay
        closeDelay = d.object(forKey: "closeDelay") as? Double ?? SettingsStore.defaultCloseDelay
        hotZonePadding = d.object(forKey: "hotZonePadding") as? Double ?? SettingsStore.defaultHotZonePadding
        clickOutsideCloses = d.object(forKey: "clickOutsideCloses") as? Bool ?? true
        startTab = d.string(forKey: "startTab") ?? "last"
        use24Hour = d.bool(forKey: "use24Hour")
        showLyrics = d.object(forKey: "showLyrics") as? Bool ?? true
        activitiesEnabled = d.object(forKey: "activitiesEnabled") as? Bool ?? true
        activityMusic = d.object(forKey: "activityMusic") as? Bool ?? true
        activityBattery = d.object(forKey: "activityBattery") as? Bool ?? true
        activityTimer = d.object(forKey: "activityTimer") as? Bool ?? true
        ambientMusic = d.object(forKey: "ambientMusic") as? Bool ?? true
        ambientBattery = d.object(forKey: "ambientBattery") as? Bool ?? true
        focusModes = d.string(forKey: "focusModes") ?? SettingsStore.defaultFocusModes
        musixmatchKey = d.string(forKey: "musixmatchKey") ?? ""
        clipboardMaxItems = d.object(forKey: "clipboardMaxItems") as? Int ?? SettingsStore.defaultClipboardItems
        clipboardPersist = d.object(forKey: "clipboardPersist") as? Bool ?? true
        clipboardRetentionDays = d.object(forKey: "clipboardRetentionDays") as? Int ?? SettingsStore.defaultClipboardDays
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Array(disabledTabs), forKey: "disabledTabs")
        d.set(clickToOpen, forKey: "clickToOpen")
        d.set(openDelay, forKey: "openDelay")
        d.set(closeDelay, forKey: "closeDelay")
        d.set(hotZonePadding, forKey: "hotZonePadding")
        d.set(clickOutsideCloses, forKey: "clickOutsideCloses")
        d.set(startTab, forKey: "startTab")
        d.set(use24Hour, forKey: "use24Hour")
        d.set(showLyrics, forKey: "showLyrics")
        d.set(activitiesEnabled, forKey: "activitiesEnabled")
        d.set(activityMusic, forKey: "activityMusic")
        d.set(activityBattery, forKey: "activityBattery")
        d.set(activityTimer, forKey: "activityTimer")
        d.set(ambientMusic, forKey: "ambientMusic")
        d.set(ambientBattery, forKey: "ambientBattery")
        d.set(focusModes, forKey: "focusModes")
        d.set(musixmatchKey, forKey: "musixmatchKey")
        d.set(clipboardMaxItems, forKey: "clipboardMaxItems")
        d.set(clipboardPersist, forKey: "clipboardPersist")
        d.set(clipboardRetentionDays, forKey: "clipboardRetentionDays")
    }

    // MARK: Tabs

    func isEnabled(_ tab: NotchTab) -> Bool {
        tab == .settings || !disabledTabs.contains(tab.rawValue)
    }

    func setEnabled(_ tab: NotchTab, _ enabled: Bool) {
        guard tab != .settings else { return }
        var updated = disabledTabs
        if enabled { updated.remove(tab.rawValue) } else { updated.insert(tab.rawValue) }
        disabledTabs = updated
    }

    /// Which tab to show when the island opens.
    func tabToOpen(lastTab: NotchTab) -> NotchTab {
        if startTab != "last", let tab = NotchTab(rawValue: startTab), isEnabled(tab) {
            return tab
        }
        return isEnabled(lastTab) ? lastTab : .settings
    }

    // MARK: Reset

    func resetToDefaults() {
        disabledTabs = []
        clickToOpen = false
        openDelay = SettingsStore.defaultOpenDelay
        closeDelay = SettingsStore.defaultCloseDelay
        hotZonePadding = SettingsStore.defaultHotZonePadding
        clickOutsideCloses = true
        startTab = "last"
        use24Hour = false
        activitiesEnabled = true
        activityMusic = true
        activityBattery = true
        activityTimer = true
        ambientMusic = true
        ambientBattery = true
        focusModes = SettingsStore.defaultFocusModes
        showLyrics = true
        clipboardMaxItems = SettingsStore.defaultClipboardItems
        clipboardPersist = true
        clipboardRetentionDays = SettingsStore.defaultClipboardDays
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message if macOS refused (for example when not running from the .app bundle).
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
