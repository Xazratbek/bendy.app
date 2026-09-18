import AppKit
import Metal
import Combine
import IOKit.ps

@MainActor
final class FoldController {
    private enum State { case idle, armed, active }

    private let settings = Settings.shared
    private let angleSource = AngleSource()
    private let device: MTLDevice
    private let renderer: FoldRenderer
    private let capture: ScreenCapture

    private var overlay: OverlayWindow?
    private var latestFrame: CapturedFrame?
    private var watchTimer: Timer?
    private var state: State = .idle
    private var cancellables = Set<AnyCancellable>()
    private var wasEngaged = false
    private var hasCountedCurrentClose = false
    private let escapeHotKey = EscapeHotKey()

    private var snapshot: MTLTexture?

    private let armMargin: Double = 15

    private let armVelocity: Double = 1

    private let disarmHysteresis: Double = 5

    private let engageFold: Double = 0.004
    private let clearFold: Double = 0.0004
    private let engageTravel: Double = 0.006
    private let clearTravel: Double = 0.002

    private var unfoldDuration: TimeInterval { settings.unfoldDuration }

    private var unfoldStart: Date?
    private var unfoldFrom: Double = 1

    private var isSuspended = false

    private var pendingUnfold: Date?

    private var lastSeenAngle: Double = AngleSource.restingAngle
    private var lastClosingAt = Date.distantPast
    var isPaused = false { didSet { if isPaused { teardown() } else { angleSource.reset() } } }

    var isCaptureAllowed = false

    var hasSensor: Bool { angleSource.hasSensor }
    var currentRawAngle: Double { angleSource.rawAngle }

