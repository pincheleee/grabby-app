# Changelog

## [3.0.0] — 2026-03-18

### Rewritten in Swift/SwiftUI
- **Complete rewrite** from Python/Flask/pywebview to native Swift/SwiftUI
- **37MB app** (down from 58MB) — eliminated 20MB Python runtime
- **35MB DMG** (down from 58MB compressed)
- **1.2MB binary** — the rest is yt-dlp (35MB, unavoidable)
- **Instant startup** — no Python interpreter boot or Flask server init
- **Native macOS UI** — SwiftUI controls, system appearance, automatic dark/light
- **Native Settings** — proper macOS Settings window (Cmd+,) with file picker dialog
- **Native notifications** — UserNotifications API instead of osascript
- **No security surface** — no HTML/innerHTML (eliminated XSS), no osascript string interpolation (eliminated command injection)
- **Swift actors** — YTDLPService is thread-safe by design
- **Proper process management** — Process with process group kill on cancel
- Same feature set: playlist support, download queue, history, drag-and-drop, cookie passthrough

## [2.0.1] — 2026-03-18

### Changed
- **Unified format picker**: Video (MP4/MKV/WebM) and Audio (MP3/FLAC/M4A/WAV/Opus) formats now in a single dropdown with optgroups -- no more hidden audio toggle
- Quality selector auto-hides when an audio format is selected
- Nav tabs: improved contrast -- inactive tabs use opacity instead of dim gray text
- Removed audio-only toggle (replaced by unified format dropdown)

## [2.0.0] — 2026-03-18

### Added
- **Playlist support**: detect playlist URLs, show track list with checkboxes, download selected tracks
- **Download queue**: tabbed UI with queue view showing all active/completed downloads with individual progress
- **Download history**: SQLite-backed log of all past downloads (title, date, path, format, filesize, thumbnail)
- **Preferences system**: persistent settings stored in `~/Library/Application Support/Grabby/prefs.json`
  - Default format, quality, audio format, cookie browser
  - Custom download directory
  - Theme selection (dark/light/auto)
- **Settings tab**: full preferences UI with save button
- **Drag-and-drop**: drop a YouTube URL anywhere on the window to start
- **macOS notifications**: system notification when download completes (via osascript)
- **Better error messages**: pattern-matched yt-dlp errors into human-friendly messages
  - Age-restricted, private, geo-blocked, copyright, rate-limited, login required
- **Thumbnail/info cache**: avoids re-fetching metadata for the same URL
- **Cancel downloads**: cancel button on active downloads (kills subprocess)
- **1080p quality option**: added to quality selector
- **File size estimate**: shown in preview metadata when available
- **Progress bar shimmer**: CSS animation on active progress bars
- **Card animations**: fade-in transitions on cards and state changes
- **Completion animation**: pop-in effect on the checkmark icon
- **Empty states**: proper placeholder UI for queue, history when empty
- **Keyboard shortcuts**: Cmd+N (new download), Cmd+, (settings), Cmd+V (focus URL input)
- **yt-dlp self-update**: button in settings to check for and install yt-dlp updates
- **Clear history**: button in settings to wipe download history
- **Queue polling**: auto-refresh queue view for real-time progress
- **Tab navigation**: Download / Queue / History / Settings tabs
- **Theme toggle**: header button to cycle dark/light/auto themes
- **Dark/light/auto themes**: full CSS variable system with system preference detection
- **Bundle ID**: `com.grabby.app` in Info.plist
- **Info.plist patching**: version, minimum macOS 12.0, copyright in build script
- **CLAUDE.md**: project documentation for AI-assisted development
- **CHANGELOG.md**: this file
- **DEVLOG.md**: development log

### Changed
- Window size increased to 700x860 (from 680x820)
- Minimum window size increased to 520x640 (from 500x600)
- App version bumped to 2.0.0
- Added `sqlite3`, `objc`, `Foundation`, `WebKit`, `AppKit` to PyInstaller hidden imports
- Cookie selector now shared between video and audio modes (single dropdown)
- Switched from Google Fonts (Outfit/JetBrains Mono) to macOS system fonts (SF Pro/SF Mono) -- eliminates network dependency, works offline, feels native
- Color contrast improved for dim text (dark: `#9999b0`, light: `#555570`) -- passes WCAG AA
- Cookie browser default changed from Safari to None (Safari requires Full Disk Access for TCC)
- Concurrent playlist downloads throttled to 3 via ThreadPoolExecutor (was unbounded)
- Job UUIDs extended from 8 to 12 chars to reduce collision risk
- Flask startup uses port polling instead of sleep(0.5) -- eliminates race condition
- Port auto-detection: if 18811 is busy, picks a free port automatically

### Fixed
- **Security: Command injection in notifications** -- video titles with quotes/backslashes could inject arbitrary AppleScript commands via osascript
- **Security: XSS in HTML template** -- video titles rendered via innerHTML without escaping; added `esc()` and `safeSrc()` sanitizers to all user-data injection points
- **Thread safety** -- `jobs` dict now protected by `threading.Lock()` for mutation and iteration
- **Process cleanup** -- cancel now kills entire process group (`os.killpg`) instead of just yt-dlp parent, preventing orphaned ffmpeg processes
- **SQLite concurrency** -- added WAL journal mode and 10s busy timeout for concurrent writes
- **Binary resolution** -- added `_internal/bin` path for PyInstaller 6.x compatibility
- **Download directory permissions** -- graceful fallback if configured path is not writable
- **Info cache** -- auto-clears at 100 entries to prevent memory leak
- **Download dir race** -- path captured at call time, not read from mutable global mid-download
- Error messages now parsed from yt-dlp stderr instead of generic "Download failed"
- Merger/post-processing destination filename now captured correctly
- Download directory respects preferences (not just hardcoded ~/Downloads/Grabby)

### Accessibility (WCAG)
- Tab navigation: `<div>` tabs replaced with `<button>` elements with `role="tab"`, `aria-selected`, `role="tablist"`
- Tab panels: added `role="tabpanel"` to all content sections
- Error messages: added `role="alert"` and `aria-live="assertive"`
- Progress: added `aria-live="polite"` to progress stats
- Completion: added `role="status"` to done card
- Form labels: added `for` attributes linking all `<label>` to their `<select>` elements
- Audio toggle: added `aria-label="Audio only mode"`
- Thumbnail: `alt` text now set to video title on fetch
- Focus visibility: added `:focus-visible` outline styles (was removed by `outline:none`)
- Reduced motion: `@media (prefers-reduced-motion: reduce)` disables all animations
- Cancel button: increased target size to 36x36px minimum

### Build
- Hardened runtime enabled (`--options runtime`) -- required for notarization
- Entitlements file added: unsigned memory, library validation disabled, network client/server
- `NSAppTransportSecurity.NSAllowsLocalNetworking` added to Info.plist for localhost WebKit
- Removed `--deep` from final codesign (Apple deprecated, inner binaries signed individually)
- Removed dead architecture conditional for yt-dlp download URL

## [1.0.0] — 2026-03-18

### Initial release
- Native macOS window via pywebview + Flask
- Video download: MP4/MKV/WebM at Best/720p/480p/360p
- Audio extraction: MP3/FLAC/WAV/Opus/M4A
- Browser cookie passthrough (Safari/Chrome/Firefox/Brave)
- Real-time progress bar with speed + ETA
- Auto-preview on paste (thumbnail, title, duration, view count)
- Dependency check on launch
- Show in Finder on completion
- Build script: PyInstaller -> code sign -> DMG
- Bundled yt-dlp + ffmpeg binaries
- Dark theme UI with JetBrains Mono + Outfit fonts
