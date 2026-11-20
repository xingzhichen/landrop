#!/bin/bash
# Run from flutter_app after `flutter build macos --release`.
set -euo pipefail
if (($# > 1)); then
  echo "usage: $0 [output-zip-path]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/build/macos/Build/Products/Release/LanDrop.app"
ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements"
OUTPUT="${1:-$ROOT/build/LanDrop-macOS.zip}"
if [[ "$OUTPUT" == */ ]]; then
  echo "ERROR: output archive path must name a file, not a directory: $OUTPUT" >&2
  exit 2
fi

if [[ ! -d "$APP" || -L "$APP" ]]; then
  echo "ERROR: built app bundle not found or is a symlink: $APP" >&2
  exit 2
fi
APP="$(cd "$APP" && pwd -P)"
verify_bundle_executable() {
  local app_bundle="$1"
  if ! python3 - "$app_bundle/Contents/Info.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as stream:
        metadata = plistlib.load(stream)
except Exception as error:
    print(f"invalid app Info.plist: {error}", file=sys.stderr)
    raise SystemExit(1)

executable = metadata.get("CFBundleExecutable")
if not isinstance(executable, str) or executable != "LanDrop":
    print(f"CFBundleExecutable must be 'LanDrop', got {executable!r}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    echo "ERROR: invalid executable metadata in app bundle: $app_bundle" >&2
    return 1
  fi
  local executable_path="$app_bundle/Contents/MacOS/LanDrop"
  if [[ ! -f "$executable_path" || -L "$executable_path" || ! -x "$executable_path" ]]; then
    echo "ERROR: app main executable must be a regular executable file: $executable_path" >&2
    return 1
  fi
}
verify_bundle_executable "$APP"
is_inside_app_bundle() {
  python3 - "$APP" "$1" <<'PY'
import os
import sys
import unicodedata

def normalized(path):
    return unicodedata.normalize("NFC", os.path.realpath(path)).casefold()

app = normalized(sys.argv[1])
candidate = normalized(sys.argv[2])
sys.exit(0 if candidate == app or candidate.startswith(app.rstrip(os.sep) + os.sep) else 1)
PY
}
OUTPUT_DIR_INPUT="$(dirname "$OUTPUT")"
OUTPUT_NAME="$(basename "$OUTPUT")"
if [[ -z "$OUTPUT_NAME" || "$OUTPUT_NAME" == '.' || "$OUTPUT_NAME" == '..' ]]; then
  echo "ERROR: invalid output archive path: $OUTPUT" >&2
  exit 2
fi
if is_inside_app_bundle "$OUTPUT"; then
  echo "ERROR: output archive must be outside the app bundle: $OUTPUT" >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR_INPUT"
OUTPUT_DIR="$(cd "$OUTPUT_DIR_INPUT" && pwd -P)"
if [[ "$OUTPUT_DIR" == '/' ]]; then
  echo 'ERROR: output archive directory must not be the filesystem root' >&2
  exit 2
fi
OUTPUT="$OUTPUT_DIR/$OUTPUT_NAME"
if [[ -L "$OUTPUT" || ( -e "$OUTPUT" && ! -f "$OUTPUT" ) ]]; then
  echo "ERROR: output path must not be a symlink or special file: $OUTPUT" >&2
  exit 2
fi
if is_inside_app_bundle "$OUTPUT"; then
  echo "ERROR: output archive must be outside the app bundle: $OUTPUT" >&2
  exit 2
fi

VERIFY_ROOT="${TMPDIR:-/tmp}"
if [[ "$VERIFY_ROOT" != /* || ! -d "$VERIFY_ROOT" ]]; then
  echo "ERROR: invalid temporary directory root: $VERIFY_ROOT" >&2
  exit 2
fi
VERIFY_ROOT="$(cd "$VERIFY_ROOT" && pwd -P)"
if [[ "$VERIFY_ROOT" == '/' ]]; then
  echo 'ERROR: temporary directory root must not be the filesystem root' >&2
  exit 2
fi
if is_inside_app_bundle "$VERIFY_ROOT"; then
  echo "ERROR: temporary directory root must be outside the app bundle: $VERIFY_ROOT" >&2
  exit 2
fi

PACKAGE_TMP_DIR=''
VERIFY_DIR=''
cleanup() {
  if [[ -n "$PACKAGE_TMP_DIR" ]]; then
    case "$PACKAGE_TMP_DIR" in
      "$OUTPUT_DIR"/.landrop-package.*) rm -rf -- "$PACKAGE_TMP_DIR" ;;
      *) echo "ERROR: unexpected package staging directory: $PACKAGE_TMP_DIR" >&2; return 2 ;;
    esac
  fi
  if [[ -n "$VERIFY_DIR" ]]; then
    case "$VERIFY_DIR" in
      "$VERIFY_ROOT"/landrop-package-verify.*) rm -rf -- "$VERIFY_DIR" ;;
      *) echo "ERROR: unexpected verification directory: $VERIFY_DIR" >&2; return 2 ;;
    esac
  fi
}
trap cleanup EXIT
PACKAGE_TMP_DIR="$(mktemp -d "$OUTPUT_DIR/.landrop-package.XXXXXX")"
case "$PACKAGE_TMP_DIR" in
  "$OUTPUT_DIR"/.landrop-package.*) ;;
  *) echo "ERROR: unexpected package staging directory: $PACKAGE_TMP_DIR" >&2; exit 2 ;;
esac
VERIFY_DIR="$(mktemp -d "$VERIFY_ROOT/landrop-package-verify.XXXXXX")"
case "$VERIFY_DIR" in
  "$VERIFY_ROOT"/landrop-package-verify.*) ;;
  *) echo "ERROR: unexpected temporary directory: $VERIFY_DIR" >&2; exit 2 ;;
esac
PACKAGE_OUTPUT="$PACKAGE_TMP_DIR/LanDrop-macOS.zip"

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

# Build and verify in private staging locations. Only replace the destination
# after the extracted bundle proves its signature and entitlements survived.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PACKAGE_OUTPUT"
python3 "$ROOT/tool/verify_zip_paths.py" \
  --require-nonempty 'LanDrop.app/Contents/Info.plist' \
  --require-nonempty 'LanDrop.app/Contents/MacOS/LanDrop' \
  "$PACKAGE_OUTPUT"
ditto -x -k "$PACKAGE_OUTPUT" "$VERIFY_DIR"
PACKAGED_APP="$VERIFY_DIR/LanDrop.app"
verify_bundle_executable "$PACKAGED_APP"
codesign --verify --deep --strict "$PACKAGED_APP"
PACKAGED_ENTITLEMENTS="$(codesign -d --entitlements :- "$PACKAGED_APP" 2>/dev/null)"
PACKAGED_READ_PERMISSION="$(printf '%s' "$PACKAGED_ENTITLEMENTS" | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.files.user-selected.read-only") is True)')"
if [[ "$PACKAGED_READ_PERMISSION" != "True" ]]; then
  echo 'ERROR: ZIP extraction lost the user-selected file read permission' >&2
  exit 1
fi
mv -f "$PACKAGE_OUTPUT" "$OUTPUT"
if [[ ! -f "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "ERROR: verified archive was not installed as a regular file: $OUTPUT" >&2
  exit 1
fi
echo "Packaged $OUTPUT (extracted signature and file picker permission verified)"
