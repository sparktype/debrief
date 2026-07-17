#!/usr/bin/env bash
# Run a command with Xcode 27 beta as DEVELOPER_DIR.
set -euo pipefail

XCODE_BETA="${CHORUS_XCODE_DEVELOPER:-/Applications/Xcode-beta.app/Contents/Developer}"

if [[ ! -d "$XCODE_BETA" ]]; then
  echo "error: Xcode beta developer directory not found: $XCODE_BETA" >&2
  echo "Install Xcode 27 beta or set CHORUS_XCODE_DEVELOPER." >&2
  exit 1
fi

export DEVELOPER_DIR="$XCODE_BETA"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

if [[ $# -eq 0 ]]; then
  echo "DEVELOPER_DIR=$DEVELOPER_DIR"
  xcodebuild -version
  swift --version
  exit 0
fi

exec "$@"
