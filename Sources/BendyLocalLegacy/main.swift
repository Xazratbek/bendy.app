import AppKit
import AudioToolbox
import CoreImage
import CoreMedia
import IOKit.hid
import ScreenCaptureKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BendyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller = BendyController()
        controller?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openMainWindow()
        return true
    }
}

enum FoldStyle: Int, CaseIterable {
    case silk
    case shade
    case frost

    var title: String {
        switch self {
        case .silk: "Silk"
        case .shade: "Shade"
        case .frost: "Frost"
        }
    }
}

struct BendySettings {
    var enabled: Bool
    var style: FoldStyle
    var perspective: Double
    var blur: Double
    var shadow: Double
    var soundEnabled: Bool
    var openAngle: Double
    var closeAngle: Double
    var manualMode: Bool
    var manualAngle: Double

    static let defaults = BendySettings(
        enabled: true,
        style: .silk,
        perspective: 0.82,
        blur: 0.55,
        shadow: 0.62,
        soundEnabled: true,
        openAngle: 105,
        closeAngle: 18,
        manualMode: false,
        manualAngle: 75
    )

    static func load() -> BendySettings {
        let defaults = UserDefaults.standard
        let base = Self.defaults
        let style = FoldStyle(rawValue: defaults.integer(forKey: "style")) ?? base.style
        return BendySettings(
            enabled: defaults.object(forKey: "enabled") as? Bool ?? base.enabled,
            style: style,
            perspective: defaults.object(forKey: "perspective") as? Double ?? base.perspective,
            blur: defaults.object(forKey: "blur") as? Double ?? base.blur,
            shadow: defaults.object(forKey: "shadow") as? Double ?? base.shadow,
            soundEnabled: defaults.object(forKey: "soundEnabled") as? Bool ?? base.soundEnabled,
            openAngle: defaults.object(forKey: "openAngle") as? Double ?? base.openAngle,
            closeAngle: defaults.object(forKey: "closeAngle") as? Double ?? base.closeAngle,
            manualMode: defaults.object(forKey: "manualMode") as? Bool ?? base.manualMode,
            manualAngle: defaults.object(forKey: "manualAngle") as? Double ?? base.manualAngle
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "enabled")
        defaults.set(style.rawValue, forKey: "style")
        defaults.set(perspective, forKey: "perspective")
        defaults.set(blur, forKey: "blur")
        defaults.set(shadow, forKey: "shadow")
        defaults.set(soundEnabled, forKey: "soundEnabled")
        defaults.set(openAngle, forKey: "openAngle")
        defaults.set(closeAngle, forKey: "closeAngle")
        defaults.set(manualMode, forKey: "manualMode")
        defaults.set(manualAngle, forKey: "manualAngle")
    }
}

