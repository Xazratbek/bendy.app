import SwiftUI

struct SettingsView: View {

    @ObservedObject private var settings = Settings.shared
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SettingsPreviewPane(model: model)
                .frame(width: 286)
                .padding(24)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))

            Divider()

            ScrollView {
                controls.padding(24)
            }
            .frame(width: 426)
        }
        .frame(width: 760, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0.25, green: 0.55, blue: 0.96))
        .onAppear { model.beginPreview() }
        .onDisappear { model.endPreview() }
        .sheet(isPresented: $model.showingCalibration) {
            CalibrationView(model: model.makeCalibrationModel()) { suggested in
                if let suggested { settings.engageAngle = suggested }
                model.showingCalibration = false
            }
        }
        .alert("Save Style", isPresented: $model.showingSaveStyle) {
            TextField("Name", text: $model.newStyleName)
            Button("Cancel", role: .cancel) { model.newStyleName = "" }
            Button("Save") {
                settings.saveCurrentAsCustomStyle(named: model.newStyleName)
                model.newStyleName = ""
            }
        } message: {
            Text("Saves the current intensity sliders as a new style you can pick again later.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Appearance")
                        .font(.title2.weight(.semibold))
                    Text("Automatic lid-following fold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            section("Style") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(settings.allStyles) { style in
                            styleChip(style)
                        }
                        Button {
                            model.showingSaveStyle = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.callout.weight(.semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .help("Save the current sliders as a new style")
                    }
                }

                Text(currentStyleBlurb)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 30, alignment: .top)
            }

            section("Intensity") {
                slider("Blur", "camera.filters", $settings.blurScale, 0...2)
                slider("Depth", "cube", $settings.perspectiveScale, 0...2)
                slider("Shadow", "moon.fill", $settings.shadowScale, 0...2)
                slider("Edge", "square.dashed", $settings.edgeScale, 0...3)
            }

            section("Behaviour") {
                HStack(alignment: .top) {
                    labelled("Clears above", value: "\(Int(settings.engageAngle))°") {
                        Slider(value: $settings.engageAngle, in: 30...115)
                    }
                    Button("Calibrate…") { model.showingCalibration = true }
                        .controlSize(.small)
                        .padding(.top, 20)
                }
                Text("Open the lid past this angle and the effect gets out of the way.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labelled("Opening animation",
                         value: String(format: "%.2fs", settings.unfoldDuration)) {
                    Slider(value: $settings.unfoldDuration, in: 0.3...1.5)
                }
                Text("A lid opens faster than the screen switches on, so the unfold runs on its own clock.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.soundEnabled) {
                    Text("Click when the effect clears").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 2)
            }

            section("Advanced") {
                Toggle(isOn: $settings.batterySaver) {
                    Text("Reduce quality on battery").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Display").font(.callout)
                    Picker("", selection: $settings.preferredDisplayID) {
                        ForEach(model.availableDisplays) { option in
                            Text(option.isBuiltIn ? "\(option.name) (built-in)" : option.name)
                                .tag(option.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Label("Pause shortcut", systemImage: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(PauseHotKey.displayString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                HStack {
                    Label("\(settings.bendCount) bends and counting", systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider()

            HStack {
                Label("Auto safety enabled", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
                    .controlSize(.regular)
            }
        }
        .disabled(!settings.enabled)
        .opacity(settings.enabled ? 1 : 0.5)
    }

    private var currentStyleBlurb: String {
        settings.allStyles.first { $0.id == settings.styleID }?.blurb ?? ""
    }

    private func styleChip(_ style: FoldStyle) -> some View {
        let isSelected = settings.styleID == style.id
        let isCustom = style.id.hasPrefix("custom-")
        return Text(style.name)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color(nsColor: .controlColor))
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .onTapGesture { settings.styleID = style.id }
            .contextMenu {
                if isCustom {
                    Button("Delete", role: .destructive) { settings.deleteCustomStyle(id: style.id) }
                }
            }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content()
        }
    }

    private func slider(_ title: String, _ symbol: String,
                        _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(title).font(.callout)
            } icon: {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            Slider(value: value, in: range)

            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func labelled<Content: View>(
        _ title: String, value: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

private struct SettingsPreviewPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("BendyLocal").font(.headline)
                Spacer()
                Circle()
                    .fill(model.hasSensor ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.hasSensor ? "Sensor ready" : "Preview only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LidPreview(fold: model.previewFold, style: settings.style)
                .frame(height: 190)

            VStack(spacing: 3) {
                if model.hasSensor {
                    Text("\(Int(model.displayedAngle))°")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(model.isScrubbing ? "Preview angle" : "Live lid angle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "laptopcomputer.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No lid sensor").font(.callout.weight(.medium))
                    Text("Drag below to preview").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Preview an angle by hand", isOn: $model.isScrubbing)
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.scrubAngle, in: 0...120)
                    Text("\(Int(model.scrubAngle))°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .disabled(!model.isScrubbing)
                .opacity(model.isScrubbing ? 1 : 0.4)
            }

            Button { model.playDemo() } label: {
                Label("Play Full-Screen Preview", systemImage: "play.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!settings.enabled)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield.checkered").foregroundStyle(.green)
                Text("Capture failure hides the overlay automatically. Press Esc anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LidPreview: View {
    let fold: Double
    let style: FoldStyle

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black)

                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.22, green: 0.45, blue: 0.92),
                                     Color(red: 0.55, green: 0.32, blue: 0.78),
                                     Color(red: 0.98, green: 0.42, blue: 0.40)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                Circle().fill(.red.opacity(0.85))
                                Circle().fill(.yellow.opacity(0.85))
                                Circle().fill(.green.opacity(0.85))
                            }
                            .frame(height: 6)
                            .padding(9)
                        }
                        .overlay(
                            LinearGradient(colors: [.clear, .black.opacity(style.shadowStrength * fold)],
                                           startPoint: .bottom, endPoint: .top)
                            .clipShape(RoundedRectangle(cornerRadius: 5)))
                        .blur(radius: style.blurRadius * fold * 0.045)
                        .brightness(-style.darkening * fold * 0.62)
                        .rotation3DEffect(.degrees(fold * 80), axis: (x: 1, y: 0, z: 0),
                                          anchor: .bottom, perspective: style.perspective * 0.64)
                        .padding(12)
                }
                .frame(height: max(geo.size.height - 12, 1))

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.55))
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                        .frame(width: 52, height: 3)
                        .padding(.top, 1)
                }
                .frame(height: 9)
                .padding(.horizontal, 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
