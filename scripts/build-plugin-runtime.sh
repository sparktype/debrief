#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/plugins/chorus/runtime"
mkdir -p "$DEST/hook_voice" "$DEST/tts_server" "$DEST/assets"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' "$ROOT/hook_voice/" "$DEST/hook_voice/"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' --exclude 'test_*.py' "$ROOT/tts_server/" "$DEST/tts_server/"
rsync -a --delete "$ROOT/assets/" "$DEST/assets/"
cp "$ROOT/classify-rules.json" "$ROOT/voice-map.json" "$DEST/"
