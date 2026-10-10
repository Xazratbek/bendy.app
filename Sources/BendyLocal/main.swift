import AppKit

// Helper modes answer in a fresh process and exit before any UI starts. See
// ScreenPermission.isGrantedNow() for why a fresh process is needed.
if CommandLine.arguments.contains(ScreenPermission.preflightFlag) {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
}
if CommandLine.arguments.contains(ScreenPermission.requestFlag) {
    exit(CGRequestScreenCaptureAccess() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
