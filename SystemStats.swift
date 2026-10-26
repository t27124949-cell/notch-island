import AppKit
import Combine
import Darwin

/// Live CPU, memory, disk and network numbers. Only samples while the Stats tab is visible.
final class StatsStore: ObservableObject {
    @Published var cpu: Double = 0                      // 0...1
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var memUsed: Double = 0                  // bytes
    @Published var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var diskFree: Double = 0                 // bytes
    @Published var diskTotal: Double = 0
    @Published var rxRate: Double = 0                   // bytes per second
    @Published var txRate: Double = 0

    private var timer: Timer?
    private var previousCPU: host_cpu_load_info?
    private var previousNet: (rx: UInt64, tx: UInt64, time: Date)?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousCPU = nil
        previousNet = nil
    }

    private func sample() {
        if let usage = readCPU() {
            cpu = usage
            var history = cpuHistory
            history.append(usage)
            if history.count > 40 { history.removeFirst(history.count - 40) }
            cpuHistory = history
        }
        readMemory()
        readDisk()
        readNetwork()
    }

    // MARK: CPU

    private func readCPU() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, raw, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        defer { previousCPU = info }
        guard let previous = previousCPU else { return nil }

        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : nil
    }

    // MARK: Memory

    private func readMemory() {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let status = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, raw, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        memUsed = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    // MARK: Disk

    private func readDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(values.volumeTotalCapacity ?? 0)
        }
    }

    // MARK: Network

    private func readNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data {
                let name = String(cString: entry.ifa_name)
                if name.hasPrefix("en") {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(stats.ifi_ibytes)
                    tx += UInt64(stats.ifi_obytes)
                }
            }
            pointer = entry.ifa_next
        }

        let now = Date()
        if let previous = previousNet {
            let seconds = now.timeIntervalSince(previous.time)
            if seconds > 0 {
                rxRate = rx >= previous.rx ? Double(rx - previous.rx) / seconds : 0
                txRate = tx >= previous.tx ? Double(tx - previous.tx) / seconds : 0
            }
        }
        previousNet = (rx, tx, now)
    }
}
