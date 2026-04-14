#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ITERATIONS="${1:-2}"
VIDEO_URL="${2:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"
PLAYLIST_URL="${3:-https://www.youtube.com/playlist?list=PL-jbbyKiQY-VlYYVIlIcio6tsFYNJ_OU3}"

for i in $(seq 1 "$ITERATIONS"); do
  echo "== Soak iteration $i/$ITERATIONS =="
  bash "$ROOT_DIR/scripts/run_tests.sh"
  bash "$ROOT_DIR/scripts/runtime_smoke.sh" "https://www.youtube.com/watch?v=jNQXAC9IVRw" chrome fetch
  bash "$ROOT_DIR/scripts/runtime_smoke.sh" "$VIDEO_URL" none download 1080
  bash "$ROOT_DIR/scripts/playlist_smoke.sh" "$PLAYLIST_URL" none fetch
done

echo "SOAK_OK iterations=$ITERATIONS"
