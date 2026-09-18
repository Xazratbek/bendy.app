import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: FoldController?
    private var menuBar: MenuBarController?

    private enum Key {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let permissionRequestVersion = "screenPermissionRequestVersion"
    }

    private let currentPermissionRequestVersion = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                await Diagnostics.run()
                NSApp.terminate(nil)
            }
            return
        }

        NSApp.setActivationPolicy(.accessory)

        do {
            let controller = try FoldController()
            self.controller = controller
            self.menuBar = MenuBarController(controller: controller)
        } catch {
            presentFatal(error)
            return
        }

        Task {
            await establishCapturePermission()
            if CommandLine.arguments.contains("--demo") {
                controller?.playDemo()
            }
        }
    }

    private func establishCapturePermission() async {
        let defaults = UserDefaults.standard
        let state = await ScreenPermission.check()

        switch state {
        case .granted:
            let isFirstLaunch = !defaults.bool(forKey: Key.hasLaunchedBefore)
            controller?.isCaptureAllowed = true
            menuBar?.needsPermission = false
            defaults.set(true, forKey: Key.hasLaunchedBefore)
            if isFirstLaunch { menuBar?.openSettings() }

        case .denied, .unavailable:
            menuBar?.needsPermission = true
            menuBar?.openSettings()
            menuBar?.openOnboarding()

            // Register this stable signed build with TCC exactly once. Routine
            // checks only use preflight and can never present another alert.
            if defaults.integer(forKey: Key.permissionRequestVersion)
                < currentPermissionRequestVersion {
                defaults.set(currentPermissionRequestVersion,
                             forKey: Key.permissionRequestVersion)
                _ = ScreenPermission.requestFromSystemOnce()
            }
        }
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "BendyLocal could not start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.openSettings()
        return true
    }
}