@MainActor
final class BendyController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var overlayWindows: [OverlayWindow] = []
    private let capture = CaptureEngine()
    private let angleSensor = LidAngleSensor()
    private var settingsWindow: SettingsWindowController?
    private var permissionWindow: PermissionWindowController?
    private var settings = BendySettings.load()
    private var timer: Timer?
    private var lastProgress = 0.0
    private var soundArmed = true
    private var latestAngle: Double = 0
    private var demoUntil: TimeInterval = 0

    func start() {
        settings.enabled = true
        settings.save()
        buildOverlays()
        setupMenu()
        demoUntil = Date().timeIntervalSince1970 + 3.0
        capture.onFrame = { [weak self] image in
            Task { @MainActor in self?.setFrame(image) }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor in self?.showPermission(message) }
        }
        Task { await capture.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openMainWindow()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func buildOverlays() {
        overlayWindows.forEach { $0.close() }
        overlayWindows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.contentView = BendyOverlayView()
            window.orderFrontRegardless()
            return window
        }
    }

    private func setupMenu() {
        statusItem.button?.title = "Bendy"
        statusItem.menu = makeMenu()
    }

    func openMainWindow() {
        openSettings()
        testFold()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "Enabled", #selector(toggleEnabled), state: settings.enabled)
        add(menu, "Settings...", #selector(openSettings))
        add(menu, "Test Fold Now", #selector(testFold))
        add(menu, "Calibrate Open Position", #selector(calibrateOpen))
        menu.addItem(.separator())
        for style in FoldStyle.allCases {
            add(menu, style.title, #selector(selectStyle(_:)), representedObject: style.rawValue, state: settings.style == style)
        }
        menu.addItem(.separator())
        add(menu, "Manual Mode", #selector(toggleManual), state: settings.manualMode)
        add(menu, "Manual 70 deg", #selector(manual70))
        add(menu, "Manual 40 deg", #selector(manual40))
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
        return menu
    }

    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        key: String = "",
        representedObject: Any? = nil,
        state: Bool = false
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = representedObject
        item.state = state ? .on : .off
        menu.addItem(item)
    }

    private func setFrame(_ image: CGImage) {
        for window in overlayWindows {
            (window.contentView as? BendyOverlayView)?.image = image
        }
    }

    private func tick() {
        let angle = settings.manualMode ? settings.manualAngle : (angleSensor.readAngle() ?? settings.openAngle)
        latestAngle = angle
        let denominator = max(settings.openAngle - settings.closeAngle, 1)
        let raw = (settings.openAngle - angle) / denominator
        var progress = smoothstep(max(0, min(1, raw)))
        let now = Date().timeIntervalSince1970
        if now < demoUntil {
            let elapsed = max(0, 3.0 - (demoUntil - now))
            let demo = sin((elapsed / 3.0) * .pi)
            progress = max(progress, demo)
            latestAngle = settings.openAngle - demo * (settings.openAngle - settings.closeAngle)
        }

        if settings.enabled {
            apply(progress)
            playClickIfNeeded(progress)
        } else {
            apply(0)
        }
        lastProgress = progress
    }

    private func apply(_ progress: Double) {
        for window in overlayWindows {
            guard let view = window.contentView as? BendyOverlayView else { continue }
            view.settings = settings
            view.progress = progress
            view.angle = latestAngle
            if progress > 0.018, settings.enabled {
                if !window.isVisible { window.orderFrontRegardless() }
            } else {
                if window.isVisible { window.orderOut(nil) }
            }
        }
        settingsWindow?.updateLive(angle: latestAngle, progress: progress)
    }

    private func smoothstep(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }

    private func playClickIfNeeded(_ progress: Double) {
        guard settings.soundEnabled else { return }
        if soundArmed, progress > 0.80 {
            soundArmed = false
            AudioServicesPlaySystemSound(1104)
        } else if !soundArmed, progress < 0.50 {
            soundArmed = true
        }
    }

    private func persist() {
        settings.save()
        statusItem.menu = makeMenu()
    }

    private func showPermission(_ message: String) {
        permissionWindow = PermissionWindowController(message: message)
        permissionWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func screenLayoutChanged() {
        buildOverlays()
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        persist()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] settings in
                self?.settings = settings
                self?.persist()
            }
        }
        settingsWindow?.settings = settings
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.level = .floating
        settingsWindow?.window?.center()
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func testFold() {
        demoUntil = Date().timeIntervalSince1970 + 3.0
        settings.enabled = true
        persist()
    }

    @objc private func calibrateOpen() {
        settings.openAngle = angleSensor.readAngle() ?? settings.manualAngle
        persist()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let style = FoldStyle(rawValue: raw) else { return }
        settings.style = style
        persist()
    }

    @objc private func toggleManual() {
        settings.manualMode.toggle()
        persist()
    }

    @objc private func manual70() {
        settings.manualMode = true
        settings.manualAngle = 70
        persist()
    }

    @objc private func manual40() {
        settings.manualMode = true
        settings.manualAngle = 40
        persist()
    }

    @objc private func quit() {
        Task { await capture.stop() }
        NSApp.terminate(nil)
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.backgroundColor = .clear
        self.isOpaque = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hasShadow = false
        self.setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
}

@MainActor
final class BendyOverlayView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var angle: Double = 100 { didSet { needsDisplay = true } }
    var settings = BendySettings.defaults { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        context.clear(bounds)
        guard let sourceImage = image ?? fallbackImage(size: bounds.size) else { return }

        let p = CGFloat(progress)
        let perspective = CGFloat(settings.perspective)
        let blurPower = CGFloat(settings.blur)
        let shadowPower = CGFloat(settings.shadow)
        let topInset = bounds.height * p * (0.035 + 0.035 * perspective)
        let sideInset = bounds.width * p * 0.018
        let shrinkY = max(0.04, 1 - p * (0.68 + 0.14 * perspective))
        let shear = p * (0.07 + 0.07 * perspective)
        let drawRect = bounds.insetBy(dx: sideInset, dy: 0)

        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.maxY - topInset)
        context.scaleBy(x: 1 - p * 0.018, y: shrinkY)
        context.concatenate(CGAffineTransform(a: 1, b: -shear, c: 0, d: 1, tx: 0, ty: 0))
        context.translateBy(x: -bounds.midX, y: -bounds.maxY)

        context.interpolationQuality = .high
        drawBentImage(context: context, image: sourceImage, in: drawRect, p: p, blurPower: blurPower)
        drawStyle(context: context, in: drawRect, p: p, shadowPower: shadowPower)
        context.restoreGState()
    }

    private func fallbackImage(size: CGSize) -> CGImage? {
        let width = max(640, Int(size.width))
        let height = max(400, Int(size.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let bg = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.38, alpha: 1).cgColor,
                     NSColor(calibratedRed: 0.70, green: 0.77, blue: 0.84, alpha: 1).cgColor] as CFArray,
            locations: [0, 1]
        )
        if let bg {
            context.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.22).cgColor)
        for index in 0..<5 {
            let x = CGFloat(70 + index * 180)
            let y = CGFloat(height - 150 - (index % 2) * 80)
            context.fill(CGRect(x: x, y: y, width: 130, height: 86).insetBy(dx: 0, dy: 0))
        }
        context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.18).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 54))
        return context.makeImage()
    }

    private func drawBentImage(context: CGContext, image: CGImage, in rect: CGRect, p: CGFloat, blurPower: CGFloat) {
        context.saveGState()
        context.draw(image, in: rect)
        guard p > 0.015, let blurred = blurredImage(image, radius: 18 * p * blurPower) else {
            context.restoreGState()
            return
        }

        let bands = 10
        for index in 0..<bands {
            let t0 = CGFloat(index) / CGFloat(bands)
            let t1 = CGFloat(index + 1) / CGFloat(bands)
            let y0 = rect.minY + rect.height * (1 - t1)
            let height = rect.height / CGFloat(bands) + 1
            let alpha = pow(1 - t0, 1.8) * p * blurPower
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: y0, width: rect.width, height: height))
            context.setAlpha(alpha)
            context.draw(blurred, in: rect)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func drawStyle(context: CGContext, in rect: CGRect, p: CGFloat, shadowPower: CGFloat) {
        let alpha = p * shadowPower
        switch settings.style {
        case .silk:
            drawGradient(context, rect, [
                (0.0, NSColor.black.withAlphaComponent(alpha * 0.42).cgColor),
                (0.33, NSColor.black.withAlphaComponent(alpha * 0.20).cgColor),
                (1.0, NSColor.black.withAlphaComponent(alpha * 0.05).cgColor)
            ])
        case .shade:
            drawGradient(context, rect, [
                (0.0, NSColor.black.withAlphaComponent(alpha * 0.72).cgColor),
                (0.48, NSColor.black.withAlphaComponent(alpha * 0.38).cgColor),
                (1.0, NSColor.black.withAlphaComponent(alpha * 0.10).cgColor)
            ])
        case .frost:
            drawGradient(context, rect, [
                (0.0, NSColor.white.withAlphaComponent(alpha * 0.26).cgColor),
                (0.24, NSColor(calibratedWhite: 0.8, alpha: alpha * 0.15).cgColor),
                (1.0, NSColor.black.withAlphaComponent(alpha * 0.12).cgColor)
            ])
        }

        let edge = rect.height * min(0.22, 0.03 + p * 0.18)
        drawGradient(context, CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge), [
            (0.0, NSColor.black.withAlphaComponent(alpha * 0.5).cgColor),
            (1.0, NSColor.clear.cgColor)
        ])
    }

    private func drawGradient(_ context: CGContext, _ rect: CGRect, _ stops: [(CGFloat, CGColor)]) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = stops.map(\.1) as CFArray
        let locations = stops.map(\.0)
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
    }

    private func blurredImage(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0.5 else { return image }
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: image)
        return input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
            .cgImage(using: context)
    }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CGImage) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "BendyLocal.capture")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?

    func start() async {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                onError?("No capture display found.")
                return
            }
            let ownBundle = Bundle.main.bundleIdentifier
            let filter = SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter { $0.bundleIdentifier == ownBundle },
                exceptingWindows: []
            )

            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 4
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            onError?("Screen Recording permission required. Enable it in System Settings, then quit and reopen BendyLocal.\n\n\(error.localizedDescription)")
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame?(cgImage)
    }
}

