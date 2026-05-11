#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/OS1.app}"
MANIFEST_PATH="${OS1_RELEASE_MANIFEST:-$ROOT_DIR/dist/release-manifest.json}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found at $APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    echo "ERROR: missing Info.plist" >&2
    exit 1
fi

if [[ ! -x "$APP_PATH/Contents/MacOS/OS1" ]]; then
    echo "ERROR: missing executable" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

signature="$(codesign -dv "$APP_PATH" 2>&1 || true)"
if echo "$signature" | grep -q "Signature=adhoc"; then
    echo "ERROR: release bundle is ad-hoc signed; Developer ID is required" >&2
    exit 1
fi

if ! spctl --assess --type execute --verbose "$APP_PATH" >/tmp/os1-spctl.log 2>&1; then
    cat /tmp/os1-spctl.log >&2
    echo "ERROR: Gatekeeper assessment failed" >&2
    exit 1
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "ERROR: missing release manifest at $MANIFEST_PATH" >&2
    exit 1
fi

python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
required = ["version", "build", "channel", "downloadURL", "sha256", "notarized"]
missing = [key for key in required if key not in manifest]
if missing:
    raise SystemExit(f"ERROR: manifest missing keys: {', '.join(missing)}")
if len(str(manifest["sha256"])) != 64:
    raise SystemExit("ERROR: manifest sha256 must be a 64-character hex digest")
if manifest["notarized"] is not True:
    raise SystemExit("ERROR: manifest must mark release notarized")
PY

echo "Release smoke passed: $APP_PATH"
