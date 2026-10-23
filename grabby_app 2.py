#!/usr/bin/env python3
"""
Grabby.app — Native macOS YouTube downloader.
Fully self-contained: bundles yt-dlp + ffmpeg inside the .app.
v2.0.0 — Playlist support, download queue, history, preferences, notifications.
"""

import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from flask import Flask, request, jsonify

# ---------------------------------------------------------------------------
# App metadata
# ---------------------------------------------------------------------------
APP_VERSION = "2.0.0"
APP_BUNDLE_ID = "com.grabby.app"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Grabby"
APP_SUPPORT.mkdir(parents=True, exist_ok=True)
DB_PATH = APP_SUPPORT / "history.db"
PREFS_PATH = APP_SUPPORT / "prefs.json"

DEFAULT_PREFS = {
    "download_dir": str(Path.home() / "Downloads" / "Grabby"),
    "format": "mp4",
    "quality": "best",
    "audio_format": "mp3",
    "cookie_browser": "",
    "audio_only": False,
    "theme": "dark",
}


def load_prefs():
    try:
        with open(PREFS_PATH) as f:
            saved = json.load(f)
        merged = {**DEFAULT_PREFS, **saved}
        return merged
    except (FileNotFoundError, json.JSONDecodeError):
        return dict(DEFAULT_PREFS)


def save_prefs(prefs):
    with open(PREFS_PATH, "w") as f:
        json.dump(prefs, f, indent=2)


PREFS = load_prefs()
DOWNLOAD_DIR = Path(PREFS["download_dir"])
try:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
except PermissionError:
    DOWNLOAD_DIR = Path.home() / "Downloads" / "Grabby"
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# SQLite history
# ---------------------------------------------------------------------------

