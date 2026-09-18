import AppKit
import Carbon

final class GlassHotKey {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlassHotKey>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x55474C53 else { return OSStatus(eventNotHandledErr) }
            owner.action?(id.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register(key: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 1)
    }
    private func register(key: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x55474C53, id: id), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { references.append(ref) }
    }
    func escape(_ enabled: Bool) {
        if enabled, references.count == 1 { register(key: UInt32(kVK_Escape), modifiers: 0, id: 2) }
        if !enabled, references.count > 1 { UnregisterEventHotKey(references.removeLast()) }
    }
    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class UnderGlassApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let reader = TelemetryReader()
    private let sensor = LidAngleSensor(pollInterval: 1.0 / 30.0)
    private let hotKey = GlassHotKey()
    private let dashboard = GlassView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
    private var window: NSWindow!
    private var overlay: NSWindow?
    private var status: NSStatusItem!
    private var sampleTimer: Timer?
    private var animationTimer: Timer?
    private var lidTimer: Timer?
    private var lidItem: NSMenuItem!
    private var amberItem: NSMenuItem!
    private var pausedLid = false
    private var latest = Telemetry()
    private var controls: NSStackView!
    private let queue = DispatchQueue(label: "app.underglass.telemetry", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: dashboard.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "UnderGlass — Live hardware"
        window.contentView = dashboard
        window.titleVisibility = .visible
        let toolbar = NSToolbar(identifier: "UnderGlass.controls")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        dashboard.amber = UserDefaults.standard.bool(forKey: "amber")
        let menu = NSMenu()
        add("Show UnderGlass", #selector(showDashboard), to: menu)
        add("Reveal desktop    ⌃⌥⌘U", #selector(toggleOverlay), to: menu)
        menu.addItem(.separator())
        lidItem = add("Reveal as lid closes", #selector(toggleLid), to: menu)
        lidItem.isEnabled = sensor.isAvailable
        lidItem.state = UserDefaults.standard.bool(forKey: "lidEnabled") ? .on : .off
        amberItem = add("Amber circuit theme", #selector(toggleAmber), to: menu)
        amberItem.state = dashboard.amber ? .on : .off
        menu.addItem(.separator())
        add("About & privacy", #selector(about), to: menu)
        add("Quit UnderGlass", #selector(quit), to: menu).keyEquivalent = "q"
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "UnderGlass")
        status.menu = menu
        hotKey.action = { [weak self] id in
            if id == 1 { self?.toggleOverlay() } else { self?.hideOverlay(); self?.pausedLid = true }
        }
        if CommandLine.arguments.contains("--amber") { dashboard.amber = true }
        sample()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.animate() }
        lidTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.updateLid() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sleeping), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showDashboard()
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.exportPreview(); self.toggleOverlay() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let visible = self.overlay?.isVisible == true
                self.hideOverlay()
                print("UnderGlass smoke: overlayShown=\(visible) overlayCleared=\(self.overlay == nil) cpu=\(self.latest.cpu) memory=\(self.latest.memory) battery=\(String(describing: self.latest.battery)) sensor=\(self.sensor.isAvailable)")
                NSApp.terminate(nil)
            }
        }
    }
    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    private func sample() {
        queue.async { [weak self] in
            guard let self else { return }
            let data = self.reader.read()
            DispatchQueue.main.async {
                self.latest = data
                self.dashboard.telemetry = data
                (self.overlay?.contentView as? GlassView)?.telemetry = data
            }
        }
    }
    private func animate() {
        let phase = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : ProcessInfo.processInfo.systemUptime
        if window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) { dashboard.phase = phase; dashboard.needsDisplay = true }
        if let view = overlay?.contentView as? GlassView { view.phase = phase; view.needsDisplay = true }
    }
    private func updateLid() {
        guard lidItem.state == .on, let angle = sensor.currentAngle() else { return }
        if angle > 105 { pausedLid = false; hideOverlay(); return }
        if angle < 15 { hideOverlay(); return }
        guard !pausedLid else { return }
        if angle < 90 {
            showOverlay()
            overlay?.alphaValue = min(1, max(0.08, (100 - angle) / 50))
            if let view = overlay?.contentView {
                var transform = CATransform3DIdentity
                transform.m34 = -1.0 / 1800
                view.layer?.transform = CATransform3DRotate(transform, CGFloat((90 - angle) / 220), 1, 0, 0)
            }
        } else { hideOverlay() }
    }
    private func showOverlay() {
        guard overlay == nil, let screen = NSScreen.main else { return }
        let panel = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = GlassView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.telemetry = latest; view.amber = dashboard.amber
        view.wantsLayer = true
        panel.contentView = view
        overlay = panel
        hotKey.escape(true)
        panel.orderFrontRegardless()
    }
    private func hideOverlay() {
        overlay?.orderOut(nil); overlay = nil; hotKey.escape(false)
    }
    @objc private func sleeping() { hideOverlay(); pausedLid = true }
    @objc func showDashboard() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func toggleOverlay() { if overlay == nil { showOverlay() } else { hideOverlay(); pausedLid = true } }
    @objc private func toggleLid() {
        lidItem.state = lidItem.state == .on ? .off : .on
        UserDefaults.standard.set(lidItem.state == .on, forKey: "lidEnabled")
        pausedLid = false; hideOverlay()
    }
    @objc private func toggleAmber() {
        dashboard.amber.toggle(); amberItem.state = dashboard.amber ? .on : .off
        UserDefaults.standard.set(dashboard.amber, forKey: "amber")
        (overlay?.contentView as? GlassView)?.amber = dashboard.amber
    }
    @objc func settings() {
        let alert = NSAlert()
        alert.messageText = "Make UnderGlass yours"
        alert.informativeText = "Reveal your circuit board with Control–Option–Command–U. Press Escape to dismiss.\n\nAutomatic lid reveal starts below 90° and clears above 105° or below 15°. Escape pauses it until you reopen the lid."
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let theme = NSButton(checkboxWithTitle: "Amber circuit theme", target: self, action: #selector(themeCheckbox(_:)))
        theme.state = dashboard.amber ? .on : .off
        let lid = NSButton(checkboxWithTitle: "Automatically reveal as lid closes", target: self, action: #selector(lidCheckbox(_:)))
        lid.state = lidItem.state; lid.isEnabled = sensor.isAvailable
        stack.addArrangedSubview(theme); stack.addArrangedSubview(lid)
        let info = NSTextField(labelWithString: sensor.isAvailable ? "Lid sensor connected" : "No compatible lid sensor. The keyboard shortcut still works.")
        info.textColor = .secondaryLabelColor; stack.addArrangedSubview(info)
        stack.frame = NSRect(x: 0, y: 0, width: 390, height: 92)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
    @objc private func themeCheckbox(_ sender: NSButton) { toggleAmber() }
    @objc private func lidCheckbox(_ sender: NSButton) { toggleLid() }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "UnderGlass 0.1.0 — Preview"
        alert.informativeText = "Illustrated hardware. Real, on-device telemetry.\n\nCPU is sampled every second. Memory includes active, wired and compressed pages. Network totals use en interfaces. The schematic does not represent your Mac's exact hardware layout.\n\nNo account, analytics, uploads or screen recording. Reveal: ⌃⌥⌘U. Dismiss: Esc. Lid reveal is optional and requires a compatible MacBook sensor.\n\nLid sensor code adapted from Clamshell, © 2026 Daniel Radosa, MIT license. Full license is included in the app Resources."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { hideOverlay() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    private func exportPreview() {
        guard let bitmap = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds) else { return }
        dashboard.cacheDisplay(in: dashboard.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("UnderGlass-preview.png")
            try? data.write(to: url)
            print("Preview: \(url.path)")
        }
    }
}

extension UnderGlassApp: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, NSToolbarItem.Identifier("reveal"), NSToolbarItem.Identifier("settings")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        if identifier.rawValue == "reveal" {
            item.label = "Reveal desktop"; item.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Reveal desktop"); item.action = #selector(toggleOverlay)
        } else {
            item.label = "Settings"; item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings"); item.action = #selector(settings)
        }
        return item
    }
}

let app = NSApplication.shared
let delegate = UnderGlassApp()
app.delegate = delegate
app.run()
