import Foundation
import IOKit.ps
import Darwin

struct Telemetry {
    var cpu = 0.0
    var memory = 0.0
    var battery: Double?
    var charging = false
    var incoming = 0.0
    var outgoing = 0.0
    var thermal = "Nominal"
}

final class TelemetryReader {
    private var lastCPU: [UInt64]?
    private var lastNetwork: (UInt64, UInt64, TimeInterval)?

    func read() -> Telemetry {
        var result = Telemetry()
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3].map(UInt64.init)
            if let previous = lastCPU {
                let delta = zip(ticks, previous).map { $0 >= $1 ? $0 - $1 : 0 }
                let total = delta.reduce(0, +)
                if total > 0 { result.cpu = 1 - Double(delta[2]) / Double(total) }
            }
            lastCPU = ticks
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS {
            let usedPages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            result.memory = min(1, Double(usedPages) * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory))
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = description[kIOPSCurrentCapacityKey] as? Double,
                      let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
                result.battery = current / maximum
                result.charging = description[kIOPSIsChargingKey] as? Bool ?? false
                break
            }
        }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        var received: UInt64 = 0
        var sent: UInt64 = 0
        if getifaddrs(&addresses) == 0 {
            var current = addresses
            while let item = current {
                let entry = item.pointee
                if entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                   String(cString: entry.ifa_name).hasPrefix("en"), let raw = entry.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(data.ifi_ibytes)
                    sent += UInt64(data.ifi_obytes)
                }
                current = entry.ifa_next
            }
            freeifaddrs(addresses)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastNetwork, now > last.2 {
            result.incoming = Double(received >= last.0 ? received - last.0 : 0) / (now - last.2)
            result.outgoing = Double(sent >= last.1 ? sent - last.1 : 0) / (now - last.2)
        }
        lastNetwork = (received, sent, now)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = "Nominal"
        case .fair: result.thermal = "Warm"
        case .serious: result.thermal = "Hot"
        case .critical: result.thermal = "Critical"
        @unknown default: result.thermal = "Unknown"
        }
        return result
    }
}
