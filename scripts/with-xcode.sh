#!/usr/bin/env bash
# Run a command with Xcode 27 as DEVELOPER_DIR.
# Prefers Xcode-beta when it is installed, otherwise Xcode.app.
set -euo pipefail

if [[ -n "${CHORUS_XCODE_DEVELOPER:-}" ]]; then
  DEVELOPER_DIR="$CHORUS_XCODE_DEVELOPER"
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
else
  echo "error: Xcode 27 developer directory not found." >&2
  echo "Install Xcode 27 or set CHORUS_XCODE_DEVELOPER." >&2
  exit 1
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: developer directory not found: $DEVELOPER_DIR" >&2
  exit 1
fi

export DEVELOPER_DIR
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

if [[ $# -eq 0 ]]; then
  echo "DEVELOPER_DIR=$DEVELOPER_DIR"
  xcodebuild -version
  swift --version
  exit 0
fi

exec "$@"