def init_db():
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT,
            title TEXT,
            filename TEXT,
            format TEXT,
            duration INTEGER,
            filesize INTEGER,
            downloaded_at TEXT,
            thumbnail TEXT
        )
    """)
    conn.commit()
    conn.close()


init_db()


def add_to_history(url, title, filename, fmt, duration=0, filesize=0, thumbnail=""):
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.execute(
        "INSERT INTO history (url, title, filename, format, duration, filesize, downloaded_at, thumbnail) VALUES (?,?,?,?,?,?,?,?)",
        (url, title, filename, fmt, duration, filesize, datetime.now().isoformat(), thumbnail),
    )
    conn.commit()
    conn.close()


def get_history(limit=50):
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM history ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def clear_history():
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.execute("DELETE FROM history")
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# Binary paths
# ---------------------------------------------------------------------------

def get_bundle_bin_dir() -> Path:
    if getattr(sys, "frozen", False):
        base = Path(sys._MEIPASS)
        candidates = [
            base / "bin",
            base / "_internal" / "bin",
            base.parent / "Resources" / "bin",
            base / ".." / "Resources" / "bin",
        ]
    else:
        base = Path(__file__).parent
        candidates = [base / "bin"]
    for c in candidates:
        if c.is_dir():
            return c.resolve()
    return base


BUNDLE_BIN = get_bundle_bin_dir()


def find_bin(name: str) -> str:
    bundled = BUNDLE_BIN / name
    if bundled.is_file() and os.access(str(bundled), os.X_OK):
        return str(bundled)
    for p in [f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/bin/{name}"]:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    result = subprocess.run(["which", name], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return name


YTDLP = find_bin("yt-dlp")
FFMPEG = find_bin("ffmpeg")

ENHANCED_PATH = str(BUNDLE_BIN) + ":" + os.environ.get("PATH", "")
for extra in ["/opt/homebrew/bin", "/usr/local/bin"]:
    if extra not in ENHANCED_PATH:
        ENHANCED_PATH = extra + ":" + ENHANCED_PATH
ENHANCED_ENV = {**os.environ, "PATH": ENHANCED_PATH}

# ---------------------------------------------------------------------------
# Thumbnail cache
# ---------------------------------------------------------------------------
_info_cache: dict = {}

# ---------------------------------------------------------------------------
# Error parsing
# ---------------------------------------------------------------------------

ERROR_PATTERNS = [
    (r"Sign in to confirm your age|age-restricted", "This video is age-restricted. Sign into YouTube in your browser and select that browser for cookies."),
    (r"Private video|Video unavailable", "This video is private or unavailable."),
    (r"geo.?restricted|not available in your country", "This video is geo-restricted and not available in your region."),
    (r"copyright", "This video was removed due to a copyright claim."),
    (r"Sign in|login required|cookies", "YouTube requires login. Select your browser from the cookie dropdown — make sure you're signed into YouTube in that browser."),
    (r"HTTP Error 429|Too Many Requests", "Rate limited by YouTube. Wait a few minutes and try again."),
    (r"HTTP Error 403|Forbidden", "Access forbidden. Try selecting a different browser for cookies."),
    (r"is not a valid URL|Unsupported URL", "This doesn't look like a valid YouTube URL."),
    (r"No video formats found", "No downloadable formats found for this video."),
    (r"Incomplete data|interrupted", "Download was interrupted. Check your internet connection and try again."),
]


def parse_error(stderr: str) -> str:
    for pattern, message in ERROR_PATTERNS:
        if re.search(pattern, stderr, re.IGNORECASE):
            return message
    # Fallback: return last meaningful line
    lines = [l.strip() for l in stderr.strip().split("\n") if l.strip() and "WARNING" not in l]
    if lines:
        last = lines[-1]
        if last.startswith("ERROR:"):
            last = last[6:].strip()
        return last
    return "Download failed. Check the URL and try again."


# ---------------------------------------------------------------------------
# macOS notification
# ---------------------------------------------------------------------------

def notify(title: str, message: str):
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    safe_msg = message.replace("\\", "\\\\").replace('"', '\\"')
    try:
        subprocess.Popen([
            "osascript", "-e",
            f'display notification "{safe_msg}" with title "{safe_title}"'
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Flask
# ---------------------------------------------------------------------------

flask_app = Flask(__name__)
flask_app.config["PROPAGATE_EXCEPTIONS"] = True
jobs: dict = {}
jobs_lock = threading.Lock()
_download_pool = ThreadPoolExecutor(max_workers=3)


def get_video_info(url, cookie_browser=None):
    cache_key = f"{url}:{cookie_browser}"
    if cache_key in _info_cache:
        return _info_cache[cache_key]
    if len(_info_cache) > 100:
        _info_cache.clear()
    cmd = [YTDLP, "--dump-json", "--no-download", url]
    if cookie_browser:
        cmd.extend(["--cookies-from-browser", cookie_browser])
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=ENHANCED_ENV)
    if result.returncode != 0:
        raise RuntimeError(parse_error(result.stderr))
    info = json.loads(result.stdout)
    _info_cache[cache_key] = info
    return info


def get_playlist_info(url, cookie_browser=None):
    cmd = [YTDLP, "--flat-playlist", "--dump-json", "--no-download", url]
    if cookie_browser:
        cmd.extend(["--cookies-from-browser", cookie_browser])
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=ENHANCED_ENV)
    if result.returncode != 0:
        raise RuntimeError(parse_error(result.stderr))
    entries = []
    for line in result.stdout.strip().split("\n"):
        if line.strip():
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


def run_download(job_id, url, fmt, cookie_browser, audio_only, audio_format, quality, dl_dir_str=None):
    job = jobs[job_id]
    job["status"] = "downloading"
    dl_dir = Path(dl_dir_str) if dl_dir_str else Path(PREFS.get("download_dir", str(DOWNLOAD_DIR)))
    dl_dir.mkdir(parents=True, exist_ok=True)
    out = str(dl_dir / "%(title)s.%(ext)s")
    cmd = [YTDLP, "--newline", "--progress", "--ffmpeg-location", os.path.dirname(FFMPEG) or ".", "-o", out]
    if cookie_browser:
        cmd.extend(["--cookies-from-browser", cookie_browser])
    if audio_only:
        cmd.extend(["-x", "--audio-format", audio_format, "--audio-quality", "0"])
    else:
        fmts = {
            "best": ["-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"] if fmt == "mp4"
                    else ["-f", "bestvideo+bestaudio/best"],
            "1080": ["-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]"],
            "720": ["-f", "bestvideo[height<=720]+bestaudio/best[height<=720]"],
            "480": ["-f", "bestvideo[height<=480]+bestaudio/best[height<=480]"],
            "360": ["-f", "bestvideo[height<=360]+bestaudio/best[height<=360]"],
        }
        cmd.extend(fmts.get(quality, fmts["best"]))
        cmd.extend(["--merge-output-format", fmt])
    cmd.append(url)

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1, env=ENHANCED_ENV,
                                start_new_session=True)
        job["pid"] = proc.pid
        for line in proc.stdout:
            line = line.strip()
            m = re.search(r"(\d+\.?\d*)%", line)
            if m:
                job["progress"] = float(m.group(1))
            m = re.search(r"(\d+\.?\d*\s*[KMG]iB/s)", line)
            if m:
                job["speed"] = m.group(1)
            m = re.search(r"ETA\s+(\S+)", line)
            if m:
                job["eta"] = m.group(1)
            m = re.search(r"Destination:\s+(.+)$", line)
            if m:
                job["filename"] = m.group(1).strip()
            # Capture merge/post-processing
            if "[Merger]" in line or "[ExtractAudio]" in line:
                m2 = re.search(r'Destination:\s+(.+)$|"(.+?)"', line)
                if m2:
                    job["filename"] = (m2.group(1) or m2.group(2)).strip()
            # Capture filesize from download line
            m = re.search(r"of\s+~?\s*(\d+\.?\d*\s*[KMG]iB)", line)
            if m:
                job["filesize_str"] = m.group(1)
            job["log"].append(line)

        proc.wait()
        if proc.returncode == 0:
            job["status"] = "done"
            job["progress"] = 100.0
            if not job.get("filename"):
                files = sorted(dl_dir.iterdir(), key=lambda f: f.stat().st_mtime, reverse=True)
                if files:
                    job["filename"] = str(files[0])
            # Add to history
            title = job.get("title", "")
            if not title and job.get("filename"):
                title = Path(job["filename"]).stem
            filesize = 0
            if job.get("filename") and os.path.isfile(job["filename"]):
                filesize = os.path.getsize(job["filename"])
            add_to_history(
                url=job["url"],
                title=title,
                filename=job.get("filename", ""),
                fmt=fmt if not audio_only else audio_format,
                duration=job.get("duration", 0),
                filesize=filesize,
                thumbnail=job.get("thumbnail", ""),
            )
            notify("Grabby", f"Downloaded: {title or 'Complete'}")
        else:
            job["status"] = "error"
            stderr_text = "\n".join(job["log"])
            job["error"] = parse_error(stderr_text)
    except Exception as e:
        job["status"] = "error"
        job["error"] = str(e)


@flask_app.route("/")
def index():
    return HTML_PAGE


@flask_app.route("/api/version")
def api_version():
    return jsonify({"version": APP_VERSION})


@flask_app.route("/api/check-deps")
def api_check_deps():
    def ok(path):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return True
        return subprocess.run(["which", os.path.basename(path)], capture_output=True, env=ENHANCED_ENV).returncode == 0
    return jsonify({"ytdlp": ok(YTDLP), "ffmpeg": ok(FFMPEG), "ytdlp_path": YTDLP, "ffmpeg_path": FFMPEG})


@flask_app.route("/api/info", methods=["POST"])
def api_info():
    data = request.json
    url = data.get("url", "").strip()
    if not url:
        return jsonify({"error": "No URL"}), 400
    try:
        # Check if playlist
        is_playlist = "list=" in url and "watch?" in url
        if is_playlist or "/playlist?" in url:
            entries = get_playlist_info(url, data.get("cookie_browser") or None)
            if len(entries) > 1:
                return jsonify({
                    "is_playlist": True,
                    "count": len(entries),
                    "entries": [
                        {
                            "title": e.get("title", f"Track {i+1}"),
                            "url": e.get("url") or e.get("webpage_url") or e.get("id", ""),
                            "duration": e.get("duration", 0),
                            "id": e.get("id", ""),
                        }
                        for i, e in enumerate(entries)
                    ],
                    "title": entries[0].get("playlist_title", "Playlist") if entries else "Playlist",
                })

        info = get_video_info(url, data.get("cookie_browser") or None)
        # Estimate filesize
        filesize = info.get("filesize") or info.get("filesize_approx") or 0
        formats = info.get("formats", [])
        if not filesize and formats:
            best = [f for f in formats if f.get("filesize")]
            if best:
                filesize = max(f["filesize"] for f in best)

        return jsonify({
            "title": info.get("title", ""),
            "thumbnail": info.get("thumbnail", ""),
            "duration": info.get("duration", 0),
            "uploader": info.get("uploader", ""),
            "view_count": info.get("view_count", 0),
            "filesize": filesize,
            "is_playlist": False,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@flask_app.route("/api/download", methods=["POST"])
def api_download():
    data = request.json
    url = data.get("url", "").strip()
    if not url:
        return jsonify({"error": "No URL"}), 400
    jid = str(uuid.uuid4())[:12]
    dl_dir_now = PREFS.get("download_dir", str(DOWNLOAD_DIR))
    with jobs_lock:
        jobs[jid] = {
            "id": jid, "url": url, "status": "queued", "progress": 0.0,
            "speed": "", "eta": "", "filename": "", "error": "", "log": [],
            "pid": None, "title": data.get("title", ""), "thumbnail": data.get("thumbnail", ""),
            "duration": data.get("duration", 0), "created_at": time.time(),
        }
    _download_pool.submit(
        run_download, jid, url, data.get("format", "mp4"), data.get("cookie_browser") or None,
        data.get("audio_only", False), data.get("audio_format", "mp3"),
        data.get("quality", "best"), dl_dir_now,
    )
    return jsonify({"job_id": jid})


@flask_app.route("/api/download-playlist", methods=["POST"])
def api_download_playlist():
    data = request.json
    urls = data.get("urls", [])
    job_ids = []
    dl_dir_now = PREFS.get("download_dir", str(DOWNLOAD_DIR))
    for entry in urls:
        url = entry if isinstance(entry, str) else entry.get("url", "")
        title = "" if isinstance(entry, str) else entry.get("title", "")
        if not url:
            continue
        if not url.startswith("http"):
            url = f"https://www.youtube.com/watch?v={url}"
        jid = str(uuid.uuid4())[:12]
        with jobs_lock:
            jobs[jid] = {
                "id": jid, "url": url, "status": "queued", "progress": 0.0,
                "speed": "", "eta": "", "filename": "", "error": "", "log": [],
                "pid": None, "title": title, "thumbnail": "", "duration": 0,
                "created_at": time.time(),
            }
        _download_pool.submit(
            run_download, jid, url, data.get("format", "mp4"), data.get("cookie_browser") or None,
            data.get("audio_only", False), data.get("audio_format", "mp3"),
            data.get("quality", "best"), dl_dir_now,
        )
        job_ids.append(jid)
    return jsonify({"job_ids": job_ids})


@flask_app.route("/api/status/<jid>")
def api_status(jid):
    job = jobs.get(jid)
    if not job:
        return jsonify({"error": "Not found"}), 404
    return jsonify({k: job.get(k, "") for k in
                    ["id", "status", "progress", "speed", "eta", "filename", "error", "title", "filesize_str"]})


@flask_app.route("/api/jobs")
def api_jobs():
    with jobs_lock:
        snapshot = list(jobs.items())
    active = []
    for jid, job in sorted(snapshot, key=lambda x: x[1].get("created_at", 0), reverse=True):
        active.append({k: job.get(k, "") for k in
                       ["id", "status", "progress", "speed", "eta", "filename", "error", "title"]})
    return jsonify({"jobs": active[:50]})


@flask_app.route("/api/cancel/<jid>", methods=["POST"])
def api_cancel(jid):
    job = jobs.get(jid)
    if not job:
        return jsonify({"error": "Not found"}), 404
    pid = job.get("pid")
    if pid:
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
    job["status"] = "error"
    job["error"] = "Cancelled"
    return jsonify({"ok": True})


@flask_app.route("/api/reveal/<jid>", methods=["POST"])
def api_reveal(jid):
    job = jobs.get(jid)
    if not job or not job.get("filename"):
        return jsonify({"error": "No file"}), 404
    fp = job["filename"]
    dl_dir = PREFS.get("download_dir", str(DOWNLOAD_DIR))
    if not os.path.isabs(fp):
        fp = str(Path(dl_dir) / fp)
    subprocess.Popen(["open", "-R", fp] if os.path.exists(fp) else ["open", dl_dir])
    return jsonify({"ok": True})


@flask_app.route("/api/open-folder", methods=["POST"])
def api_open_folder():
    dl_dir = PREFS.get("download_dir", str(DOWNLOAD_DIR))
    subprocess.Popen(["open", dl_dir])
    return jsonify({"ok": True})


@flask_app.route("/api/history")
def api_history():
    return jsonify({"history": get_history()})


@flask_app.route("/api/history/clear", methods=["POST"])
def api_clear_history():
    clear_history()
    return jsonify({"ok": True})


@flask_app.route("/api/prefs", methods=["GET"])
def api_get_prefs():
    return jsonify(load_prefs())


@flask_app.route("/api/prefs", methods=["POST"])
def api_set_prefs():
    global PREFS, DOWNLOAD_DIR
    data = request.json
    current = load_prefs()
    current.update(data)
    save_prefs(current)
    PREFS = current
    DOWNLOAD_DIR = Path(current["download_dir"])
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    return jsonify({"ok": True})


@flask_app.route("/api/update-ytdlp", methods=["POST"])
def api_update_ytdlp():
    try:
        result = subprocess.run([YTDLP, "-U"], capture_output=True, text=True, timeout=60, env=ENHANCED_ENV)
        output = result.stdout + result.stderr
        if "is up to date" in output.lower():
            return jsonify({"message": "yt-dlp is already up to date."})
        elif result.returncode == 0:
            return jsonify({"message": "yt-dlp updated successfully."})
        else:
            return jsonify({"error": output.strip()}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Grabby</title>
<style>
:root{
  --bg:#0a0a0b;--surface:#141416;--surface-2:#1c1c20;--surface-3:#242429;
  --border:#2a2a30;--text:#e8e8ed;--text-dim:#9999b0;
  --accent:#ff5c39;--accent-glow:rgba(255,92,57,.15);--accent-2:#ff8c39;
  --green:#34d399;--green-glow:rgba(52,211,153,.15);
  --red:#ef4444;--radius:12px;--radius-sm:8px;
}
@media(prefers-color-scheme:light){
  :root.auto-theme{
    --bg:#f5f5f7;--surface:#ffffff;--surface-2:#f0f0f2;--surface-3:#e8e8ec;
    --border:#d1d1d6;--text:#1d1d1f;--text-dim:#555570;
    --accent:#e8430a;--accent-glow:rgba(232,67,10,.12);--accent-2:#d4650a;
    --green:#059669;--green-glow:rgba(5,150,105,.12);--red:#dc2626;
  }
}
:root.light{
  --bg:#f5f5f7;--surface:#ffffff;--surface-2:#f0f0f2;--surface-3:#e8e8ec;
  --border:#d1d1d6;--text:#1d1d1f;--text-dim:#555570;
  --accent:#e8430a;--accent-glow:rgba(232,67,10,.12);--accent-2:#d4650a;
  --green:#059669;--green-glow:rgba(5,150,105,.12);--red:#dc2626;
}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:40px 20px;-webkit-user-select:none;user-select:none;transition:background .3s,color .3s}
.titlebar{position:fixed;top:0;left:0;right:0;height:38px;-webkit-app-region:drag;z-index:1000}
.container{max-width:640px;width:100%;margin-top:10px}
.header{text-align:center;margin-bottom:32px;position:relative}
.logo{font-size:42px;font-weight:800;letter-spacing:-2px;background:linear-gradient(135deg,var(--accent),var(--accent-2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;margin-bottom:4px}
.tagline{font-size:14px;color:var(--text-dim);font-weight:300;letter-spacing:2px;text-transform:uppercase}
.header-actions{position:absolute;right:0;top:50%;transform:translateY(-50%);display:flex;gap:8px}
.icon-btn{background:var(--surface-2);border:1px solid var(--border);border-radius:var(--radius-sm);width:36px;height:36px;display:flex;align-items:center;justify-content:center;cursor:pointer;color:var(--text-dim);font-size:16px;transition:all .2s;-webkit-app-region:no-drag}
.icon-btn:hover{border-color:var(--accent);color:var(--text);background:var(--surface-3)}
.icon-btn.active{border-color:var(--accent);color:var(--accent)}

/* Navigation tabs */
.nav-tabs{display:flex;gap:4px;margin-bottom:20px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:4px}
.nav-tab{flex:1;padding:10px;text-align:center;font-size:13px;font-weight:600;color:var(--text-dim);cursor:pointer;border-radius:var(--radius-sm);transition:all .2s;border:none;background:none;-webkit-app-region:no-drag}
.nav-tab:hover{color:var(--text)}
.nav-tab.active{background:var(--surface-3);color:var(--text)}
.tab-content{display:none}.tab-content.active{display:block}

.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:28px;margin-bottom:16px;animation:fadeIn .3s ease}
@keyframes fadeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
.dep-warning{display:none;background:rgba(255,92,57,.08);border:1px solid rgba(255,92,57,.25);border-radius:var(--radius-sm);padding:16px;margin-bottom:20px;font-size:13px;line-height:1.6}
.dep-warning.show{display:block}
.dep-warning code{background:var(--bg);padding:2px 8px;border-radius:4px;font-family:'SF Mono',Menlo,monospace;font-size:12px;-webkit-user-select:text;user-select:text}
.dep-warning strong{color:var(--accent)}

/* Empty state */
.empty-state{text-align:center;padding:48px 20px;color:var(--text-dim)}
.empty-icon{font-size:56px;margin-bottom:16px;opacity:.3}
.empty-title{font-size:18px;font-weight:600;color:var(--text);margin-bottom:6px}
.empty-sub{font-size:14px;line-height:1.5}

.url-group{display:flex;gap:10px;margin-bottom:20px}
.url-input{flex:1;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);padding:14px 16px;font-size:15px;font-family:'SF Mono',Menlo,monospace;color:var(--text);outline:none;transition:border-color .2s,box-shadow .2s;-webkit-user-select:text;user-select:text}
.url-input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}
.url-input::placeholder{color:var(--text-dim);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif}
.btn-fetch{background:var(--surface-3);border:1px solid var(--border);border-radius:var(--radius-sm);padding:14px 20px;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;font-size:14px;font-weight:600;cursor:pointer;transition:all .2s;white-space:nowrap;-webkit-app-region:no-drag}
.btn-fetch:hover{background:var(--surface-2);border-color:var(--accent)}
.options-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:20px}
.option-group label{display:block;font-size:11px;text-transform:uppercase;letter-spacing:1.5px;color:var(--text-dim);margin-bottom:6px;font-weight:500}
.option-group select,.option-group input[type=text]{width:100%;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);padding:10px 12px;font-size:14px;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;color:var(--text);outline:none;cursor:pointer;appearance:none;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%238888a0' stroke-width='2'%3E%3Cpolyline points='6 9 12 15 18 9'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 12px center}
.option-group input[type=text]{background-image:none;cursor:text;-webkit-user-select:text;user-select:text}
.option-group select:focus,.option-group input[type=text]:focus{border-color:var(--accent)}
.toggle-row{display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-top:1px solid var(--border);margin-bottom:20px}
.toggle-label{font-size:14px;font-weight:500}
.toggle{position:relative;width:48px;height:26px;cursor:pointer}
.toggle input{opacity:0;width:0;height:0}
.toggle .slider{position:absolute;inset:0;background:var(--surface-3);border-radius:13px;transition:.3s;border:1px solid var(--border)}
.toggle .slider::before{content:'';position:absolute;width:20px;height:20px;left:2px;bottom:2px;background:var(--text-dim);border-radius:50%;transition:.3s}
.toggle input:checked+.slider{background:var(--accent);border-color:var(--accent)}
.toggle input:checked+.slider::before{transform:translateX(22px);background:#fff}
.btn-download{width:100%;padding:16px;border:none;border-radius:var(--radius-sm);font-size:16px;font-weight:700;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;cursor:pointer;transition:all .3s;background:linear-gradient(135deg,var(--accent),var(--accent-2));color:#fff;letter-spacing:.5px;-webkit-app-region:no-drag}
.btn-download:hover{transform:translateY(-1px);box-shadow:0 8px 30px var(--accent-glow)}
.btn-download:disabled{opacity:.4;cursor:not-allowed;transform:none;box-shadow:none}
.preview{display:none;margin-bottom:20px;background:var(--bg);border-radius:var(--radius-sm);overflow:hidden;border:1px solid var(--border);animation:fadeIn .3s ease}
.preview.show{display:block}
.preview-thumb{width:100%;height:180px;object-fit:cover;display:block}
.preview-info{padding:14px 16px}
.preview-title{font-weight:600;font-size:15px;margin-bottom:4px;line-height:1.3;-webkit-user-select:text;user-select:text}
.preview-meta{font-size:13px;color:var(--text-dim)}

/* Playlist UI */
.playlist-info{margin-bottom:20px;animation:fadeIn .3s ease}
.playlist-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}
.playlist-title{font-weight:600;font-size:16px}
.playlist-count{font-size:13px;color:var(--text-dim)}
.playlist-actions{display:flex;gap:8px}
.playlist-actions button{background:var(--surface-3);border:1px solid var(--border);border-radius:6px;padding:6px 12px;font-size:12px;font-weight:600;cursor:pointer;color:var(--text-dim);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;transition:all .2s;-webkit-app-region:no-drag}
.playlist-actions button:hover{border-color:var(--accent);color:var(--text)}
.playlist-list{max-height:300px;overflow-y:auto;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--bg)}
.playlist-list::-webkit-scrollbar{width:6px}
.playlist-list::-webkit-scrollbar-track{background:transparent}
.playlist-list::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
.playlist-item{display:flex;align-items:center;gap:10px;padding:10px 14px;border-bottom:1px solid var(--border);font-size:13px;cursor:pointer;transition:background .15s}
.playlist-item:last-child{border-bottom:none}
.playlist-item:hover{background:var(--surface-2)}
.playlist-item input[type=checkbox]{accent-color:var(--accent);cursor:pointer;width:16px;height:16px}
.playlist-item .track-num{color:var(--text-dim);font-family:'SF Mono',Menlo,monospace;font-size:12px;min-width:24px}
.playlist-item .track-title{flex:1;-webkit-user-select:text;user-select:text}
.playlist-item .track-dur{color:var(--text-dim);font-family:'SF Mono',Menlo,monospace;font-size:12px}

/* Progress / queue */
.progress-card{display:none;margin-bottom:12px}
.progress-card.show{display:block}
.progress-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
.progress-title{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:80%}
.progress-cancel{background:none;border:none;color:var(--text-dim);cursor:pointer;font-size:18px;min-width:36px;min-height:36px;padding:8px;display:flex;align-items:center;justify-content:center;transition:color .2s;-webkit-app-region:no-drag}
.progress-cancel:hover{color:var(--red)}
.progress-bar-track{width:100%;height:6px;background:var(--bg);border-radius:3px;overflow:hidden;margin-bottom:10px;position:relative}
.progress-bar-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-2));border-radius:3px;width:0%;transition:width .3s ease;position:relative}
@keyframes shimmer{0%{transform:translateX(-100%)}100%{transform:translateX(100%)}}
.progress-bar-fill::after{content:'';position:absolute;top:0;left:0;right:0;bottom:0;background:linear-gradient(90deg,transparent,rgba(255,255,255,.2),transparent);animation:shimmer 1.5s infinite}
.progress-bar-fill.done{background:var(--green)}.progress-bar-fill.done::after{display:none}
.progress-stats{display:flex;justify-content:space-between;font-size:12px;font-family:'SF Mono',Menlo,monospace;color:var(--text-dim)}
.done-card{display:none;text-align:center;padding:32px 28px}
.done-card.show{display:block}
.done-icon{font-size:48px;margin-bottom:12px;color:var(--green);animation:popIn .4s ease}
@keyframes popIn{0%{transform:scale(0);opacity:0}50%{transform:scale(1.2)}100%{transform:scale(1);opacity:1}}
.done-text{font-size:18px;font-weight:600;margin-bottom:6px}
.done-filename{font-size:13px;font-family:'SF Mono',Menlo,monospace;color:var(--text-dim);margin-bottom:20px;word-break:break-all;-webkit-user-select:text;user-select:text}
.btn-reveal,.btn-new{border-radius:var(--radius-sm);padding:12px 24px;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;font-size:14px;font-weight:600;cursor:pointer;transition:all .2s;margin:0 4px;-webkit-app-region:no-drag}
.btn-reveal{background:var(--surface-3);border:1px solid var(--border);color:var(--text)}
.btn-reveal:hover{border-color:var(--green);background:var(--green-glow)}
.btn-new{background:linear-gradient(135deg,var(--accent),var(--accent-2));border:none;color:#fff}
.error-msg{display:none;background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.3);border-radius:var(--radius-sm);padding:12px 16px;font-size:13px;color:var(--red);margin-bottom:16px;font-family:'SF Mono',Menlo,monospace;-webkit-user-select:text;user-select:text;animation:fadeIn .2s ease}
.error-msg.show{display:block}

/* History */
.history-list{list-style:none}
.history-item{display:flex;align-items:center;gap:12px;padding:14px 0;border-bottom:1px solid var(--border);animation:fadeIn .3s ease}
.history-item:last-child{border-bottom:none}
.history-thumb{width:80px;height:45px;border-radius:6px;object-fit:cover;background:var(--surface-3);flex-shrink:0}
.history-info{flex:1;min-width:0}
.history-title{font-size:14px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-bottom:2px;-webkit-user-select:text;user-select:text}
.history-meta{font-size:12px;color:var(--text-dim);display:flex;gap:8px}
.history-btn{background:none;border:none;color:var(--text-dim);cursor:pointer;font-size:14px;padding:4px 8px;transition:color .2s;-webkit-app-region:no-drag}
.history-btn:hover{color:var(--accent)}

/* Prefs */
.prefs-section{margin-bottom:24px}
.prefs-section h3{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--text-dim);margin-bottom:12px;font-weight:500}
.pref-row{display:flex;align-items:center;justify-content:space-between;padding:10px 0;border-bottom:1px solid var(--border)}
.pref-row:last-child{border-bottom:none}
.pref-label{font-size:14px;font-weight:500}
.pref-value select,.pref-value input[type=text]{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:8px 10px;font-size:13px;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;outline:none;min-width:160px}
.pref-value input[type=text]{-webkit-user-select:text;user-select:text}
.pref-value select{appearance:none;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%238888a0' stroke-width='2'%3E%3Cpolyline points='6 9 12 15 18 9'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center;padding-right:28px;cursor:pointer}
.btn-text{background:none;border:none;color:var(--accent);cursor:pointer;font-size:13px;font-weight:600;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;padding:6px 0;transition:opacity .2s;-webkit-app-region:no-drag}
.btn-text:hover{opacity:.8}

/* Drag overlay */
.drop-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:999;align-items:center;justify-content:center;flex-direction:column;gap:12px;pointer-events:none}
.drop-overlay.show{display:flex}
.drop-icon{font-size:64px;color:var(--accent);animation:pulse 1s ease infinite}
@keyframes pulse{0%,100%{transform:scale(1);opacity:.8}50%{transform:scale(1.1);opacity:1}}
.drop-text{font-size:20px;font-weight:600;color:#fff}

.footer{text-align:center;margin-top:24px;font-size:12px;color:var(--text-dim)}
.folder-link{cursor:pointer;transition:color .2s;color:var(--accent);-webkit-app-region:no-drag}
.folder-link:hover{color:var(--text)}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid var(--text-dim);border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite;vertical-align:middle;margin-right:6px}
@keyframes spin{to{transform:rotate(360deg)}}
.hidden{display:none!important}
.version{font-size:11px;color:var(--text-dim);margin-top:6px;opacity:0.5}

/* Queue mini cards */
.queue-section{margin-top:8px}
.queue-item{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);padding:14px 16px;margin-bottom:8px;animation:fadeIn .3s ease}
.queue-item-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}
.queue-item-title{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:75%}
.queue-item-status{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:1px}
.queue-item-status.downloading{color:var(--accent)}
.queue-item-status.done{color:var(--green)}
.queue-item-status.error{color:var(--red)}
.queue-item-status.queued{color:var(--text-dim)}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
.url-input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:0.01ms !important;animation-iteration-count:1 !important;transition-duration:0.01ms !important}}
</style>
</head>
<body>
<div class="titlebar"></div>
<div class="drop-overlay" id="dropOverlay">
  <div class="drop-icon">&#8615;</div>
  <div class="drop-text">Drop URL to download</div>
</div>
<div class="container">
  <div class="header">
    <div class="logo">Grabby</div>
    <div class="tagline">Grab what you need</div>
    <div class="header-actions">
      <button class="icon-btn" id="themeBtn" onclick="cycleTheme()" title="Toggle theme">&#9681;</button>
    </div>
  </div>

  <div class="nav-tabs" role="tablist">
    <button class="nav-tab active" role="tab" aria-selected="true" aria-controls="tab-download" onclick="switchTab('download')">Download</button>
    <button class="nav-tab" role="tab" aria-selected="false" aria-controls="tab-queue" onclick="switchTab('queue')">Queue</button>
    <button class="nav-tab" role="tab" aria-selected="false" aria-controls="tab-history" onclick="switchTab('history')">History</button>
    <button class="nav-tab" role="tab" aria-selected="false" aria-controls="tab-prefs" onclick="switchTab('prefs')">Settings</button>
  </div>

  <div class="dep-warning" id="depWarning">
    <strong>Missing dependencies.</strong> Open Terminal and run:<br><br>
    <code id="depCmd">brew install yt-dlp ffmpeg</code><br><br>
    Then relaunch Grabby.
  </div>

  <!-- DOWNLOAD TAB -->
  <div class="tab-content active" id="tab-download" role="tabpanel">
    <div class="card" id="mainCard">
      <div class="url-group">
        <input type="text" class="url-input" id="urlInput" placeholder="Paste a YouTube URL..." spellcheck="false" autocomplete="off">
        <button class="btn-fetch" id="fetchBtn" onclick="fetchInfo()">Preview</button>
      </div>
      <div class="error-msg" id="errorMsg" role="alert" aria-live="assertive"></div>
      <div class="preview" id="preview">
        <img class="preview-thumb" id="previewThumb" src="" alt="">
        <div class="preview-info">
          <div class="preview-title" id="previewTitle"></div>
          <div class="preview-meta" id="previewMeta"></div>
        </div>
      </div>
      <!-- Playlist -->
      <div class="playlist-info" id="playlistInfo" style="display:none">
        <div class="playlist-header">
          <div><span class="playlist-title" id="playlistTitle"></span> <span class="playlist-count" id="playlistCount"></span></div>
          <div class="playlist-actions">
            <button onclick="selectAllPlaylist(true)" aria-label="Select all tracks">All</button>
            <button onclick="selectAllPlaylist(false)" aria-label="Deselect all tracks">None</button>
          </div>
        </div>
        <div class="playlist-list" id="playlistList"></div>
      </div>
      <div id="optionsArea">
        <div class="options-grid">
          <div class="option-group"><label for="formatSelect">Format</label><select id="formatSelect" onchange="onFormatChange()">
            <optgroup label="Video">
              <option value="mp4">MP4</option>
              <option value="mkv">MKV</option>
              <option value="webm">WebM</option>
            </optgroup>
            <optgroup label="Audio Only">
              <option value="mp3">MP3</option>
              <option value="flac">FLAC</option>
              <option value="m4a">M4A</option>
              <option value="wav">WAV</option>
              <option value="opus">Opus</option>
            </optgroup>
          </select></div>
          <div class="option-group" id="qualityGroup"><label for="qualitySelect">Quality</label><select id="qualitySelect"><option value="best">Best Available</option><option value="1080">1080p</option><option value="720">720p</option><option value="480">480p</option><option value="360">360p</option></select></div>
        </div>
        <div class="options-grid" style="margin-bottom:0">
          <div class="option-group"><label for="cookieSelect">Cookies From</label><select id="cookieSelect"><option value="">None</option><option value="safari">Safari</option><option value="chrome">Chrome</option><option value="firefox">Firefox</option><option value="brave">Brave</option></select></div>
          <div></div>
        </div>
      </div>
      <button class="btn-download" id="downloadBtn" onclick="startDownload()">Download</button>
    </div>
    <div class="card progress-card" id="progressCard">
      <div class="progress-header">
        <div class="progress-title" id="progressTitle">Downloading...</div>
        <button class="progress-cancel" onclick="cancelCurrent()" title="Cancel" aria-label="Cancel download">&#215;</button>
      </div>
      <div class="progress-bar-track"><div class="progress-bar-fill" id="progressFill"></div></div>
      <div class="progress-stats" aria-live="polite"><span id="progressPct">0%</span><span id="progressSpeed">-</span><span id="progressEta">-</span></div>
    </div>
    <div class="card done-card" id="doneCard" role="status">
      <div class="done-icon">&#10003;</div>
      <div class="done-text">Download Complete</div>
      <div class="done-filename" id="doneFilename"></div>
      <button class="btn-reveal" onclick="revealFile()">Show in Finder</button>
      <button class="btn-new" onclick="resetUI()">New Download</button>
    </div>
  </div>

  <!-- QUEUE TAB -->
  <div class="tab-content" id="tab-queue" role="tabpanel">
    <div class="queue-section" id="queueList">
      <div class="empty-state" id="queueEmpty">
        <div class="empty-icon">&#9776;</div>
        <div class="empty-title">No active downloads</div>
        <div class="empty-sub">Start a download and it will appear here</div>
      </div>
    </div>
  </div>

  <!-- HISTORY TAB -->
  <div class="tab-content" id="tab-history" role="tabpanel">
    <div id="historyContent">
      <div class="empty-state" id="historyEmpty">
        <div class="empty-icon">&#128197;</div>
        <div class="empty-title">No downloads yet</div>
        <div class="empty-sub">Your download history will appear here</div>
      </div>
    </div>
  </div>

  <!-- SETTINGS TAB -->
  <div class="tab-content" id="tab-prefs" role="tabpanel">
    <div class="card">
      <div class="prefs-section">
        <h3>Defaults</h3>
        <div class="pref-row">
          <span class="pref-label">Video Format</span>
          <div class="pref-value"><select id="prefFormat"><option value="mp4">MP4</option><option value="mkv">MKV</option><option value="webm">WebM</option></select></div>
        </div>
        <div class="pref-row">
          <span class="pref-label">Quality</span>
          <div class="pref-value"><select id="prefQuality"><option value="best">Best</option><option value="1080">1080p</option><option value="720">720p</option><option value="480">480p</option></select></div>
        </div>
        <div class="pref-row">
          <span class="pref-label">Audio Format</span>
          <div class="pref-value"><select id="prefAudioFormat"><option value="mp3">MP3</option><option value="flac">FLAC</option><option value="wav">WAV</option><option value="opus">Opus</option><option value="m4a">M4A</option></select></div>
        </div>
        <div class="pref-row">
          <span class="pref-label">Cookie Browser</span>
          <div class="pref-value"><select id="prefCookie"><option value="">None</option><option value="safari">Safari</option><option value="chrome">Chrome</option><option value="firefox">Firefox</option><option value="brave">Brave</option></select></div>
        </div>
      </div>
      <div class="prefs-section">
        <h3>Storage</h3>
        <div class="pref-row">
          <span class="pref-label">Download Folder</span>
          <div class="pref-value"><input type="text" id="prefDownloadDir" style="min-width:200px"></div>
        </div>
      </div>
      <div class="prefs-section">
        <h3>Appearance</h3>
        <div class="pref-row">
          <span class="pref-label">Theme</span>
          <div class="pref-value"><select id="prefTheme"><option value="dark">Dark</option><option value="light">Light</option><option value="auto">System</option></select></div>
        </div>
      </div>
      <div class="prefs-section">
        <h3>Maintenance</h3>
        <div class="pref-row">
          <span class="pref-label">Update yt-dlp</span>
          <button class="btn-text" id="updateYtdlpBtn" onclick="updateYtdlp()">Check for Updates</button>
        </div>
        <div class="pref-row">
          <span class="pref-label">Clear History</span>
          <button class="btn-text" onclick="clearAllHistory()" style="color:var(--red)">Clear All</button>
        </div>
      </div>
      <button class="btn-download" onclick="savePrefs()" style="margin-top:8px">Save Settings</button>
    </div>
  </div>

  <div class="footer">
    <span class="folder-link" onclick="openFolder()">~/Downloads/Grabby</span> &middot; Powered by yt-dlp
    <div class="version" id="versionLabel">v2.0.0</div>
  </div>
</div>
<script>
let currentJobId=null,pollInterval=null,activeJobs=[],playlistData=null;
const $=id=>document.getElementById(id);
function esc(s){if(!s)return'';const d=document.createElement('div');d.textContent=String(s);return d.innerHTML}
function safeSrc(url){return url&&(url.startsWith('https://')||url.startsWith('http://'))?esc(url):''}
const showError=m=>{$('errorMsg').textContent=m;$('errorMsg').classList.add('show')};
const hideError=()=>$('errorMsg').classList.remove('show');

// --- Theme ---
function applyTheme(t){
  const r=document.documentElement;
  r.classList.remove('light','auto-theme');
  if(t==='light')r.classList.add('light');
  else if(t==='auto')r.classList.add('auto-theme');
}
function cycleTheme(){
  const themes=['dark','light','auto'];
  let cur=localStorage.getItem('grabby-theme')||'dark';
  let i=(themes.indexOf(cur)+1)%themes.length;
  localStorage.setItem('grabby-theme',themes[i]);
  applyTheme(themes[i]);
}
applyTheme(localStorage.getItem('grabby-theme')||'dark');

// --- Tabs ---
function switchTab(name){
  document.querySelectorAll('.nav-tab').forEach((t,i)=>{
    const isActive=t.textContent.toLowerCase()===name||(name==='download'&&i===0)||(name==='queue'&&i===1)||(name==='history'&&i===2)||(name==='prefs'&&i===3);
    t.classList.toggle('active',isActive);
    t.setAttribute('aria-selected',isActive?'true':'false');
  });
  document.querySelectorAll('.tab-content').forEach(t=>t.classList.remove('active'));
  const el=$('tab-'+name);
  if(el)el.classList.add('active');
  if(name==='history')loadHistory();
  if(name==='queue')refreshQueue();
  if(name==='prefs')loadPrefs();
}

// --- Prefs ---
async function loadPrefs(){
  try{
    const p=await(await fetch('/api/prefs')).json();
    $('prefFormat').value=p.format||'mp4';
    $('prefQuality').value=p.quality||'best';
    $('prefAudioFormat').value=p.audio_format||'mp3';
    $('prefCookie').value=p.cookie_browser||'';
    $('prefDownloadDir').value=p.download_dir||'';
    $('prefTheme').value=p.theme||'dark';
  }catch(e){}
}
async function savePrefs(){
  const p={
    format:$('prefFormat').value,
    quality:$('prefQuality').value,
    audio_format:$('prefAudioFormat').value,
    cookie_browser:$('prefCookie').value,
    download_dir:$('prefDownloadDir').value,
    theme:$('prefTheme').value,
  };
  await fetch('/api/prefs',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p)});
  // Apply theme
  localStorage.setItem('grabby-theme',p.theme);
  applyTheme(p.theme);
  // Apply defaults to main UI
  $('formatSelect').value=p.format;
  $('qualitySelect').value=p.quality;
  $('cookieSelect').value=p.cookie_browser;
  onFormatChange();
  // Flash confirmation
  const btn=event.target;btn.textContent='Saved!';setTimeout(()=>btn.textContent='Save Settings',1500);
}

// --- Audio toggle ---
const AUDIO_FMTS=['mp3','flac','m4a','wav','opus'];
function isAudioFormat(){return AUDIO_FMTS.includes($('formatSelect').value)}
function onFormatChange(){$('qualityGroup').classList.toggle('hidden',isAudioFormat())}
function getCB(){return $('cookieSelect').value}
function fD(s){if(!s)return'';const m=Math.floor(s/60),sec=s%60;return m+':'+String(sec).padStart(2,'0')}
function fV(n){return n>=1e6?(n/1e6).toFixed(1)+'M views':n>=1e3?(n/1e3).toFixed(1)+'K views':n?n+' views':''}
function fSize(b){if(!b)return'';if(b>=1e9)return(b/1e9).toFixed(1)+' GB';if(b>=1e6)return(b/1e6).toFixed(1)+' MB';if(b>=1e3)return(b/1e3).toFixed(0)+' KB';return b+' B'}

// --- Deps check ---
async function checkDeps(){
  try{
    const r=await(await fetch('/api/check-deps')).json();
    if(!r.ytdlp||!r.ffmpeg){
      const m=[];if(!r.ytdlp)m.push('yt-dlp');if(!r.ffmpeg)m.push('ffmpeg');
      $('depCmd').textContent='brew install '+m.join(' ');
      $('depWarning').classList.add('show');
    }
  }catch(e){}
}
checkDeps();

// --- Apply saved prefs to main UI on load ---
(async()=>{
  try{
    const p=await(await fetch('/api/prefs')).json();
    if(p.format)$('formatSelect').value=p.format;
    if(p.quality)$('qualitySelect').value=p.quality;
    if(p.cookie_browser)$('cookieSelect').value=p.cookie_browser;
    if(p.theme){localStorage.setItem('grabby-theme',p.theme);applyTheme(p.theme);}
    onFormatChange();
  }catch(e){}
})();

// --- Fetch info ---
async function fetchInfo(){
  hideError();
  const u=$('urlInput').value.trim();
  if(!u){showError('Paste a URL first');return}
  $('fetchBtn').innerHTML='<span class="spinner"></span>Fetching';
  $('fetchBtn').disabled=true;
  $('playlistInfo').style.display='none';
  $('preview').classList.remove('show');
  playlistData=null;
  try{
    const d=await(await fetch('/api/info',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({url:u,cookie_browser:getCB()})})).json();
    if(d.error){showError(d.error);return}
    if(d.is_playlist){
      playlistData=d;
      $('playlistTitle').textContent=d.title||'Playlist';
      $('playlistCount').textContent=d.count+' tracks';
      let html='';
      d.entries.forEach((e,i)=>{
        html+=`<div class="playlist-item" onclick="this.querySelector('input').click()">
          <input type="checkbox" checked data-url="${esc(e.url||e.id)}" data-title="${esc(e.title||'')}" onclick="event.stopPropagation()">
          <span class="track-num">${i+1}</span>
          <span class="track-title">${esc(e.title||'Track '+(i+1))}</span>
          <span class="track-dur">${fD(e.duration)}</span>
        </div>`;
      });
      $('playlistList').innerHTML=html;
      $('playlistInfo').style.display='block';
      $('downloadBtn').textContent='Download Selected';
    }else{
      $('previewThumb').src=d.thumbnail||'';$('previewThumb').alt=d.title||'Video thumbnail';
      $('previewTitle').textContent=d.title;
      const meta=[d.uploader,fD(d.duration),fV(d.view_count)];
      if(d.filesize)meta.push('~'+fSize(d.filesize));
      $('previewMeta').textContent=meta.filter(Boolean).join('  \u00b7  ');
      $('preview').classList.add('show');
      $('downloadBtn').textContent='Download';
    }
  }catch(e){showError('Failed: '+e.message)}
  finally{$('fetchBtn').innerHTML='Preview';$('fetchBtn').disabled=false}
}

// --- Playlist helpers ---
function selectAllPlaylist(checked){
  $('playlistList').querySelectorAll('input[type=checkbox]').forEach(cb=>cb.checked=checked);
}

// --- Download ---
async function startDownload(){
  hideError();
  const u=$('urlInput').value.trim();
  if(!u){showError('Paste a URL first');return}
  $('downloadBtn').disabled=true;
  $('downloadBtn').innerHTML='<span class="spinner"></span>Starting...';

  const fmt=$('formatSelect').value;
  const audioOnly=isAudioFormat();
  const opts={
    cookie_browser:getCB(),
    audio_only:audioOnly,
    format:audioOnly?'mp4':fmt,
    quality:$('qualitySelect').value,
    audio_format:audioOnly?fmt:'mp3',
  };

  try{
    if(playlistData){
      // Collect selected tracks
      const checks=$('playlistList').querySelectorAll('input[type=checkbox]:checked');
      const urls=Array.from(checks).map(cb=>({url:cb.dataset.url,title:cb.dataset.title}));
      if(!urls.length){showError('Select at least one track');$('downloadBtn').disabled=false;$('downloadBtn').textContent='Download Selected';return}
      const d=await(await fetch('/api/download-playlist',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({urls,...opts})})).json();
      if(d.error){showError(d.error);$('downloadBtn').disabled=false;$('downloadBtn').textContent='Download Selected';return}
      activeJobs=d.job_ids;
      switchTab('queue');
      startQueuePoll();
      $('downloadBtn').disabled=false;
      $('downloadBtn').textContent='Download Selected';
    }else{
      const d=await(await fetch('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({url:u,...opts,title:$('previewTitle')?.textContent||'',
          thumbnail:$('previewThumb')?.src||'',duration:0})})).json();
      if(d.error){showError(d.error);$('downloadBtn').disabled=false;$('downloadBtn').textContent='Download';return}
      currentJobId=d.job_id;
      activeJobs.push(d.job_id);
      $('progressCard').classList.add('show');
      $('progressFill').style.width='0%';
      $('progressFill').classList.remove('done');
      $('progressTitle').textContent=$('previewTitle')?.textContent||'Downloading...';
      pollInterval=setInterval(pollStatus,500);
    }
  }catch(e){showError('Failed: '+e.message);$('downloadBtn').disabled=false;$('downloadBtn').textContent='Download'}
}

async function pollStatus(){
  if(!currentJobId)return;
  try{
    const d=await(await fetch('/api/status/'+currentJobId)).json();
    $('progressFill').style.width=d.progress+'%';
    $('progressPct').textContent=d.progress.toFixed(1)+'%';
    $('progressSpeed').textContent=d.speed||'-';
    $('progressEta').textContent=d.eta?'ETA '+d.eta:'-';
    if(d.title)$('progressTitle').textContent=d.title;
    if(d.status==='done'){
      clearInterval(pollInterval);
      $('progressCard').classList.remove('show');
      $('doneCard').classList.add('show');
      $('mainCard').style.display='none';
      $('doneFilename').textContent=(d.filename||'').split('/').pop()||'File saved';
      $('progressFill').classList.add('done');
    }
    if(d.status==='error'){
      clearInterval(pollInterval);
      $('progressCard').classList.remove('show');
      showError(d.error||'Failed');
      $('downloadBtn').disabled=false;
      $('downloadBtn').textContent='Download';
    }
  }catch(e){}
}

async function cancelCurrent(){
  if(currentJobId){
    await fetch('/api/cancel/'+currentJobId,{method:'POST'});
    clearInterval(pollInterval);
    $('progressCard').classList.remove('show');
    $('downloadBtn').disabled=false;
    $('downloadBtn').textContent='Download';
    currentJobId=null;
  }
}

async function revealFile(){await fetch('/api/reveal/'+currentJobId,{method:'POST'})}
async function openFolder(){await fetch('/api/open-folder',{method:'POST'})}

function resetUI(){
  $('mainCard').style.display='';$('doneCard').classList.remove('show');
  $('progressCard').classList.remove('show');$('preview').classList.remove('show');
  $('playlistInfo').style.display='none';playlistData=null;
  $('urlInput').value='';$('downloadBtn').disabled=false;
  $('downloadBtn').textContent='Download';hideError();currentJobId=null;
}

// --- Queue ---
let queuePollInterval=null;
function startQueuePoll(){
  if(queuePollInterval)clearInterval(queuePollInterval);
  queuePollInterval=setInterval(refreshQueue,1000);
}
async function refreshQueue(){
  try{
    const d=await(await fetch('/api/jobs')).json();
    const jobs=d.jobs||[];
    if(!jobs.length){
      $('queueList').innerHTML='<div class="empty-state" id="queueEmpty"><div class="empty-icon">&#9776;</div><div class="empty-title">No active downloads</div><div class="empty-sub">Start a download and it will appear here</div></div>';
      if(queuePollInterval)clearInterval(queuePollInterval);
      return;
    }
    let html='';
    let anyActive=false;
    jobs.forEach(j=>{
      const sc=j.status==='done'?'done':j.status==='error'?'error':j.status==='downloading'?'downloading':'queued';
      if(sc==='downloading'||sc==='queued')anyActive=true;
      html+=`<div class="queue-item">
        <div class="queue-item-header">
          <div class="queue-item-title">${esc(j.title||j.id)}</div>
          <span class="queue-item-status ${sc}">${j.status}</span>
        </div>
        <div class="progress-bar-track"><div class="progress-bar-fill ${j.status==='done'?'done':''}" style="width:${j.progress||0}%"></div></div>
        <div class="progress-stats"><span>${(j.progress||0).toFixed(1)}%</span><span>${j.speed||''}</span><span>${j.eta?'ETA '+j.eta:j.status==='done'?'Complete':j.error||''}</span></div>
      </div>`;
    });
    $('queueList').innerHTML=html;
    if(!anyActive&&queuePollInterval)clearInterval(queuePollInterval);
  }catch(e){}
}

// --- History ---
async function loadHistory(){
  try{
    const d=await(await fetch('/api/history')).json();
    const items=d.history||[];
    if(!items.length){
      $('historyContent').innerHTML='<div class="empty-state"><div class="empty-icon">&#128197;</div><div class="empty-title">No downloads yet</div><div class="empty-sub">Your download history will appear here</div></div>';
      return;
    }
    let html='<div class="card"><ul class="history-list">';
    items.forEach(h=>{
      const date=h.downloaded_at?new Date(h.downloaded_at).toLocaleDateString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
      const size=h.filesize?fSize(h.filesize):'';
      html+=`<li class="history-item">
        ${h.thumbnail?`<img class="history-thumb" src="${safeSrc(h.thumbnail)}" alt="">`:'<div class="history-thumb"></div>'}
        <div class="history-info">
          <div class="history-title">${esc(h.title||'Unknown')}</div>
          <div class="history-meta"><span>${esc(date)}</span><span>${esc(h.format||'')}</span><span>${esc(size)}</span></div>
        </div>
      </li>`;
    });
    html+='</ul></div>';
    $('historyContent').innerHTML=html;
  }catch(e){}
}

async function clearAllHistory(){
  if(!confirm('Clear all download history?'))return;
  await fetch('/api/history/clear',{method:'POST'});
  loadHistory();
}

// --- Update yt-dlp ---
async function updateYtdlp(){
  $('updateYtdlpBtn').textContent='Checking...';
  try{
    const d=await(await fetch('/api/update-ytdlp',{method:'POST'})).json();
    $('updateYtdlpBtn').textContent=d.message||d.error||'Done';
    setTimeout(()=>$('updateYtdlpBtn').textContent='Check for Updates',3000);
  }catch(e){$('updateYtdlpBtn').textContent='Failed';setTimeout(()=>$('updateYtdlpBtn').textContent='Check for Updates',2000)}
}

// --- Drag and drop ---
let dragCounter=0;
document.addEventListener('dragenter',e=>{e.preventDefault();dragCounter++;$('dropOverlay').classList.add('show')});
document.addEventListener('dragleave',e=>{e.preventDefault();dragCounter--;if(dragCounter<=0){dragCounter=0;$('dropOverlay').classList.remove('show')}});
document.addEventListener('dragover',e=>e.preventDefault());
document.addEventListener('drop',e=>{
  e.preventDefault();dragCounter=0;$('dropOverlay').classList.remove('show');
  const text=e.dataTransfer.getData('text/plain')||e.dataTransfer.getData('text/uri-list')||'';
  if(text&&(text.includes('youtube.com')||text.includes('youtu.be'))){
    $('urlInput').value=text.trim();
    switchTab('download');
    fetchInfo();
  }
});

// --- Paste auto-fetch ---
$('urlInput').addEventListener('paste',()=>{
  setTimeout(()=>{const v=$('urlInput').value.trim();if(v&&(v.includes('youtube.com')||v.includes('youtu.be')))fetchInfo()},100);
});
$('urlInput').addEventListener('keydown',e=>{if(e.key==='Enter')fetchInfo()});

// --- Version ---
fetch('/api/version').then(r=>r.json()).then(d=>{$('versionLabel').textContent='v'+d.version}).catch(()=>{});

// --- Keyboard shortcuts ---
document.addEventListener('keydown',e=>{
  if(e.metaKey&&e.key==='v'&&document.activeElement!==$('urlInput')){$('urlInput').focus()}
  if(e.metaKey&&e.key==='n'){e.preventDefault();resetUI()}
  if(e.metaKey&&e.key===','){e.preventDefault();switchTab('prefs')}
});
</script>
</body>
</html>"""


# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

def start_flask(port):
    import logging
    log = logging.getLogger("werkzeug")
    log.setLevel(logging.ERROR)
    flask_app.run(host="127.0.0.1", port=port, debug=False, use_reloader=False)


def find_free_port(preferred=18811):
    import socket
    try:
        with socket.create_connection(("127.0.0.1", preferred), timeout=0.1):
            pass
    except (ConnectionRefusedError, OSError):
        return preferred
    # Preferred port in use, find a free one
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_flask(port, timeout=10):
    import socket
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return True
        except (ConnectionRefusedError, OSError):
            time.sleep(0.05)
    return False


def main():
    import webview
    port = find_free_port()
    threading.Thread(target=start_flask, args=(port,), daemon=True).start()
    wait_for_flask(port)
    webview.create_window(
        "Grabby", f"http://127.0.0.1:{port}",
        width=700, height=860, resizable=True,
        min_size=(520, 640), background_color="#0a0a0b",
    )
    webview.start(gui="cocoa", debug=False)


if __name__ == "__main__":
    main()
