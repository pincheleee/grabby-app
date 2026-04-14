# Grabby

A native macOS YouTube downloader built with SwiftUI, `yt-dlp`, and `ffmpeg`. Paste a URL, preview it, and download it without leaving the app.

## Project Status

- Status: stable
- Active app: `Grabby.xcodeproj` / `Grabby/`
- Last reliability pass: 2026-04-13
- Build: `bash build-swift.sh`
- Bundle output: `dist/Grabby.app` and `dist/Grabby.dmg`

The old Python prototype is still in the repo for reference, but the supported desktop app is the native Swift/SwiftUI build.

## Install

### From DMG (recommended)

```bash
bash build-swift.sh
```

This produces `dist/Grabby.dmg`. Double-click it, drag Grabby to Applications, done.

Everything the app needs is bundled inside the app bundle: `yt-dlp`, `ffmpeg`, and `ffprobe`.

### Run from Xcode

```bash
open Grabby.xcodeproj
```

Build the `Grabby` scheme, or run:

```bash
xcodebuild -project Grabby.xcodeproj -scheme Grabby -configuration Debug build
```

## What `build-swift.sh` does

1. Downloads yt-dlp binary (from GitHub releases)
2. Copies `ffmpeg` and `ffprobe` from Homebrew if needed
3. Builds the Swift app with `xcodebuild`
4. Signs bundled binaries and `Grabby.app`
5. Creates `dist/Grabby.dmg` with drag-to-Applications layout

Build requires Xcode and `ffmpeg` to be installed locally.

## Features

- Native macOS app built with SwiftUI
- Paste or drop a URL to auto-preview title, thumbnail, duration, and metadata
- Playlist preview with per-entry selection
- Video: MP4 / MKV / WebM at Best / 1080p / 720p / 480p / 360p
- Audio only: MP3 / FLAC / WAV / Opus / M4A
- Browser cookie passthrough (Safari / Chrome / Firefox / Brave)
- Separate saved defaults for video format and audio format
- Download queue with cancel support
- Download history stored in SQLite
- Dependency health shown in Settings
- `yt-dlp` updates install to a managed copy in app support instead of mutating `Grabby.app`
- Real-time progress bar with speed + ETA
- Show in Finder when complete
- Native notifications on completion
- Downloads to `~/Downloads/Grabby/` by default, configurable in Settings

## Cookie Support

YouTube often requires login for previews or downloads. Select your browser in Grabby and stay signed into YouTube in that browser.

- Chrome, Firefox, and Brave are supported directly
- Safari may require Full Disk Access because of macOS privacy controls
- Cookie-backed preview and playlist metadata fetches were verified in the 2026-04-13 reliability pass

## Architecture

```
Grabby.app
├── Contents/
│   ├── MacOS/Grabby          # Native Swift binary
│   └── Resources/
│       ├── Grabby.icns       # App icon
│       ├── yt-dlp            # Bundled downloader
│       ├── ffmpeg            # Bundled transcoder
│       └── ffprobe           # Bundled probe binary
```

Source layout:

```text
Grabby/
├── GrabbyApp.swift
├── Models/
├── Services/
└── Views/
```

- UI: SwiftUI
- Downloader integration: `Process` + progress parsing in `YTDLPService`
- Queue/state: `DownloadManager` on `@MainActor`
- History: SQLite via `HistoryStore`
- Preferences: JSON at `~/Library/Application Support/Grabby/prefs.json`

## Validation

Local checks:

```bash
bash scripts/run_tests.sh
```

Live runtime smoke:

```bash
bash scripts/runtime_smoke.sh 'https://www.youtube.com/watch?v=jNQXAC9IVRw' none download
```

Use `chrome fetch` as the second and third arguments to exercise the cookie-backed metadata path.

## Recent Fixes

2026-04-13 reliability pass:

- Fixed cookie-browser argument ordering for metadata fetches and playlist fetches
- Fixed final merged file path capture so Finder reveal and history point to the real output file
- Fixed the audio default setting so it applies independently from the video format default
- Removed the Swift 6 concurrency warning in the download completion path
- Moved yt-dlp self-updates to a managed copy under `~/Library/Application Support/Grabby/bin`
- Added repo-local arg/parser tests and a runtime smoke script
- Removed dead completion-sheet state and the unused theme preference
