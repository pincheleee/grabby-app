#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="${1:-$ROOT_DIR/dist/Grabby.dmg}"

if [ ! -f "$DMG_PATH" ]; then
  echo "Package launch smoke failed: DMG not found at $DMG_PATH" >&2
  exit 1
fi

TMP_MOUNT="$(mktemp -d /tmp/grabby-dmg.XXXXXX)"
APP_COPY="/tmp/GrabbyManualTest-$(uuidgen).app"

cleanup() {
  osascript -e 'tell application id "com.grabby.app" to quit' >/dev/null 2>&1 || true
  if mount | grep -q "on $TMP_MOUNT "; then
    hdiutil detach "$TMP_MOUNT" >/dev/null 2>&1 || hdiutil detach "$TMP_MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_MOUNT"
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$TMP_MOUNT" >/dev/null
cp -R "$TMP_MOUNT/Grabby.app" "$APP_COPY"
hdiutil detach "$TMP_MOUNT" >/dev/null
rm -rf "$TMP_MOUNT"
TMP_MOUNT=""

open "$APP_COPY"
sleep 5

PIDS="$(pgrep -f "$APP_COPY/Contents/MacOS/Grabby" || true)"
if [ -z "$PIDS" ]; then
  echo "PACKAGED_LAUNCH_FAILED" >&2
  exit 1
fi

echo "PACKAGED_LAUNCH_PIDS $PIDS"
echo "MANUAL_APP_COPY $APP_COPY"
