import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BendyLocal needs to see your screen")
                        .font(.title3.weight(.semibold))
                    Text(model.statusLine)
                        .font(.callout)
                        .foregroundStyle(model.state == .granted ? .green : .secondary)
                }
            }

            Text("""
            The fold effect is a live copy of your desktop bent in 3D, so macOS \
            counts it as screen recording. Nothing is recorded, uploaded or \
            written to disk — frames go straight to the GPU and are discarded.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Open Privacy & Security ▸ Screen & System Audio Recording.")
                    step(2, "Turn BendyLocal on once.")
                    step(3, "BendyLocal will detect the grant and relaunch itself.")
                }
                .padding(6)
            }

            if case .unavailable(let reason) = model.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open System Settings") { ScreenPermission.openSystemSettings() }
                Button("Check Again") { model.recheck() }
                Spacer()
                Button(model.state == .granted ? "Relaunch Now" : "Relaunch") {
                    ScreenPermission.relaunch()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var state: ScreenPermission.State = .denied
    @Published private(set) var isChecking = false

    var onGranted: (() -> Void)?
    private var pollTimer: Timer?

    var statusLine: String {
        if isChecking { return "Checking…" }
        switch state {
        case .granted:        return "Granted. Relaunch to start using it."
        case .denied:         return "Not granted yet."
        case .unavailable:    return "Screen capture is unavailable."
        }
    }

    func recheck() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await ScreenPermission.check()
            self.state = result
            self.isChecking = false
            if result == .granted {
                self.stopPolling()
                self.onGranted?()
            }
        }
    }

    func startPolling() {
        recheck()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
