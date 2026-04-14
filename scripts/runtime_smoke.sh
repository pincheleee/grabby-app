#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="${TMPDIR:-/tmp}/grabby-runtime-smoke"

xcrun swiftc \
  -o "$BIN_PATH" \
  "$ROOT_DIR/scripts/runtime_smoke.swift" \
  "$ROOT_DIR/Grabby/Models/DownloadJob.swift" \
  "$ROOT_DIR/Grabby/Models/VideoInfo.swift" \
  "$ROOT_DIR/Grabby/Services/YTDLPService.swift"

"$BIN_PATH" "$@"
