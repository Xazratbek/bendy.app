import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private weak var controller: FoldController?
    private let pauseHotKey = PauseHotKey()

    init(controller: FoldController?) {
        self.controller = controller
        super.init()
        installStatusItem()
        pauseHotKey.arm { [weak self] in self?.togglePause() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "laptopcomputer", accessibilityDescription: "BendyLocal"
            )
            button.image?.isTemplate = true
            button.title = " Bendy"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let pause = NSMenuItem(
            title: "Pause", action: #selector(togglePause), keyEquivalent: "b"
        )
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        pause.tag = 1
        menu.addItem(pause)

        let demo = NSMenuItem(
            title: "Preview Effect", action: #selector(playDemo), keyEquivalent: ""
        )
        demo.target = self
        menu.addItem(demo)

        let bendCount = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bendCount.tag = 4
        bendCount.isEnabled = false
        menu.addItem(bendCount)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.tag = 2
        menu.addItem(launchAtLogin)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let permission = NSMenuItem(
            title: "Screen Recording…", action: #selector(openOnboarding), keyEquivalent: ""
        )
        permission.target = self
        permission.tag = 3
        menu.addItem(permission)

        let about = NSMenuItem(title: "About BendyLocal", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BendyLocal", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func playDemo() {
        controller?.playDemo()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nmacOS registers login items by bundle path. Install "
                + "BendyLocal to /Applications and try again."
            alert.alertStyle = .warning
            NSApp.activate()
            alert.runModal()
        }
        refreshStatusAppearance()
    }

    @objc private func togglePause() {
        guard let controller else { return }
        controller.isPaused.toggle()
        refreshStatusAppearance()
    }

    var needsPermission = false {
        didSet { refreshStatusAppearance() }
    }

    private func refreshStatusAppearance() {
        let paused = controller?.isPaused ?? false
        statusItem?.button?.appearsDisabled = paused || needsPermission
        statusItem?.button?.image = NSImage(
            systemSymbolName: needsPermission ? "laptopcomputer.trianglebadge.exclamationmark"
                                              : "laptopcomputer",
            accessibilityDescription: "BendyLocal"
        )
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.title = " Bendy"
        statusItem?.menu?.item(withTag: 3)?.title =
            needsPermission ? "Screen Recording — Not Granted…" : "Screen Recording…"
        if let item = statusItem?.menu?.item(withTag: 1) {
            item.title = paused ? "Resume" : "Pause"
        }
        if let item = statusItem?.menu?.item(withTag: 2) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        if let item = statusItem?.menu?.item(withTag: 4) {
            let count = Settings.shared.bendCount
            item.title = count == 1 ? "1 bend and counting" : "\(count) bends and counting"
        }
    }

    @objc func openSettings() {
        if let window = settingsWindow {
            bringToFront(window)
            return
        }

        let model = SettingsModel(controller: controller)
        settingsModel = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))

        let window = NSWindow(contentViewController: hosting)
        window.title = "BendyLocal"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func openOnboarding() {
        if let window = onboardingWindow {
            onboardingModel?.recheck()
            bringToFront(window)
            return
        }
        let model = OnboardingModel()
        model.onGranted = { [weak self] in self?.permissionBecameAvailable() }
        onboardingModel = model

        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model)))
        window.title = "BendyLocal Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        bringToFront(window)
    }

    private func permissionBecameAvailable() {
        controller?.isCaptureAllowed = true
        needsPermission = false
        ScreenPermission.relaunch()
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "BendyLocal",
            .init(rawValue: "Copyright"): "Independent local build. Clamshell core used under MIT license.",
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === settingsWindow {
            settingsModel?.endPreview()
            settingsModel = nil
            settingsWindow = nil
        } else if window === onboardingWindow {
            onboardingModel = nil
            onboardingWindow = nil
        }
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusAppearance()
    }
}
