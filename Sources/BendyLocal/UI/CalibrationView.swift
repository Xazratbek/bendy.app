import SwiftUI

/// A three-step guided flow that samples the lid-angle sensor at two
/// positions the user actually chooses — "where I type" and "where I want
/// the effect to start" — instead of asking them to guess a degree number on
/// a slider.
@MainActor
final class CalibrationModel: ObservableObject {
    enum Step { case intro, sampleOpen, sampleEngage, done }

    @Published var step: Step = .intro
    @Published private(set) var liveAngle: Double = 0
    @Published private(set) var openAngle: Double?
    @Published private(set) var engageAngle: Double?
    @Published private(set) var isSampling = false

    private weak var controller: FoldController?
    private var ticker: Timer?
    private var sampleBuffer: [Double] = []

    var hasSensor: Bool { controller?.hasSensor ?? false }

    init(controller: FoldController?) {
        self.controller = controller
    }

    func begin() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func end() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let controller else { return }
        liveAngle = controller.currentRawAngle
        if isSampling { sampleBuffer.append(liveAngle) }
    }

    /// Captures a short, averaged reading rather than a single instantaneous
    /// one — the hinge sensor has noise, and the lid is never perfectly still
    /// in someone's hand.
    func startSample(duration: TimeInterval = 0.6, completion: @escaping (Double) -> Void) {
        guard !isSampling else { return }
        sampleBuffer = []
        isSampling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            let average = self.sampleBuffer.isEmpty
                ? self.liveAngle
                : self.sampleBuffer.reduce(0, +) / Double(self.sampleBuffer.count)
            self.isSampling = false
            completion(average)
        }
    }

    func captureOpen() {
        startSample { [weak self] value in
            self?.openAngle = value
            self?.step = .sampleEngage
        }
    }

    func captureEngage() {
        startSample { [weak self] value in
            self?.engageAngle = value
            self?.step = .done
        }
    }

    /// The angle to save, biased slightly toward "open" so the effect doesn't
    /// start before the user actually meant it to.
    var suggestedEngageAngle: Double? {
        guard let engageAngle else { return nil }
        return min(max(engageAngle + 4, 30), 115)
    }
}

struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel
    let onFinish: (Double?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch model.step {
            case .intro: intro
            case .sampleOpen: sampleOpen
            case .sampleEngage: sampleEngage
            case .done: done
            }
        }
        .padding(28)
        .frame(width: 420, height: 320)
        .onAppear { model.begin() }
        .onDisappear { model.end() }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Calibrate to your habits").font(.title3.weight(.semibold))
            if model.hasSensor {
                Text("Two quick captures: how you normally have the lid open, and roughly where you'd like the effect to kick in. Takes about ten seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start") { model.step = .sampleOpen }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Text("This Mac doesn't expose a lid-angle sensor, so there's nothing to calibrate — use the angle slider in Behaviour instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close") { onFinish(nil) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var sampleOpen: some View {
        stepBody(
            title: "1. Open it the way you normally would",
            hint: "Set the lid where you'd actually sit and type, then capture.",
            angle: model.liveAngle,
            action: model.captureOpen
        )
    }

    private var sampleEngage: some View {
        stepBody(
            title: "2. Tilt to where the effect should start",
            hint: "Close it partway, to the point you'd want the fold to begin.",
            angle: model.liveAngle,
            action: model.captureEngage
        )
    }

    private func stepBody(title: String, hint: String, angle: Double,
                          action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            Text(hint)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(Int(angle))°")
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(model.isSampling ? .secondary : .primary)
                .contentTransition(.numericText())

            Button {
                action()
            } label: {
                if model.isSampling {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Capture").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSampling)
            .frame(width: 160)
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Set").font(.title3.weight(.semibold))
            if let suggested = model.suggestedEngageAngle {
                Text("Effect will start around \(Int(suggested))°, based on your open angle of \(Int(model.openAngle ?? 0))°.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Done") { onFinish(model.suggestedEngageAngle) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
