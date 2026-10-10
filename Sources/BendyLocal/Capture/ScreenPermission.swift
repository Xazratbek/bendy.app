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

    static let preflightFlag = "--preflight-screen-capture"
    static let requestFlag = "--request-screen-capture"

    static func check() async -> State {
        // SCShareableContent may present the system permission alert as a side
        // effect. Preflight first so routine checks and polling stay silent.
        guard CGPreflightScreenCaptureAccess() else {
            // A grant made after launch is invisible to this process (see
            // isGrantedNow). Report it anyway so the caller relaunches into it.
            return await isGrantedNow() ? .granted : .denied
        }

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

    /// CGPreflightScreenCaptureAccess() is evaluated once per process: after the
    /// user flips the switch in System Settings, a running app keeps reading
    /// "denied" until it relaunches. A fresh copy of this binary reads the
    /// current TCC answer, silently, so polling sees the grant within a second.
    static func isGrantedNow() async -> Bool {
        await runSelf(preflightFlag)
    }

    @discardableResult
    static func requestFromSystemOnce() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Fixes a grant that System Settings shows as on but macOS no longer
    /// honours — what happens when the entry was recorded for an older
    /// signature of this app. Drops the entry, then registers this build again
    /// so it reappears in the list for a single fresh toggle.
    static func resetAndRequest() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.bendylocal.mac"
        await run(URL(fileURLWithPath: "/usr/bin/tccutil"), ["reset", "ScreenCapture", bundleID])
        // In a fresh process: this one already asked once and won't ask again.
        await runSelf(requestFlag)
        openSystemSettings()
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

    @discardableResult
    private static func runSelf(_ flag: String) async -> Bool {
        guard let path = Bundle.main.executablePath else { return false }
        return await run(URL(fileURLWithPath: path), [flag])
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
