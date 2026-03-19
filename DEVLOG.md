# Grabby — Development Log

## 2026-03-18 — v2.0.0: Major feature update

### What changed
Rewrote `grabby_app.py` from ~376 lines to ~750+ lines, adding all priority features while keeping the single-file architecture.

### Features implemented

**Playlist support**
- Detects playlist URLs (`list=` param or `/playlist?`)
- Uses `yt-dlp --flat-playlist --dump-json` to get track list without downloading
- UI shows checklist with select all/none, track numbers, durations
- Downloads selected tracks via `/api/download-playlist` endpoint (one thread per track)

**Download queue**
- New "Queue" tab showing all active/completed/failed downloads
- Each job rendered as a mini card with progress bar, speed, ETA
- Auto-polling refreshes queue every second when active downloads exist
- Jobs stored in-memory dict, keyed by UUID

**SQLite history**
- Database at `~/Library/Application Support/Grabby/history.db`
- Records: url, title, filename, format, duration, filesize, downloaded_at, thumbnail
- History tab shows list with thumbnails, dates, formats, file sizes
- Clear all button in settings

**Preferences**
- JSON file at `~/Library/Application Support/Grabby/prefs.json`
- Defaults applied to main UI on load
- Settings tab with full form: format, quality, audio format, cookie browser, download dir, theme
- Save button persists and applies immediately

**Error handling**
- 10 regex patterns matching common yt-dlp errors to friendly messages
- Fallback: last non-WARNING line from stderr, stripped of "ERROR:" prefix
- Applied to both `/api/info` and download completion

**UI polish**
- Dark/light/auto theme via CSS custom properties
- `prefers-color-scheme` media query for auto mode
- Progress bar shimmer animation (CSS `@keyframes shimmer`)
- Card fade-in animation
- Checkmark pop-in animation on completion
- Empty state placeholders for queue and history
- Tab navigation replacing the single-view layout

**Distribution hardening**
- `build.sh` now patches Info.plist: version 2.0.0, bundle ID `com.grabby.app`, min macOS 12.0
- Added `sqlite3` to hidden imports (needed for history)
- Added `--osx-bundle-identifier` to PyInstaller call

### Architecture decisions
- Kept single-file design. HTML string grew but remains manageable.
- Used `osascript` for notifications instead of pyobjc to avoid adding deps.
- Thumbnail cache is in-memory dict (lost on restart, but that's fine).
- Playlist downloads run concurrently (one thread each). Could add a semaphore for throttling later.
- Preferences apply to main UI on page load via async IIFE.

## 2026-03-18 — Post-review security & accessibility hardening

### Three-agent review
Ran senior code reviewer, UI/UX compliance expert, and macOS platform specialist in parallel. Combined findings: 3 critical security issues, 8 WCAG failures, 5 macOS platform concerns.

### Security fixes applied
1. **Command injection in `notify()`** — video titles could inject shell commands via osascript. Fixed by escaping `\` and `"`.
2. **XSS in innerHTML** — video titles rendered unescaped in WebKit webview (equivalent to local code execution). Added `esc()` and `safeSrc()` sanitizers.
3. **Thread safety** — `jobs` dict accessed from Flask threads + download threads with no locking. Added `threading.Lock()`.

### macOS platform fixes
- Hardened runtime + entitlements in build.sh (required for notarization)
- `NSAppTransportSecurity.NSAllowsLocalNetworking` in Info.plist (WebKit localhost on macOS 14+)
- Process groups for subprocess cleanup (`start_new_session=True` + `os.killpg`)
- Port auto-detection instead of hardcoded 18811 (handles port conflicts)
- Flask startup polling instead of `time.sleep(0.5)` (race condition on cold launch)
- Cookie browser default changed to None (Safari needs Full Disk Access via TCC)
- PyInstaller 6.x binary resolution path (`_internal/bin`)
- Added pyobjc hidden imports (`objc`, `Foundation`, `WebKit`, `AppKit`)
- Removed `--deep` from codesign (deprecated by Apple)

### Accessibility fixes (WCAG)
- Tabs: `<div>` -> `<button>` with `role="tab"`, `aria-selected`, `role="tablist"`, `role="tabpanel"`
- Labels: `for` attributes on all form labels, `aria-label` on toggle
- Live regions: `role="alert"` on errors, `aria-live="polite"` on progress, `role="status"` on completion
- Focus: `:focus-visible` outlines (were suppressed by `outline:none`)
- Contrast: bumped `--text-dim` to pass WCAG AA (dark: `#9999b0`, light: `#555570`)
- Motion: `prefers-reduced-motion` media query disables all animations
- System fonts: dropped Google Fonts for `-apple-system`/SF Pro (works offline, feels native)
- Target size: cancel button increased to 36x36px

## 2026-03-18 — UX fix: unified format picker + tab contrast

### Problem
- Audio formats (MP3) were hidden behind an "Audio Only" toggle — users couldn't find them
- Nav tabs (Queue/History/Settings) were gray-on-gray, hard to distinguish from background

### Fix
- Replaced separate video/audio format dropdowns + toggle with a single `<select>` using `<optgroup>` labels ("Video" and "Audio Only")
- Quality selector auto-hides when audio format selected (no quality for audio rips)
- Tabs now use opacity (0.5 inactive, 1.0 active) instead of dim gray text for better contrast

## 2026-03-18 — Swift rewrite

### Why
Python/PyInstaller produced a 58MB DMG (20MB was just the Python runtime). Code signing with hardened runtime required 4 entitlements. Startup was slow (Python interpreter boot + Flask server). Not the right stack for a macOS desktop app targeting non-technical users.

### What changed
Complete rewrite from Python/Flask/pywebview to native Swift/SwiftUI:
- **37MB app, 35MB DMG** (down from 58MB) — 1.2MB binary + 35MB yt-dlp
- **Instant startup** — no Python interpreter, no Flask server
- **Native macOS UI** — SwiftUI controls, system fonts, automatic dark/light mode
- **Proper Settings** — native macOS Settings window (Cmd+,) with NSOpenPanel file picker
- **UserNotifications** — proper macOS notification API instead of osascript hack
- **No security hacks** — no command injection surface (no osascript string interpolation), no XSS (no HTML/innerHTML)
- **Thread safety** — Swift actors (`YTDLPService`) + `@MainActor` for UI state
- **3 concurrent downloads** — `DispatchSemaphore` throttling built in

### Architecture
- 11 Swift files in Models/Views/Services pattern
- `YTDLPService` is a Swift actor — all subprocess calls are inherently thread-safe
- `DownloadManager` is `@MainActor ObservableObject` — drives SwiftUI reactivity
- `HistoryStore` uses raw SQLite C API (no CoreData/SwiftData overhead)
- yt-dlp/ffmpeg still run as subprocess `Process` — same regex parsing carries over from Python version

### Known limitations
- Queue is in-memory only — lost on app restart
- Info.plist LSUIElement not set (app shows in dock, which is actually fine)

### Next steps
- First-launch onboarding modal explaining cookie setup
- Rate-limit concurrent playlist downloads (semaphore of 3)
- Search/filter in history
- Re-download from history
- Proper macOS menu bar items (About, Quit)
- Consider moving to pywebview's built-in API instead of Flask for simpler IPC
