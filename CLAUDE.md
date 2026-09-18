# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BendyLocal is a macOS menu bar utility that folds the desktop as the laptop lid closes, tracking the physical hinge angle in real time (via the private lid-angle HID sensor) and unfolding it again on wake — a personal, independently-built alternative to the commercial app trybendy.app. It's MIT-derived from Daniel Radosa's Clamshell (see `ATTRIBUTION.md`); the BendyLocal name, icon, and local build packaging are this project's own.

## Build, run, and diagnose

This is a Command-Line-Tools-only project — **no Xcode is assumed to be installed.** `Package.swift` exists and `swift build` happens to work here, but the real, authoritative build path is the `Makefile`, which invokes `swiftc` directly (Xcode's `PackageDescription` in bare CLT is inconsistent) and compiles the Metal shaders from source at runtime rather than an offline `.metallib` (the offline `metal` compiler ships only with Xcode). Always build/verify through `make`, not raw `swift build`.

- `make setup` — first-time: creates a signing certificate, installs, resets permission, launches.
- `make build` / `make debug` — compile the optimized / debug-symboled arm64 binary.
- `make install` — build, sign, install to `/Applications`.
- `make run` — install and launch.
- `make diagnose` — writes `~/Library/Logs/BendyLocal-diagnostics.txt`: screen-recording permission state, display list, lid-sensor availability/angle. The only way to check capture/sensor health without a human watching the screen.
- `make preview` — renders the fold effect offscreen to PNGs in `.dist/preview/` (no window, no display, no permission needed) — compiles just `Shaders.swift` + `FoldRenderer.swift` + `FoldCurve.swift` + `FoldStyle.swift` + `Tools/FoldPreview/main.swift`. This is the fastest way to sanity-check a shader or curve change.
- `make icon` — regenerates `Resources/AppIcon.icns` from `Tools/IconRender/main.swift` (a standalone Core Graphics tool, same "no Xcode asset catalog" constraint). Never hand-edit the `.icns`.
- `make dmg` — builds the signed `.dist/BendyLocal-*.dmg`.
- `make certificate` / `make remove-certificate` — manage the local codesigning identity. A stable identity is what keeps the Screen Recording TCC grant alive across rebuilds; an ad-hoc signature changes the code hash every build and macOS re-prompts. Avoid `make reset-permission` during normal development for the same reason.

There is no test target. Verification is: `make build`, `make preview` (visual check of the shader/curve), `make diagnose` (permission/sensor check), and — because a passing build proves nothing about feel — physically opening and closing the lid to check the fold tracks smoothly, clears automatically past the engage angle, and `Esc` pauses it.

## Architecture

**State machine.** `FoldController` (`Sources/BendyLocal/FoldController.swift`) is the coordinator: `idle → armed → active`, driven by a `Timer`-based watch loop (`watchTick`, 60–120Hz) that reads lid angle and transitions state. `armed` means "watching, no overlay yet"; `active` means the overlay is shown and rendering. Sleep/wake and screen-lock notifications suspend/resume it; a "pending unfold" mechanism replays the open animation if the Mac wakes with the lid already open past the engage angle.

**Timing: two clocks, one owner at a time.** The fold's physical simulation (`AngleSource.tick()`, a critically-damped spring toward the sensor's target angle) is advanced by *either* the watch `Timer` *or* the overlay's `CADisplayLink` (in `FoldController.drawFrame`), never both — gated by `renderLoopIsDriving` (`overlay?.metalView.isRenderingEnabled`). This is deliberate: driving physics from a `Timer` while a separate `CADisplayLink` draws produces visible judder even at a steady frame rate, since the two clocks drift against each other. When the overlay is actually rendering, it ticks the physics itself so simulation and draw land on the same frame; otherwise (idle/armed, before there's anything to draw) the `Timer` is the only clock. Read the comment on `renderLoopIsDriving` before touching either loop.

**Sensor is polled off the main thread.** `LidAngleSensor` (`Sources/BendyLocal/Sensor/LidAngleSensor.swift`) talks to the lid-angle HID device (usage page `0x20`, usage `0x8A`) via `IOHIDDeviceGetReport`, a synchronous kernel round-trip that can occasionally take several milliseconds. A dedicated background thread polls it continuously (240Hz) and caches the latest value behind a lock; `currentAngle()` only ever reads that cache. Never call the raw IOHID read from the main thread again — it's exactly the kind of stall that shows up as animation stutter.

