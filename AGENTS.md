# Repository Guidelines

## Project Structure & Module Organization

Application code lives in `Sources/BendyLocal/`. `Capture/` handles ScreenCaptureKit and permissions, `Sensor/` reads the lid angle off the main thread (`LidAngleSensor` polls on a background thread; callers only read the cached value), `Render/` contains Metal and overlay code, `Model/` stores fold settings, and `UI/` contains SwiftUI and menu bar views, including the calibration wizard (`CalibrationView.swift`) and the global pause shortcut (`PauseHotKey.swift`). `FoldController.swift` coordinates them; while the overlay's `CADisplayLink` is running it drives `AngleSource.tick()` itself (in `drawFrame`) rather than the watch `Timer`, so the physics step and the draw call land on the same clock — see the `renderLoopIsDriving` comment there before changing either loop. Metadata is in `Resources/Info.plist`; the app icon is generated from `Tools/IconRender/main.swift` via `make icon` — never hand-edit `Resources/AppIcon.icns`; other utilities are in `Tools/`; signing automation is in `Scripts/`. `Sources/BendyLocalLegacy/` is reference-only. Treat `.build/`, `.dist/`, and `build/` as generated output.

SwiftUI in this project is limited to the pre-macro API (`ObservableObject`, `@Published`, `@ObservedObject`, `@Binding`). `@State`, `@Observable`, and `@Bindable` are Swift macros and the SwiftUIMacros compiler plugin isn't available in a Command-Line-Tools-only toolchain — view-local state goes on the nearest `*Model` class instead (see `SettingsModel`).

## Build, Test, and Development Commands

- `make build`: compile the optimized arm64 binary.
- `make debug`: compile with debug symbols.
- `make install`: build, sign, and install to `/Applications`.
- `make run`: install and launch the menu bar app.
- `make preview`: render variants to `.dist/preview/` without capture permission.
- `make diagnose`: verify permission, display capture, and lid sensor.
- `make icon`: regenerate `Resources/AppIcon.icns` from `Tools/IconRender/main.swift`.
- `make dmg`: create the signed `.dist/BendyLocal-*.dmg`.
- `make clean`: remove generated output.

Run `make certificate` once for a stable signing identity. Avoid `make reset-permission` during normal development because it removes Screen Recording access.

## Coding Style & Naming Conventions

Use Swift 5 conventions, four-space indentation, and one primary type per file. Name types in `UpperCamelCase` and members in `lowerCamelCase`. Keep UI updates on `@MainActor`; isolate capture and rendering from SwiftUI views. Comment only non-obvious safety, timing, permission, or GPU behavior. No formatter or linter is configured, so match neighboring files.

## Testing Guidelines

There is no XCTest target. Before submitting, run `make build`, `make preview`, and `make diagnose`. Inspect every style after renderer changes. For sensor or overlay work, verify physical lid movement, automatic clearing, and the `Esc` pause. A successful build alone does not verify display behavior.

## Commit & Pull Request Guidelines

This directory has no Git history or established convention. Use short imperative subjects, such as `Fix stale screen capture permission`. Pull requests should describe behavior, safety impact, verification commands, and tested hardware. Include screenshots for UI changes and trace excerpts for sensor fixes. Exclude generated apps, DMGs, logs, and previews.

## Security & Permissions

Screen frames must remain on-device. Preserve the bundle identifier and signing identity unless documenting a permission migration. Overlay failures must hide the window, stop capture, and leave `Esc` available.
