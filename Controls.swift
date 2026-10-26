import AppKit
import Combine

/// Runs AppleScript source and returns its string result (nil on error).
@discardableResult
func runAppleScript(_ source: String) -> String? {
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if error != nil { return nil }
    return result.stringValue ?? ""
}

/// Runs a command-line tool and returns its standard output (nil if it can't be launched).
func runProcess(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// Native quick controls that replace the usual menu bar toggles: volume, Wi-Fi, dark mode,
/// keep-awake and sleep-display. Only uses public tools (AppleScript, networksetup, caffeinate, pmset).
final class ControlsStore: ObservableObject {
    @Published var volume: Double = 50          // 0...100
    @Published var volumeAvailable = true
    @Published var muted = false
    @Published var wifiOn: Bool?                // nil = unknown / no Wi-Fi hardware
    @Published var darkMode = false
    @Published var keepAwake = false

    private var wifiDevice: String?
    private var caffeinate: Process?

    init() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = runProcess("/usr/sbin/networksetup", ["-listallhardwareports"]) ?? ""
            var device: String?
            var inWifi = false
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("Hardware Port:") {
                    inWifi = line.contains("Wi-Fi") || line.contains("AirPort")
                } else if inWifi, line.hasPrefix("Device:") {
                    device = line.replacingOccurrences(of: "Device:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            DispatchQueue.main.async {
                self?.wifiDevice = device
                self?.refresh()
            }
        }
        refresh()
    }

    // MARK: Reading state

    func refresh() {
        darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        keepAwake = caffeinate?.isRunning ?? false

        let script = """
        set s to get volume settings
        return ((output volume of s) as string) & "|" & ((output muted of s) as string)
        """
        if let result = runAppleScript(script) {
            let parts = result.components(separatedBy: "|")
            if parts.count == 2, let level = Double(parts[0]) {
                volume = level
                muted = (parts[1] == "true")
                volumeAvailable = true
            } else {
                volumeAvailable = false // e.g. an HDMI output with no software volume
            }
        }

        if let device = wifiDevice {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let output = runProcess("/usr/sbin/networksetup", ["-getairportpower", device]) ?? ""
                let isOn = output.contains(": On")
                let isOff = output.contains(": Off")
                DispatchQueue.main.async {
                    if isOn { self?.wifiOn = true } else if isOff { self?.wifiOn = false }
                }
            }
        } else {
            wifiOn = nil
        }
    }

    // MARK: Actions

    func setVolume(_ value: Double) {
        let level = Int(max(0, min(100, value)).rounded())
        volume = Double(level)
        if muted && level > 0 { muted = false }
        runAppleScript("set volume output volume \(level)")
    }

    func toggleMute() {
        let newValue = !muted
        muted = newValue
        runAppleScript("set volume output muted \(newValue)")
    }

    func toggleWifi() {
        guard let device = wifiDevice, let isOn = wifiOn else { return }
        wifiOn = !isOn // optimistic; confirmed by the refresh below
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = runProcess("/usr/sbin/networksetup", ["-setairportpower", device, isOn ? "off" : "on"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
        }
    }

    func toggleDarkMode() {
        darkMode.toggle()
        runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    func toggleKeepAwake() {
        if let process = caffeinate, process.isRunning {
            process.terminate()
            caffeinate = nil
            keepAwake = false
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d: keep the display awake, -i: keep the system awake, -w: stop automatically when we quit.
        process.arguments = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        do {
            try process.run()
            caffeinate = process
            keepAwake = true
        } catch {
            keepAwake = false
        }
    }

    func sleepDisplay() {
        DispatchQueue.global(qos: .utility).async {
            _ = runProcess("/usr/bin/pmset", ["displaysleepnow"])
        }
    }
}