**Render pipeline.** `ScreenCapture` (ScreenCaptureKit) delivers frames to `FoldController`, which hands the latest GPU texture to `FoldRenderer` (`Sources/BendyLocal/Render/FoldRenderer.swift`) each `CADisplayLink` tick. The renderer blurs the source, folds a grid mesh by `fold` progress (0–1, from `FoldCurve`), and composites — parameterized by a `FoldStyle` (perspective, blur radius, darkening, shadow, vignette, edge softness, sheen, curvature). On close, the last live frame is blitted into a private `snapshot` texture, which is what plays back on wake before a fresh capture stream is available. `OverlayWindow` is a borderless, click-through, all-spaces window at `CGShieldingWindowLevel()`, one per launch (lazily created, reused).

**Settings & styles.** `Settings` (`Sources/BendyLocal/Model/Settings.swift`) is a `UserDefaults`-backed `ObservableObject` — the single source of truth for both the live effect and the Settings UI. `FoldStyle` (`Codable`) defines three built-ins (`.satin`/"Silk", `.eclipse`/"Shade", `.glacier`/"Frost") plus user-saved custom styles (JSON-encoded array in defaults); `Settings.style` applies four global intensity multipliers (perspective/blur/shadow/edge scale) on top of whichever style is selected. Style differences only become visible as `fold` approaches 1 — at rest (lid open, angle above `engageAngle`) every style looks identical by design, because every style-dependent term in the shader/preview is scaled by `fold`.

**SwiftUI is pre-macro only.** `@State`, `@Observable`, and `@Bindable` are Swift macros, and the SwiftUIMacros compiler plugin isn't available in a Command-Line-Tools-only toolchain — using them fails the build with "plugin for module 'SwiftUIMacros' not found". This codebase uses only the older `ObservableObject` / `@Published` / `@ObservedObject` / `@Binding` mechanism. View-local UI state (sheet/alert presentation, form drafts) belongs on the nearest `*Model` class (see `SettingsModel`, `CalibrationModel`), not as `@State` in the view.

**Display targeting.** `FoldController.targetScreen` picks the overlay's screen: an explicit `Settings.preferredDisplayID` if set and still connected, else the display where `CGDisplayIsBuiltin` is true, else `NSScreen.main`. Don't reintroduce name-matching on `localizedName` ("Built-in") — it breaks under non-English system languages.

**Power awareness.** `Settings.batterySaver` + `FoldController.isOnBatteryPower()` (via `IOPSCopyPowerSourcesInfo`) halve capture resolution and drop to 30fps on battery; this is threaded through `ScreenCapture.start(on:reducedQuality:)`.

## Second app: UnderGlass

`Sources/UnderGlass/` is a separate, much smaller menu bar app ("live Mac X-ray": an illustrated circuit-board dashboard driven by real CPU / memory / battery / network telemetry, revealed full-screen by hotkey or as the lid closes). It is **not** built by the main `Makefile` or `Package.swift`; it has its own makefile:

- `make -f UnderGlass.mk build` — renders the icon (`Tools/UnderGlassIcon`), compiles, bundles and ad-hoc signs `.dist/UnderGlass.app`.
- `make -f UnderGlass.mk smoke` — builds, launches with `--smoke-test`, which shows and clears the overlay, prints one telemetry line (`cpu=… memory=… battery=… sensor=…`) and exits. This is its only automated check.
- `make -f UnderGlass.mk install` / `dmg`.

Key differences from BendyLocal: pure AppKit + Core Graphics drawing (`GlassView`), no Metal, no ScreenCaptureKit and therefore no Screen Recording permission; telemetry comes from Mach host statistics, IOKit power sources and `getifaddrs` in `Telemetry.swift`; hotkey is ⌃⌥⌘U (Escape while shown). Bundle ID `app.underglass.mac`.

It compiles `Sources/BendyLocal/Sensor/LidAngleSensor.swift` directly into its binary, so **changes to that file affect both apps** — rebuild and smoke-test UnderGlass too.

Other paths: `Sources/BendyLocalLegacy/` is an old single-file version kept for reference only (not built); `Tools/HIDDump.swift` is a standalone HID device dump used when investigating the lid sensor. `build/` is legacy generated output. This directory is not a git repository. Unrelated products (e.g. Liquid Desktop in `~/programming/LiquidDesktop`) live in their own folders and must not be added here.

## Global identifiers

- Bundle ID: `app.bendylocal.mac`.
- Pause hotkey: ⌃⌥⌘B system-wide (`PauseHotKey`), independent of the `Esc` pause that's only armed while the overlay is visible (`EscapeHotKey`).