final class LidAngleSensor {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var element: IOHIDElement?
    private var scale: Double = 1

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104],
            [kIOHIDVendorIDKey: 0x05AC]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        discover()
    }

    func readAngle() -> Double? {
        if device == nil || element == nil { discover() }
        guard let device, let element else { return nil }
        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        let result = IOHIDDeviceGetValue(device, element, valuePointer)
        guard result == kIOReturnSuccess else { return nil }
        let raw = Double(IOHIDValueGetIntegerValue(valuePointer.pointee.takeUnretainedValue()))
        let angle = raw / scale
        guard angle >= 0, angle <= 180 else { return nil }
        return angle
    }

    private func discover() {
        device = nil
        element = nil
        scale = 1
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            let primaryPage = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber
            let primaryUsage = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? NSNumber
            guard primaryPage?.intValue == 32, primaryUsage?.intValue == 138 else { continue }
            guard let elements = IOHIDDeviceCopyMatchingElements(candidate, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            let candidates = elements.filter {
                IOHIDElementGetType($0).rawValue == 1 && IOHIDElementGetUsagePage($0) == 32
            }
            for usage in [1349, 1151] {
                guard let candidateElement = candidates.first(where: { IOHIDElementGetUsage($0) == usage }) else { continue }
                let usagePage = IOHIDElementGetUsagePage(candidateElement)
                let logicalMax = IOHIDElementGetLogicalMax(candidateElement)
                if usagePage == 0x20 {
                    device = candidate
                    element = candidateElement
                    scale = logicalMax > 360 ? 100 : 1
                    return
                }
            }
        }
    }
}

