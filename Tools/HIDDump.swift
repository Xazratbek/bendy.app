import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x05AC] as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    exit(1)
}

for device in devices {
    let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString).map { "\($0)" } ?? "?"
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString).map { "\($0)" } ?? "?"
    let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString).map { "\($0)" } ?? "?"
    let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString).map { "\($0)" } ?? "?"
    print("device vendor=\(vendor) product=\(product) page=\(usagePage) usage=\(usage)")

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
        continue
    }
    for element in elements {
        let page = IOHIDElementGetUsagePage(element)
        let use = IOHIDElementGetUsage(element)
        let type = IOHIDElementGetType(element).rawValue
        let min = IOHIDElementGetLogicalMin(element)
        let max = IOHIDElementGetLogicalMax(element)
        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        let result = IOHIDDeviceGetValue(device, element, valuePointer)
        var raw = "nil"
        if result == kIOReturnSuccess {
            raw = "\(IOHIDValueGetIntegerValue(valuePointer.pointee.takeUnretainedValue()))"
        }
        valuePointer.deallocate()
        print("  element type=\(type) page=\(page) usage=\(use) min=\(min) max=\(max) raw=\(raw)")
    }
}
