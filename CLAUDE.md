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
- Downloads throttled to 3 concurrent via `DispatchSemaphore`
- SQLite via raw C API (`sqlite3.h`) — no SwiftData/CoreData
- Preferences stored as JSON at `~/Library/Application Support/Grabby/prefs.json`
- macOS UserNotifications for download completion

### Binary resolution order
1. `Bundle.main.path(forResource:)` — inside .app bundle
2. Homebrew paths (`/opt/homebrew/bin/`, `/usr/local/bin/`)
3. System PATH

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
- All error messages from yt-dlp are parsed into human-friendly strings
- Downloads save to `~/Downloads/Grabby/` by default (configurable)

## Don't
- Don't add Electron, Tauri, or web frameworks
- Don't add telemetry or analytics
- Don't require terminal interaction after .app is built
