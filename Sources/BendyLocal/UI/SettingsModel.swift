import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class SettingsModel: ObservableObject {
    @Published var previewFold: Double = 0
    @Published var liveAngle: Double = 0

    @Published var isScrubbing: Bool {
        didSet { sample() }
    }

    @Published var scrubAngle: Double = 60 {
        didSet { if isScrubbing { sample() } }
    }

    var hasSensor: Bool { controller?.hasSensor ?? false }
    var displayedAngle: Double { isScrubbing ? scrubAngle : liveAngle }

    // View-presentation state. This lives here rather than as `@State` in
    // SettingsView because `@State` is implemented as a Swift macro, and this
    // project builds with the Command Line Tools alone — no Xcode, so no
    // SwiftUIMacros plugin. Plain ObservableObject/@Published, being the
    // pre-macro mechanism, works fine.
    @Published var showingCalibration = false
    @Published var showingSaveStyle = false
    @Published var newStyleName = ""

    private weak var controller: FoldController?
    private var ticker: Timer?

    init(controller: FoldController?) {
        self.controller = controller
        self.isScrubbing = (controller?.hasSensor ?? false) == false
    }

    func beginPreview() {
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func endPreview() {
        ticker?.invalidate()
        ticker = nil
        isScrubbing = false
    }

    func playDemo() {
        isScrubbing = false
        controller?.playDemo()
    }

    private func sample() {
        guard let controller else { return }
        let nextAngle = controller.currentRawAngle
        if abs(nextAngle - liveAngle) > 0.05 { liveAngle = nextAngle }

        let angle = isScrubbing ? scrubAngle : nextAngle
        let nextFold = FoldCurve.progress(
            angle: angle, engageAngle: Settings.shared.engageAngle
        )
        if abs(nextFold - previewFold) > 0.0001 { previewFold = nextFold }
    }

    func makeCalibrationModel() -> CalibrationModel {
        CalibrationModel(controller: controller)
    }

    struct DisplayOption: Identifiable, Equatable {
        let id: Int
        let name: String
        let isBuiltIn: Bool
    }

    /// 0 is always "Automatic" (built-in panel if there is one, else the main
    /// display); the rest are every screen currently connected.
    var availableDisplays: [DisplayOption] {
        let screens = NSScreen.screens.compactMap { screen -> DisplayOption? in
            guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
            else { return nil }
            let builtIn = CGDisplayIsBuiltin(number.uint32Value) != 0
            return DisplayOption(id: number.intValue, name: screen.localizedName, isBuiltIn: builtIn)
        }
        return [DisplayOption(id: 0, name: "Automatic", isBuiltIn: false)] + screens
    }
}
