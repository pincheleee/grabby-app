#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="${TMPDIR:-/tmp}/grabby-ytdlp-tests"

xcrun swiftc \
  -o "$BIN_PATH" \
  "$ROOT_DIR/scripts/ytdlp_service_tests.swift" \
  "$ROOT_DIR/Grabby/Models/DownloadJob.swift" \
  "$ROOT_DIR/Grabby/Models/VideoInfo.swift" \
  "$ROOT_DIR/Grabby/Services/YTDLPService.swift"

"$BIN_PATH"
