import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

enum ScreenPermission {
    enum State: Equatable {
        case granted
        case denied
        case unavailable(String)
    }

    static func check() async -> State {
        // SCShareableContent may present the system permission alert as a side
        // effect. Preflight first so routine checks and polling stay silent.
        guard CGPreflightScreenCaptureAccess() else { return .denied }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return content.displays.isEmpty ? .unavailable("No capturable display.") : .granted
        } catch {
            let nsError = error as NSError
            if nsError.code == -3801 { return .denied }
            return .unavailable(error.localizedDescription)
        }
    }

    @discardableResult
    static func requestFromSystemOnce() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
