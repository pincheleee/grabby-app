# Grabby

A native macOS YouTube downloader. Paste a URL, grab your content.

## Install

### From DMG (recommended)

```bash
bash build.sh
```

This produces `dist/Grabby.dmg`. Double-click it, drag Grabby to Applications, done.

Everything is bundled inside the app — yt-dlp, ffmpeg, Python runtime — no Homebrew or terminal required after install.

### Run without building

```bash
pip3 install flask pywebview
brew install yt-dlp ffmpeg
python3 grabby_app.py
```

## What the build does

1. Downloads yt-dlp binary (from GitHub releases)
2. Downloads ffmpeg binary (universal macOS build)
3. Generates app icon and .icns
4. Bundles everything into Grabby.app via PyInstaller
5. Creates Grabby.dmg with drag-to-Applications layout

Build takes ~1-2 minutes. Requires Python 3.10+ and pip.

## Features

- Native macOS window (WebKit, not a browser tab)
- Paste URL → auto-preview with thumbnail, title, duration
- Video: MP4 / MKV / WebM at Best / 720p / 480p / 360p
- Audio only: MP3 / FLAC / WAV / Opus / M4A
- Browser cookie passthrough (Safari / Chrome / Firefox / Brave)
- Real-time progress bar with speed + ETA
- Show in Finder when complete
- Dependency check on launch
- Downloads to ~/Downloads/Grabby/

## Cookie Support

YouTube requires login for most downloads. Select your browser from the dropdown — Grabby reads your existing cookies. Just be signed into YouTube in that browser.

## Architecture

```
Grabby.app
├── Contents/
│   ├── MacOS/Grabby          # PyInstaller bootstrap
│   ├── Frameworks/            # Python runtime + libs
│   │   └── bin/
│   │       ├── yt-dlp         # Bundled
│   │       ├── ffmpeg         # Bundled
│   │       └── ffprobe        # Bundled
│   └── Resources/
│       ├── Grabby.icns        # App icon
│       └── bin/               # Backup binary location
└── (self-contained, no external deps)
```

Backend: Flask on localhost:18811
Frontend: HTML/CSS/JS in native WebKit window via pywebview
Downloader: yt-dlp subprocess with progress parsing