final class PermissionWindowController: NSWindowController {
    init(message: String) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let title = NSTextField(labelWithString: "Screen Recording Needed")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 148, width: 412, height: 28)

        let body = NSTextField(wrappingLabelWithString: message)
        body.frame = NSRect(x: 24, y: 70, width: 412, height: 70)

        let settings = NSButton(title: "Open System Settings", target: nil, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.frame = NSRect(x: 24, y: 24, width: 160, height: 32)

        content.addSubview(title)
        content.addSubview(body)
        content.addSubview(settings)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BendyLocal"
        window.contentView = content
        super.init(window: window)
        settings.target = self
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

final class SettingsWindowController: NSWindowController {
    var settings: BendySettings {
        didSet { sync() }
    }
    private let onChange: (BendySettings) -> Void
    private let style = NSSegmentedControl(labels: FoldStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: "Sound", target: nil, action: nil)
    private let manual = NSButton(checkboxWithTitle: "Manual angle", target: nil, action: nil)
    private let perspective = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let blur = NSSlider(value: 0.55, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadow = NSSlider(value: 0.62, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let manualAngle = NSSlider(value: 75, minValue: 18, maxValue: 120, target: nil, action: nil)
    private let live = NSTextField(labelWithString: "Angle -- deg")
    private let help = NSTextField(wrappingLabelWithString: "Close the lid slowly. Screen image should stay anchored near the hinge while the top folds, blurs, and darkens. Use Test Fold Now from the Bendy menu if the lid sensor or permission is not ready.")

    init(settings: BendySettings, onChange: @escaping (BendySettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 470))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "BendyLocal Settings"
        super.init(window: window)
        window.contentView = view
        build(view)
        sync()
    }

    required init?(coder: NSCoder) { nil }

    func updateLive(angle: Double, progress: Double) {
        live.stringValue = "Angle \(String(format: "%.1f", angle)) deg    Bend \(Int(progress * 100))%"
    }

    private func build(_ view: NSView) {
        let title = NSTextField(labelWithString: "BendyLocal")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.frame = NSRect(x: 24, y: 416, width: 240, height: 32)
        view.addSubview(title)

        help.frame = NSRect(x: 24, y: 356, width: 512, height: 48)
        help.textColor = .secondaryLabelColor
        view.addSubview(help)

        enabled.frame = NSRect(x: 24, y: 316, width: 120, height: 24)
        sound.frame = NSRect(x: 150, y: 316, width: 120, height: 24)
        manual.frame = NSRect(x: 276, y: 316, width: 140, height: 24)
        view.addSubview(enabled)
        view.addSubview(sound)
        view.addSubview(manual)

        addLabel("Style", y: 276, to: view)
        style.frame = NSRect(x: 130, y: 272, width: 260, height: 28)
        view.addSubview(style)

        addSlider("Perspective", slider: perspective, y: 228, to: view)
        addSlider("Blur", slider: blur, y: 180, to: view)
        addSlider("Shadow", slider: shadow, y: 132, to: view)
        addSlider("Angle", slider: manualAngle, y: 84, to: view)

        live.frame = NSRect(x: 24, y: 32, width: 300, height: 22)
        live.textColor = .secondaryLabelColor
        view.addSubview(live)

        let calibrate = NSButton(title: "Use Current As Open", target: self, action: #selector(useCurrentAsOpen))
        calibrate.bezelStyle = .rounded
        calibrate.frame = NSRect(x: 360, y: 26, width: 160, height: 32)
        view.addSubview(calibrate)

        for control in [enabled, sound, manual, style, perspective, blur, shadow, manualAngle] {
            control.target = self
            control.action = #selector(changed)
        }
    }

    private func addLabel(_ text: String, y: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 24, y: y, width: 100, height: 20)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)
    }

    private func addSlider(_ text: String, slider: NSSlider, y: CGFloat, to view: NSView) {
        addLabel(text, y: y + 4, to: view)
        slider.frame = NSRect(x: 130, y: y, width: 300, height: 28)
        view.addSubview(slider)
    }

    private func sync() {
        enabled.state = settings.enabled ? .on : .off
        sound.state = settings.soundEnabled ? .on : .off
        manual.state = settings.manualMode ? .on : .off
        style.selectedSegment = settings.style.rawValue
        perspective.doubleValue = settings.perspective
        blur.doubleValue = settings.blur
        shadow.doubleValue = settings.shadow
        manualAngle.doubleValue = settings.manualAngle
    }

    @objc private func changed() {
        settings.enabled = enabled.state == .on
        settings.soundEnabled = sound.state == .on
        settings.manualMode = manual.state == .on
        settings.style = FoldStyle(rawValue: style.selectedSegment) ?? .silk
        settings.perspective = perspective.doubleValue
        settings.blur = blur.doubleValue
        settings.shadow = shadow.doubleValue
        settings.manualAngle = manualAngle.doubleValue
        onChange(settings)
    }

    @objc private func useCurrentAsOpen() {
        settings.openAngle = settings.manualAngle
        onChange(settings)
    }
}

private extension CIImage {
    func cgImage(using context: CIContext) -> CGImage? {
        context.createCGImage(self, from: extent)
    }
}
