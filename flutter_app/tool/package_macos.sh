#!/bin/bash
# Run from flutter_app after `flutter build macos --release`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/macos/Build/Products/Release/LanDrop.app"
ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements"
OUTPUT="${1:-$ROOT/build/LanDrop-macOS.zip}"

# Sign nested frameworks first without applying application-only entitlements.
# Re-sign the outer app explicitly: a plain --force --deep signing command can
# discard the permissions required by file_picker despite a successful build.
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
READ_PERMISSION="$(printf '%s' "$SIGNED_ENTITLEMENTS" | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.files.user-selected.read-only") is True)')"
if [[ "$READ_PERMISSION" != "True" ]]; then
  echo 'ERROR: packaged app lost the user-selected file read permission' >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT"
echo "Packaged $OUTPUT (file picker permission verified)"
