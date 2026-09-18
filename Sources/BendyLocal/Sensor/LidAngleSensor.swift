import Foundation
import IOKit
import IOKit.hid

final class LidAngleSensor {
    private static let sensorUsagePage = 0x20
    private static let lidAngleUsage = 0x8A

    private enum AngleReport {
        case precise
        case coarse

        var id: CFIndex { self == .precise ? 7 : 1 }
        var minimumLength: Int { 3 }

        func degrees(from buffer: [UInt8]) -> Double {
            let raw = UInt16(buffer[1]) | (UInt16(buffer[2]) << 8)
            switch self {
            case .precise: return Double(raw) / 100.0
            case .coarse:  return Double(raw & 0x1FF)
            }
        }
    }

    private static let bufferSize = 8

    // IOHIDDeviceGetReport is a synchronous round trip into the kernel for this
    // feature report and can occasionally take several milliseconds. Calling it
    // directly from the main-thread watch loop stalls whatever else is due that
    // tick (spring integration, CADisplayLink-driven draw), which is exactly the
    // kind of hitch that reads as "not smooth". A dedicated thread polls the
    // device and publishes the latest angle behind a lock; callers on the main
    // thread only ever read that cached value, so they never block on IOKit.
    private let pollInterval: TimeInterval

    private var device: IOHIDDevice?
    private var report: AngleReport = .precise

    private let lock = NSLock()
    private var cachedAngle: Double?
    private var shouldStopPolling = false

    var isAvailable: Bool { device != nil }

    var resolution: Double { report == .precise ? 0.01 : 1.0 }

    init(pollInterval: TimeInterval = 1.0 / 240.0) {
        self.pollInterval = max(1.0 / 240.0, pollInterval)
        if let (device, report) = Self.openSensorDevice() {
            self.device = device
            self.report = report
            cachedAngle = Self.readAngle(from: device, using: report)
            startPolling(device: device, report: report)
        }
    }

    deinit {
        lock.lock()
        shouldStopPolling = true
        lock.unlock()
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func startPolling(device: IOHIDDevice, report: AngleReport) {
        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                let stop = self.shouldStopPolling
                self.lock.unlock()
                if stop { return }

                if let angle = Self.readAngle(from: device, using: report) {
                    self.lock.lock()
                    self.cachedAngle = angle
                    self.lock.unlock()
                }
                Thread.sleep(forTimeInterval: self.pollInterval)
            }
        }
        thread.name = "com.danielradosa.bendylocal.lidangle-poll"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func openSensorDevice() -> (IOHIDDevice, AngleReport)? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: sensorUsagePage,
            kIOHIDPrimaryUsageKey as String: lidAngleUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }

        for report in [AngleReport.precise, .coarse] where readAngle(from: device, using: report) != nil {
            return (device, report)
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        return nil
    }

    private static func readAngle(from device: IOHIDDevice, using report: AngleReport) -> Double? {
        var length = bufferSize
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, report.id, &buffer, &length
        )
        guard result == kIOReturnSuccess, length >= report.minimumLength else { return nil }

        let degrees = report.degrees(from: buffer)
        guard degrees >= 0, degrees <= 180 else { return nil }
        return degrees
    }

    func currentAngle() -> Double? {
        guard device != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cachedAngle
    }
}
