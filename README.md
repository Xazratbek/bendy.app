# bendy.app

> BendyLocal brings an iPhone 18-inspired opening and closing animation to your Mac desktop.

BendyLocal is a native macOS menu bar utility that turns the last live frame of your display into a smooth 3D fold, driven by the physical hinge angle. The result is a MacBook experience inspired by the fluid opening and closing animation of iPhone 18: close the lid and your desktop folds away; open it again and the desktop unfolds before the live capture stream resumes.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-111827?style=flat-square)
![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-111827?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-2f855a?style=flat-square)

## Download

Download the latest distribution from [GitHub Releases](../../releases/latest). Open the DMG, drag **BendyLocal.app** to **Applications**, and launch it from the menu bar.

> The release build targets Apple Silicon Macs running macOS 14 or later.

## What it does

- Tracks the MacBook hinge angle using the lid sensor.
- Captures the selected display locally and folds it through a Metal renderer.
- Uses a snapshot while waking so the unfold animation does not wait on capture.
- Supports three built-in looks: Silk, Shade, and Frost.
- Includes a calibration flow, display selection, battery-aware quality, and pause controls.
- Keeps frames on-device; no account, network service, or upload pipeline is required.

## Requirements

- Apple Silicon MacBook
- macOS 14 or later
- Screen Recording permission

The lid-angle sensor is a private macOS hardware interface, so behavior is intended for compatible MacBook hardware rather than desktop Macs or virtual machines.

## Build locally

This project is intentionally built with the macOS Command Line Tools and does not require Xcode.

```sh
make build     # Compile the optimized binary
make preview   # Render the fold effect offscreen to .dist/preview/
make dmg       # Build .dist/BendyLocal-<version>.dmg
make diagnose  # Check capture, display, and lid-sensor health
```

For a stable local Screen Recording grant, create the local signing identity once and install the app:

```sh
make setup
```

The app is compiled for `arm64-apple-macos14.0`. The generated `.build/`, `.dist/`, and `build/` directories are local output and are intentionally excluded from Git.

## Permissions

On first launch, macOS asks for Screen Recording access. Grant it in **System Settings -> Privacy & Security -> Screen Recording**, then relaunch BendyLocal if macOS requests it. The app needs this permission to read the display image that becomes the fold surface.

## Releases

Releases are automated through [`.github/workflows/release.yml`](.github/workflows/release.yml). Push a semantic version tag to build a DMG and publish it as a GitHub Release:

```sh
git tag v0.1.5
git push origin v0.1.5
```

The version in `Resources/Info.plist` must match the release tag before publishing.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/BendyLocal/` | Main menu bar app |
| `Sources/BendyLocal/Capture/` | ScreenCaptureKit and permission handling |
| `Sources/BendyLocal/Sensor/` | Background lid-angle polling and physics source |
| `Sources/BendyLocal/Render/` | Metal renderer, shaders, and overlay window |
| `Sources/BendyLocal/UI/` | SwiftUI settings and calibration screens |
| `Sources/UnderGlass/` | Separate lightweight telemetry overlay app |
| `Tools/FoldPreview/` | Offscreen renderer for visual checks |

## Attribution

BendyLocal is MIT-derived from Daniel Radosa's [Clamshell](https://github.com/danielradosa/clamshell). See [`ATTRIBUTION.md`](ATTRIBUTION.md) and [`LICENSE`](LICENSE) for the full notices.

## Privacy

Screen frames and sensor data stay on the Mac. BendyLocal does not include analytics, telemetry, accounts, or a network upload service.