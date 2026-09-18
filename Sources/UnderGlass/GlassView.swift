import AppKit

final class GlassView: NSView {
    var telemetry = Telemetry()
    var phase = 0.0
    var reveal = 1.0
    var amber = false
    override var isFlipped: Bool { true }

    private var accent: NSColor { amber ? NSColor(calibratedRed: 1, green: 0.68, blue: 0.29, alpha: 1) : NSColor(calibratedRed: 0.35, green: 0.94, blue: 0.81, alpha: 1) }
    private func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, color: NSColor = .white, weight: NSFont.Weight = .regular) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    private func box(_ rect: NSRect, fill: NSColor, stroke: NSColor? = nil, radius: CGFloat = 12) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedRed: 0.025, green: 0.043, blue: 0.055, alpha: 0.96).setFill(); bounds.fill()
        let scale = min(bounds.width / 1000, bounds.height / 650)
        context.saveGState()
        context.translateBy(x: (bounds.width - 1000 * scale) / 2, y: (bounds.height - 650 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        let muted = NSColor(calibratedWhite: 0.51, alpha: 1)
        text("UNDERGLASS", 42, 30, size: 15, weight: .bold)
        text("A living view beneath your desktop", 42, 56, size: 11, color: muted)
        text("● LIVE / ON DEVICE", 786, 34, size: 11, color: accent)
        box(NSRect(x: 42, y: 98, width: 916, height: 424), fill: NSColor(calibratedWhite: 0.055, alpha: 1), stroke: accent.withAlphaComponent(0.22), radius: 24)
        // The board is an original schematic, not a claim about hardware layout.
        for x in stride(from: 62, through: 940, by: 22) {
            for y in stride(from: 119, through: 500, by: 22) {
                accent.withAlphaComponent(0.12).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(x), y: CGFloat(y), width: 1.5, height: 1.5)).fill()
            }
        }
        for index in 0..<14 {
            let offset = CGFloat(index) * 9
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 300, y: 218 + offset))
            p.line(to: NSPoint(x: 370 - offset * 0.2, y: 218 + offset))
            p.line(to: NSPoint(x: 400, y: 250 + offset * 0.6))
            p.line(to: NSPoint(x: 590, y: 250 + offset * 0.6))
            p.line(to: NSPoint(x: 640 + offset * 0.2, y: 180 + offset))
            p.line(to: NSPoint(x: 805, y: 180 + offset))
            accent.withAlphaComponent(0.13 + telemetry.cpu * 0.3).setStroke(); p.lineWidth = 1; p.stroke()
        }
        let heat = NSColor(calibratedRed: 0.35 + telemetry.cpu * 0.65, green: 0.94 - telemetry.cpu * 0.54, blue: 0.81 - telemetry.cpu * 0.60, alpha: 1)
        box(NSRect(x: 398, y: 205, width: 198, height: 174), fill: heat.withAlphaComponent(0.08), stroke: heat.withAlphaComponent(0.6), radius: 18)
        box(NSRect(x: 423, y: 230, width: 148, height: 124), fill: NSColor(calibratedWhite: 0.055, alpha: 1), stroke: heat, radius: 8)
        text("PROCESSOR", 446, 249, size: 12, color: heat)
        text(String(format: "%.0f%%", telemetry.cpu * 100), 450, 274, size: 34, color: heat, weight: .medium)
        text(telemetry.thermal.uppercased(), 455, 322, size: 10, color: muted)
        for i in 0..<18 {
            let x = 430 + CGFloat(i) * 7.5
            box(NSRect(x: x, y: 195, width: 3, height: 8), fill: heat.withAlphaComponent(0.45), radius: 1)
            box(NSRect(x: x, y: 381, width: 3, height: 8), fill: heat.withAlphaComponent(0.45), radius: 1)
        }
        text("UNIFIED MEMORY", 91, 146, size: 11, color: muted)
        for i in 0..<8 {
            let r = NSRect(x: 90 + (i % 2) * 98, y: 176 + (i / 2) * 60, width: 84, height: 45)
            box(r, fill: accent.withAlphaComponent(Double(i) / 8 < telemetry.memory ? 0.24 : 0.035), stroke: accent.withAlphaComponent(0.30), radius: 5)
            text(String(format: "%02d", i + 1), r.minX + 10, r.minY + 13, size: 11, color: accent)
        }
        text(String(format: "%.0f%% ACTIVE", telemetry.memory * 100), 91, 431, size: 15, color: accent)
        text("ENERGY RESERVE", 690, 146, size: 11, color: muted)
        for i in 0..<3 {
            let r = NSRect(x: 690, y: 177 + i * 72, width: 211, height: 59)
            box(r, fill: NSColor(calibratedWhite: 0.08, alpha: 1), stroke: accent.withAlphaComponent(0.23), radius: 7)
            if let battery = telemetry.battery {
                box(NSRect(x: r.minX + 5, y: r.minY + 5, width: 201 * battery, height: 49), fill: accent.withAlphaComponent(0.13), radius: 4)
                let pulse = CGFloat((phase * (telemetry.charging ? 0.7 : 0.18) + Double(i) * 0.24).truncatingRemainder(dividingBy: 1))
                box(NSRect(x: r.minX + 7 + pulse * 190, y: r.minY + 9, width: 2, height: 40), fill: accent.withAlphaComponent(0.6), radius: 1)
            }
        }
        text(telemetry.battery.map { String(format: "%.0f%%", $0 * 100) } ?? "AC POWER", 692, 431, size: 18, color: accent)
        text(telemetry.charging ? "CHARGING" : "BATTERY", 800, 435, size: 10, color: muted)
        let network = min(1, (telemetry.incoming + telemetry.outgoing) / 1_000_000)
        for i in 0..<35 {
            let height = 3 + network * (10 + 17 * (0.5 + 0.5 * sin(phase * 4 + Double(i))))
            box(NSRect(x: 352 + CGFloat(i) * 8, y: 475 - height, width: 3, height: height), fill: accent.withAlphaComponent(0.65), radius: 1)
        }
        let cards: [(String, String)] = [
            ("PROCESSOR", String(format: "%.1f%%", telemetry.cpu * 100)),
            ("MEMORY · ACTIVE + WIRED", String(format: "%.1f / %.0f GB", telemetry.memory * Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)),
            ("NETWORK · ↓ / ↑", "\(rate(telemetry.incoming)) / \(rate(telemetry.outgoing))")
        ]
        for (i, card) in cards.enumerated() {
            let x = CGFloat(42 + i * 309)
            box(NSRect(x: x, y: 540, width: 298, height: 70), fill: NSColor(calibratedWhite: 0.065, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.07))
            text(card.0, x + 16, 552, size: 10, color: muted)
            text(card.1, x + 16, 576, size: 17, color: .white, weight: .medium)
        }
        text("ILLUSTRATED HARDWARE / REAL TELEMETRY", 43, 625, size: 9, color: muted)
        text("⌃⌥⌘U TO REVEAL · ESC TO DISMISS", 699, 625, size: 9, color: muted)
        context.restoreGState()
    }
    private func rate(_ bytes: Double) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB/s", bytes / 1_000_000) : String(format: "%.0f KB/s", bytes / 1000)
    }
}
