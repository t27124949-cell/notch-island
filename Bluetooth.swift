import AppKit
import IOBluetooth

/// Announces in the notch when headphones or other Bluetooth devices connect, with AirPods battery when known.
final class BluetoothWatcher: NSObject {
    private weak var model: NotchModel?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var started = false

    func start(model: NotchModel) {
        guard !started else { return }
        started = true
        self.model = model
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Bluetooth device"
        let key = device.addressString ?? name
        disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                       selector: #selector(deviceDisconnected(_:device:)))
        guard wantsAlerts else { return }
        // Give the device a moment to report its battery before asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            BluetoothBattery.lookup(name: name) { text in
                self?.post(symbol: BluetoothWatcher.symbol(for: name), title: "\(name) connected", subtitle: text ?? "")
            }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Bluetooth device"
        disconnectNotifications.removeValue(forKey: device.addressString ?? name)
        notification.unregister()
        guard wantsAlerts else { return }
        post(symbol: BluetoothWatcher.symbol(for: name), title: "\(name) disconnected", subtitle: "")
    }

    private var wantsAlerts: Bool {
        guard let model else { return false }
        return model.settings.activitiesEnabled && model.settings.activityBluetooth
    }

    private func post(symbol: String, title: String, subtitle: String) {
        guard wantsAlerts, let model else { return }
        model.activity = Activity(symbol: symbol, tint: .systemBlue, title: title, subtitle: subtitle, duration: 4)
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("headphone") || lower.contains("buds") || lower.contains("headset") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Battery levels for a connected Bluetooth device, read from macOS's system profiler.
enum BluetoothBattery {
    static func lookup(name: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var text: String?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = parse(data, deviceName: name)
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func parse(_ data: Data, deviceName: String) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            guard let devices = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in devices {
                guard let info = entry[deviceName] as? [String: Any] else { continue }
                var parts: [String] = []
                if let left = info["device_batteryLevelLeft"] as? String { parts.append("L \(left)") }
                if let right = info["device_batteryLevelRight"] as? String { parts.append("R \(right)") }
                if let box = info["device_batteryLevelCase"] as? String { parts.append("Case \(box)") }
                if parts.isEmpty, let main = info["device_batteryLevelMain"] as? String { parts.append("Battery \(main)") }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        }
        return nil
    }
}