    @Published private(set) var previewFold: Double = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ControllerError.noMetalDevice }
        self.device = device
        self.renderer = try FoldRenderer(device: device)
        self.capture = ScreenCapture(device: device)

        capture.onFrame = { [weak self] frame in self?.latestFrame = frame }
        capture.onFailure = { [weak self] _ in
            Task { @MainActor in self?.handleCaptureFailure() }
        }

        if !angleSource.hasSensor {
            angleSource.mode = .manual(AngleSource.restingAngle)
        }
        isSuspended = ScreenLock.isLocked

        settings.$enabled
            .sink { [weak self] enabled in if !enabled { self?.teardown() } }
            .store(in: &cancellables)

        observeSleepAndWake()
        observeScreenLock()
        startWatching()
    }

    func setMode(_ mode: AngleSource.Mode) {
        angleSource.mode = mode
        angleSource.reset()
    }

    func playDemo() {
        angleSource.mode = .demo
        angleSource.reset(to: AngleSource.restingAngle)
        demoDeadline = Date().addingTimeInterval(3.6)
    }

    private var demoDeadline: Date?

    private func endDemoIfFinished() {
        guard let deadline = demoDeadline, Date() >= deadline else { return }
        demoDeadline = nil
        angleSource.mode = angleSource.hasSensor ? .sensor : .manual(AngleSource.restingAngle)
        angleSource.reset()
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.prepareForSleep() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        }
    }

    private func observeScreenLock() {
        ScreenLock.observe(onLock: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trace("screen locked — dropping snapshot and hiding")
                self.hideOverlay()
                self.snapshot = nil
                self.latestFrame = nil
                self.state = .idle
                self.isSuspended = true
            }
        }, onUnlock: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trace("screen unlocked")
                self.isSuspended = false
                self.angleSource.reset()
                if self.pendingUnfold != nil {
                    self.startCapture()
                    self.scheduleWatch(interval: 1.0 / 120.0)
                }
            }
        })
    }

    private func prepareForSleep() {
        guard !isSuspended else { return }
        isSuspended = true
        let fold = currentFold()
        if fold > engageFold {
            pendingUnfold = Date().addingTimeInterval(60)
        }
        unfoldStart = nil
        trace(String(format: "sleeping at fold %.3f — suspended, unfold owed: %@",
                     fold, pendingUnfold != nil ? "yes" : "no"))
        hideOverlay()
        state = .armed
        capture.stop()
        latestFrame = nil
    }

    private func handleWake() {
        guard settings.enabled, !isPaused, isCaptureAllowed else {
            isSuspended = false
            return
        }
        guard !ScreenLock.isLocked else {
            trace("wake: locked — holding the unfold until unlock")
            snapshot = nil
            state = .idle
            scheduleWatch(interval: 1.0 / 10.0)
            return
        }
        isSuspended = false

        startCapture()

        angleSource.reset()
        scheduleWatch(interval: 1.0 / 120.0)

        let sensorFold = FoldCurve.progress(
            angle: angleSource.angle, engageAngle: settings.engageAngle
        )
        trace(String(format: "wake: angle %.1f fold %.3f snapshot %@",
                     angleSource.angle, sensorFold, snapshot != nil ? "yes" : "no"))

        guard snapshot != nil else {
            state = .armed
            return
        }
        beginUnfold(from: sensorFold)
        state = .active
        showOverlay()
    }

    private func startWatching() {
        scheduleWatch(interval: 1.0 / 60.0)
    }

    private func scheduleWatch(interval: TimeInterval) {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    // While the overlay's CADisplayLink is running, it advances the spring
    // simulation itself (in drawFrame, right before rendering) so the physics
    // step lands on the exact frame it's drawn for. If this watch timer ticked
    // it too, the two independent clocks would fight over the same state and
    // the fold would visibly judder even at a steady frame rate. Everywhere
    // else (idle/armed, before the overlay exists) this timer is the only
    // clock, so it keeps driving the tick.
    private var renderLoopIsDriving: Bool { overlay?.metalView.isRenderingEnabled == true }

    private func watchTick() {
        if !renderLoopIsDriving { angleSource.tick() }
        endDemoIfFinished()

        guard settings.enabled, !isPaused else {
            if state != .idle { teardown() }
            return
        }

        if isSuspended {
            if state == .active { transition(to: .armed) }
            return
        }

        if let deadline = pendingUnfold {
            if Date() > deadline {
                trace("owed unfold expired")
                pendingUnfold = nil
            } else if latestFrame != nil {
                trace("playing the unfold owed from the lid close")
                pendingUnfold = nil
                beginUnfold(from: 1)
                transition(to: .active)
            }
        }

        let angle = angleSource.rawAngle
        let engage = settings.engageAngle
        let fold = currentFold()
        previewFold = fold

        let closingFast = angleSource.closingVelocity > armVelocity
        if closingFast { lastClosingAt = Date() }
        let isClosingRecently = Date().timeIntervalSince(lastClosingAt) < 0.35
        let armAngle = min(engage + armMargin, 118)

        let wasShut = lastSeenAngle < FoldCurve.closedAngle + 8
        let isOpening = angle > FoldCurve.closedAngle + 8
        if wasShut, isOpening, unfoldStart == nil, snapshot != nil,
           pendingUnfold == nil, !isSuspended {
            trace(String(format: "lid opening observed (%.1f -> %.1f), starting unfold",
                         lastSeenAngle, angle))
            beginUnfold(from: 1)
            if state != .active { transition(to: .active) }
        }
        lastSeenAngle = angle
        _ = angleSource.consumeTeleport()

        switch state {
        case .idle:
            if angle < armAngle || closingFast { transition(to: .armed) }
        case .armed:
            if angle > engage + disarmHysteresis && !isClosingRecently {
                transition(to: .idle)
            } else if FoldCurve.travel(angle: angle, engageAngle: engage) > engageTravel,
                      hasSomethingToDraw {
                transition(to: .active)
            }
        case .active:
            if FoldCurve.travel(angle: angle, engageAngle: engage) < clearTravel,
               unfoldStart == nil { transition(to: .armed) }
        }

        trackClearSound(fold: fold)
        trackBendCount(fold: fold)
    }

    private static let traceURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/BendyLocal-trace.log")

    private static let traceStart = Date()

    private func trace(_ message: String) {
        let stamp = String(format: "%7.3f", Date().timeIntervalSince(Self.traceStart))
        let line = "[\(stamp)] \(message)\n"
        if Self.isTracingToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.traceURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.traceURL)
        }
    }

    private static let isTracingToStderr =
        ProcessInfo.processInfo.environment["CLAMSHELL_TRACE"] == "1"

    private func transition(to next: State) {
        guard next != state else { return }
        let previous = state
        state = next
        trace("state \(previous) -> \(next)")

        switch next {
        case .idle:
            hideOverlay()
            capture.stop()
            latestFrame = nil
            scheduleWatch(interval: 1.0 / 60.0)

        case .armed:
            if previous == .idle { startCapture() }
            if previous == .active { hideOverlay() }
            scheduleWatch(interval: 1.0 / 120.0)

        case .active:
            showOverlay()
            scheduleWatch(interval: 1.0 / 120.0)
        }
    }

    private var hasSomethingToDraw: Bool { latestFrame != nil || snapshot != nil }

    private func currentFold() -> Double {
        let sensorFold = FoldCurve.progress(
            angle: angleSource.angle, engageAngle: settings.engageAngle
        )
        guard let start = unfoldStart else { return sensorFold }

        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < unfoldDuration else {
            unfoldStart = nil
            return sensorFold
        }

        let progress = elapsed / unfoldDuration
        let eased = 1 - pow(1 - progress, 3)
        return unfoldFrom + (sensorFold - unfoldFrom) * eased
    }

    private func currentSoftness(fold: Double) -> Double {
        if unfoldStart != nil {
            return FoldCurve.softness(forTravel: pow(max(fold, 0), 1.0 / 3.0))
        }
        return FoldCurve.softness(angle: angleSource.angle, engageAngle: settings.engageAngle)
    }

    private func beginUnfold(from fold: Double) {
        unfoldFrom = max(fold, 0.85)
        unfoldStart = Date()
        trace(String(format: "unfold started from %.3f over %.2fs", unfoldFrom, unfoldDuration))
    }

    private func startCapture() {
        guard isCaptureAllowed else { return }
        let displayID = displayIDForOverlay()
        let reduced = settings.batterySaver && Self.isOnBatteryPower()
        Task { try? await capture.start(on: displayID, reducedQuality: reduced) }
    }

    /// Cheap, synchronous read of whether the Mac is currently running off its
    /// battery (as opposed to wall power). Used to trade capture quality for
    /// battery life when the user has that on — a laptop lid effect that
    /// drains the battery faster is a bad trade for most people.
    private static func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }

    private func handleCaptureFailure() {
        trace("capture stream ended")
        latestFrame = nil
        if state == .active { transition(to: .armed) }
    }

    private func displayIDForOverlay() -> CGDirectDisplayID {
        let screen = targetScreen
        let number = screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    /// Picks which physical screen gets the fold. Honors an explicit choice
    /// from Settings when one is set and still connected; otherwise prefers
    /// the laptop's own panel — found via `CGDisplayIsBuiltin`, which (unlike
    /// matching on `localizedName`) works regardless of the system language —
    /// and falls back to the main display for external-monitor-only Macs.
    private var targetScreen: NSScreen? {
        if settings.preferredDisplayID != 0,
           let chosen = NSScreen.screens.first(where: {
               ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.int32Value
                   == Int32(settings.preferredDisplayID)
           }) {
            return chosen
        }
        let builtIn = NSScreen.screens.first {
            guard let number = $0.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
        return builtIn ?? NSScreen.main
    }

    private func ensureOverlay() -> OverlayWindow? {
        if let overlay { return overlay }
        guard let screen = targetScreen else { return nil }
        let window = OverlayWindow(screen: screen, device: device)
        window.metalView.onFrame = { [weak self] layer in
            MainActor.assumeIsolated { self?.drawFrame(into: layer) }
        }
        overlay = window
        trace("overlay WINDOW CREATED (should happen exactly once)")
        return window
    }

    private func showOverlay() {
        guard !ScreenLock.isLocked else {
            trace("refusing to show overlay: screen is locked")
            snapshot = nil
            state = .armed
            return
        }
        guard let overlay = ensureOverlay() else { return }
        overlay.show()
        trace("overlay shown")
        escapeHotKey.arm { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
        }
    }

    private func hideOverlay() {
        escapeHotKey.disarm()
        if overlay?.isVisible == true { trace("overlay hidden") }
        overlay?.hide()
    }

    private func drawFrame(into layer: CAMetalLayer) {
        angleSource.tick()
        guard let source = latestFrame?.texture ?? snapshot else { return }
        let fold = currentFold()
        let softness = currentSoftness(fold: fold)
        guard let drawable = layer.nextDrawable() else { return }
        renderer.render(source: source, fold: fold, softness: softness,
                        style: settings.style, drawable: drawable)

        if let live = latestFrame?.texture, fold > 0.25 {
            let hadSnapshot = snapshot != nil
            snapshot = renderer.copy(live, into: snapshot)
            if !hadSnapshot, snapshot != nil {
                trace("snapshot taken (\(live.width)x\(live.height)) — this is what unfolds on wake")
            }
        }
    }

    private func trackClearSound(fold: Double) {
        let engaged = fold > engageFold
        defer { wasEngaged = engaged }
        guard wasEngaged, !engaged, settings.soundEnabled else { return }
        Chime.playClear()
    }

    /// A "bend" is one full close, counted the moment the fold reaches all the
    /// way shut, then re-armed once it's fully open again so the next close
    /// counts too. Purely cosmetic — see Settings.bendCount.
    private func trackBendCount(fold: Double) {
        if fold > 0.97 {
            if !hasCountedCurrentClose {
                hasCountedCurrentClose = true
                settings.recordBend()
            }
        } else if fold < 0.05 {
            hasCountedCurrentClose = false
        }
    }

    private func teardown() {
        state = .idle
        hideOverlay()
        capture.stop()
        latestFrame = nil
        previewFold = 0
        scheduleWatch(interval: 1.0 / 60.0)
    }

    enum ControllerError: LocalizedError {
        case noMetalDevice
        var errorDescription: String? { "This Mac has no Metal-capable GPU." }
    }
}
