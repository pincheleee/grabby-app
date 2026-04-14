# Grabby — CLAUDE.md

## What is Grabby?
A native macOS YouTube downloader wrapping yt-dlp with a SwiftUI GUI. Self-contained .app that bundles yt-dlp + ffmpeg — zero terminal knowledge required from end users.

## Architecture

### Swift/SwiftUI native app
- **No Python, no Flask, no pywebview** — pure Swift with SwiftUI
- Xcode project at `Grabby.xcodeproj`
- Source in `Grabby/` directory

### File structure
```
Grabby/
├── GrabbyApp.swift              # @main entry point, window config, drag-and-drop
├── Models/
│   ├── VideoInfo.swift          # Video metadata model (decoded from yt-dlp JSON)
│   ├── DownloadJob.swift        # Download state: status, progress, speed, ETA
│   └── HistoryItem.swift        # SQLite history record
├── Views/
│   ├── ContentView.swift        # Main UI: tabs, download form, queue, history
│   ├── Components.swift         # PreviewCard, PlaylistView, ProgressCard, QueueItemCard, HistoryItemRow
│   └── SettingsView.swift       # macOS Settings window (Cmd+,)
├── Services/
│   ├── YTDLPService.swift       # Actor wrapping yt-dlp subprocess calls
│   ├── DownloadManager.swift    # ObservableObject managing jobs, notifications
│   ├── HistoryStore.swift       # SQLite history (raw C API, WAL mode)
│   └── PreferencesStore.swift   # JSON prefs at ~/Library/Application Support/Grabby/
└── Resources/
    ├── yt-dlp                   # Bundled binary (~35MB)
    ├── ffmpeg                   # Bundled binary
    └── ffprobe                  # Bundled binary
```

### Runtime
- yt-dlp runs as `Process` (subprocess) with stdout progress parsing via regex
- Playlist metadata uses `yt-dlp --flat-playlist --dump-json`
- Downloads capped at 3 concurrent via `DownloadManager` slot gating
- Final output path is captured from yt-dlp `after_move` output when available
- Settings surfaces dependency health for `yt-dlp` and `ffmpeg`
- SQLite via raw C API (`sqlite3.h`) — no SwiftData/CoreData
- Preferences stored as JSON at `~/Library/Application Support/Grabby/prefs.json`
- Preferences include separate saved defaults for video format and audio format
- macOS UserNotifications for download completion

### Binary resolution order
1. Managed `yt-dlp` at `~/Library/Application Support/Grabby/bin/yt-dlp`
2. `Bundle.main.path(forResource:)` — inside `.app` bundle
3. Homebrew paths (`/opt/homebrew/bin/`, `/usr/local/bin/`)
4. No generic PATH fallback for `yt-dlp` — fail fast if it is missing

### Validation
- `bash scripts/run_tests.sh` — arg-building and parsing coverage for `YTDLPService`
- `bash scripts/runtime_smoke.sh <url> <cookieBrowser|none> <fetch|download> [quality]` — live service smoke test
- `bash scripts/playlist_smoke.sh <playlistUrl> <cookieBrowser|none> <fetch|download>` — playlist fetch and entry-download smoke test
- `bash scripts/package_launch_smoke.sh` — mount DMG, copy app, launch packaged build, confirm process starts
- `bash scripts/soak_test.sh [iterations]` — repeat core validation paths in a lightweight loop

## Build
```bash
bash build-swift.sh
```
Produces `dist/Grabby.app` (37MB) and `dist/Grabby.dmg` (35MB).

Or open `Grabby.xcodeproj` in Xcode and build directly.

## Key conventions
- macOS 14+ (Sonoma), Apple Silicon primary target
- SwiftUI native controls — no custom CSS, follows system appearance automatically
- Segmented picker for tabs (Download / Queue / History)
- Settings via native macOS Settings window (Cmd+,)
- Main download UI has separate video/audio mode defaults
- `yt-dlp` updates must not mutate the signed app bundle; use the managed copy flow
- All error messages from yt-dlp are parsed into human-friendly strings
- Downloads save to `~/Downloads/Grabby/` by default (configurable)

## Don't
- Don't add Electron, Tauri, or web frameworks
- Don't add telemetry or analytics
- Don't require terminal interaction after .app is built
