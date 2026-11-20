#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
test_root="${TMPDIR:-/tmp}"
if [[ "$test_root" != /* || ! -d "$test_root" ]]; then
  echo "invalid test temporary directory: $test_root" >&2
  exit 2
fi
test_root="$(cd "$test_root" && pwd -P)"
if [[ "$test_root" == '/' ]]; then
  echo 'test temporary directory must not be the filesystem root' >&2
  exit 2
fi
tmp="$(mktemp -d "$test_root/landrop-package-test.XXXXXX")"
case "$tmp" in
  "$test_root"/landrop-package-test.*) ;;
  *) echo "unexpected test directory: $tmp" >&2; exit 2 ;;
esac
cleanup() {
  case "$tmp" in
    "$test_root"/landrop-package-test.*) rm -rf -- "$tmp" ;;
    *) echo "refusing to clean unexpected test directory: $tmp" >&2; return 2 ;;
  esac
}
trap cleanup EXIT

project="$tmp/project"
app="$project/build/macos/Build/Products/Release/LanDrop.app"
mkdir -p "$project/tool" "$app/Contents/MacOS" "$project/macos/Runner" \
  "$tmp/fakebin" "$tmp/verify"
cp "$repo_root/flutter_app/tool/package_macos.sh" "$project/tool/package_macos.sh"
cp "$repo_root/flutter_app/tool/verify_zip_paths.py" "$project/tool/verify_zip_paths.py"
write_info_plist() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>CFBundleExecutable</key>' \
    "<string>$1</string></dict></plist>" > "$app/Contents/Info.plist"
}
write_info_plist LanDrop
printf 'mock executable\n' > "$app/Contents/MacOS/LanDrop"
chmod +x "$app/Contents/MacOS/LanDrop"
printf 'mock entitlements\n' > "$project/macos/Runner/Release.entitlements"

cat > "$tmp/fakebin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CODESIGN_LOG"
if [[ "${1:-}" == '--verify' && "${MOCK_CODE_SIGN_MODE:-}" == 'extracted-signature-fail' && \
  "${4:-}" == *'/landrop-package-verify.'* ]]; then
  exit 1
fi
if [[ "${1:-}" == '-d' ]]; then
  permission='<true/>'
  target="${4:-}"
  if [[ "${MOCK_CODE_SIGN_MODE:-}" == 'source-no-permission' && \
    "$target" != *'/landrop-package-verify.'* ]]; then
    permission='<false/>'
  elif [[ "${MOCK_CODE_SIGN_MODE:-}" == 'extracted-no-permission' && \
    "$target" == *'/landrop-package-verify.'* ]]; then
    permission='<false/>'
  fi
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>com.apple.security.files.user-selected.read-only</key>' \
    "$permission</dict></plist>"
fi
SH
cat > "$tmp/fakebin/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DITTO_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$DITTO_LOG"
fi
if [[ "${1:-}" == '-c' ]]; then
  app="${5:?missing app source}"
  output="${6:?missing archive output}"
  if [[ "${MOCK_DITTO_MODE:-}" == 'bad' ]]; then
    printf 'not a ZIP archive\n' > "$output"
    exit 0
  fi
  if [[ "${MOCK_DITTO_MODE:-}" == 'unsafe' ]]; then
    python3 - "$output" <<'PY'
from zipfile import ZIP_STORED, ZipFile
import sys
with ZipFile(sys.argv[1], 'w', compression=ZIP_STORED) as archive:
    archive.writestr('LanDrop.app/Contents/Info.plist', b'plist')
    archive.writestr('LanDrop.app/Contents/MacOS/LanDrop', b'executable')
    archive.writestr('../escaped.txt', b'outside')
PY
    exit 0
  fi
  python3 - "$app" "$output" <<'PY'
from pathlib import Path
from zipfile import ZIP_STORED, ZipFile, ZipInfo
import os
import stat
import sys
app = Path(sys.argv[1])
with ZipFile(sys.argv[2], 'w', compression=ZIP_STORED) as archive:
    for path in app.rglob('*'):
        if path.is_file():
            relative = path.relative_to(app).as_posix()
            archive_name = f'LanDrop.app/{relative}'
            if os.environ.get('MOCK_DITTO_MODE') == 'metadata' and relative == 'Contents/Info.plist':
                info = ZipInfo(archive_name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, b'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Other</string></dict></plist>')
            elif os.environ.get('MOCK_DITTO_MODE') == 'nonexec' and relative == 'Contents/MacOS/LanDrop':
                info = ZipInfo(archive_name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, path.read_bytes())
            else:
                archive.write(path, archive_name)
PY
elif [[ "${1:-}" == '-x' ]]; then
  archive="${3:?missing archive input}"
  destination="${4:?missing extraction directory}"
  python3 - "$archive" "$destination" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import os
import stat
import sys
with ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
    for info in archive.infolist():
        mode = info.external_attr >> 16
        extracted = Path(sys.argv[2]) / info.filename
        if stat.S_IFMT(mode) == stat.S_IFREG and extracted.is_file() and not extracted.is_symlink():
            os.chmod(extracted, stat.S_IMODE(mode))
PY
else
  echo "unexpected ditto arguments: $*" >&2
  exit 2
fi
SH
chmod +x "$tmp/fakebin/codesign" "$tmp/fakebin/ditto"

assert_no_staging() {
  python3 - "$tmp" "$tmp/verify" <<'PY'
from pathlib import Path
import sys
roots = [Path(path) for path in sys.argv[1:]]
leftovers = [
    child
    for root in roots
    for pattern in ('.landrop-package.*', 'landrop-package-verify.*')
    for child in root.glob(pattern)
]
if leftovers:
    raise SystemExit(f'packaging staging directories leaked: {leftovers!r}')
PY
}

# Source metadata must name the main executable before signing starts.
write_info_plist Other
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/source-metadata-codesign.log" \
  bash "$project/tool/package_macos.sh" "$tmp/source-metadata-output.zip" \
  > "$tmp/source-metadata.log" 2>&1; then
  echo 'package script accepted a source bundle with mismatched executable metadata' >&2
  exit 1
fi
if [[ -e "$tmp/source-metadata-codesign.log" || -e "$tmp/source-metadata-output.zip" ]]; then
  echo 'source metadata failure occurred after signing or output creation' >&2
  exit 1
fi
write_info_plist LanDrop
assert_no_staging

# Keep the verification scratch root outside the source bundle being archived.
inside_app_tmp="$app/Contents/Resources/verify-root"
mkdir -p "$inside_app_tmp"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$inside_app_tmp" \
  CODESIGN_LOG="$tmp/inside-app-tmp-codesign.log" \
  bash "$project/tool/package_macos.sh" "$tmp/inside-app-tmp-output.zip" \
  > "$tmp/inside-app-tmp.log" 2>&1; then
  echo 'package script accepted a temporary directory inside the app bundle' >&2
  exit 1
fi
if [[ -e "$tmp/inside-app-tmp-codesign.log" || -e "$tmp/inside-app-tmp-output.zip" ]] || \
  ! grep -q 'temporary directory root must be outside the app bundle' "$tmp/inside-app-tmp.log"; then
  echo 'package script signed or created output for an in-bundle temporary directory' >&2
  exit 1
fi
rmdir "$inside_app_tmp"
assert_no_staging

# Extra arguments are rejected rather than silently ignored.
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/args-codesign.log" \
  bash "$project/tool/package_macos.sh" "$tmp/ignored-output.zip" "$tmp/unexpected-argument" \
  > "$tmp/args.log" 2>&1; then
  echo 'package script accepted extra command-line arguments' >&2
  exit 1
fi
if [[ -e "$tmp/args-codesign.log" || -e "$tmp/ignored-output.zip" ]]; then
  echo 'package script acted on output before rejecting extra arguments' >&2
  exit 1
fi
assert_no_staging

# A symlink output must be rejected before invoking any signing tools.
printf 'symlink sentinel\n' > "$tmp/symlink-target"
ln -s "$tmp/symlink-target" "$tmp/symlink-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/symlink-codesign.log" \
  bash "$project/tool/package_macos.sh" "$tmp/symlink-output.zip" \
  > "$tmp/symlink.log" 2>&1; then
  echo 'package script accepted a symlink output path' >&2
  exit 1
fi
if ! grep -qx 'symlink sentinel' "$tmp/symlink-target" || \
  [[ ! -L "$tmp/symlink-output.zip" || -e "$tmp/symlink-codesign.log" ]]; then
  echo 'package script followed the symlink or signed before rejecting it' >&2
  exit 1
fi
assert_no_staging

# A trailing slash must not turn a filename argument into a directory path.
trailing_output="$tmp/not-created/"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/trailing-codesign.log" \
  bash "$project/tool/package_macos.sh" "$trailing_output" > "$tmp/trailing.log" 2>&1; then
  echo 'package script accepted a trailing-slash output path' >&2
  exit 1
fi
if [[ -e "$tmp/not-created" || -e "$tmp/trailing-codesign.log" ]]; then
  echo 'package script created a directory or signed for a trailing-slash output path' >&2
  exit 1
fi
assert_no_staging

# A hard-linked destination is safely replaced without modifying its peer.
printf 'hardlink sentinel\n' > "$tmp/hardlink-target"
ln "$tmp/hardlink-target" "$tmp/hardlink-output.zip"
PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/hardlink-codesign.log" \
  bash "$project/tool/package_macos.sh" "$tmp/hardlink-output.zip" \
  > "$tmp/hardlink.log" 2>&1
if ! grep -qx 'hardlink sentinel' "$tmp/hardlink-target" || \
  [[ ! -f "$tmp/hardlink-output.zip" || -L "$tmp/hardlink-output.zip" || \
    "$tmp/hardlink-target" -ef "$tmp/hardlink-output.zip" ]]; then
  echo 'package script modified the target of a hard-linked output' >&2
  exit 1
fi
unzip -t "$tmp/hardlink-output.zip" >/dev/null
assert_no_staging

# A failed staged archive verification must leave the previous output intact.
printf 'previous verified archive\n' > "$tmp/preserved-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/failure-codesign.log" \
  MOCK_DITTO_MODE=bad bash "$project/tool/package_macos.sh" "$tmp/preserved-output.zip" \
  > "$tmp/failure.log" 2>&1; then
  echo 'package script accepted a corrupt staged archive' >&2
  exit 1
fi
if ! grep -qx 'previous verified archive' "$tmp/preserved-output.zip" || \
  [[ ! -f "$tmp/preserved-output.zip" || -L "$tmp/preserved-output.zip" ]]; then
  echo 'failed package verification replaced the prior output' >&2
  exit 1
fi
assert_no_staging

# A missing source entitlement must stop packaging before archive creation.
printf 'previous source-entitlement output\n' > "$tmp/source-entitlement-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/source-entitlement-codesign.log" \
  DITTO_LOG="$tmp/source-entitlement-ditto.log" MOCK_CODE_SIGN_MODE=source-no-permission \
  bash "$project/tool/package_macos.sh" "$tmp/source-entitlement-output.zip" \
  > "$tmp/source-entitlement.log" 2>&1; then
  echo 'package script accepted a missing source file-picker entitlement' >&2
  exit 1
fi
if ! grep -qx 'previous source-entitlement output' "$tmp/source-entitlement-output.zip" || \
  [[ ! -f "$tmp/source-entitlement-output.zip" || -L "$tmp/source-entitlement-output.zip" || \
    -e "$tmp/source-entitlement-ditto.log" ]]; then
  echo 'source entitlement failure modified output or began archive creation' >&2
  exit 1
fi
assert_no_staging

# A missing extracted entitlement must not commit the staged archive.
printf 'previous extracted-entitlement output\n' > "$tmp/extracted-entitlement-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/extracted-entitlement-codesign.log" \
  MOCK_CODE_SIGN_MODE=extracted-no-permission \
  bash "$project/tool/package_macos.sh" "$tmp/extracted-entitlement-output.zip" \
  > "$tmp/extracted-entitlement.log" 2>&1; then
  echo 'package script accepted a ZIP without the required file-picker entitlement' >&2
  exit 1
fi
if ! grep -qx 'previous extracted-entitlement output' "$tmp/extracted-entitlement-output.zip" || \
  [[ ! -f "$tmp/extracted-entitlement-output.zip" || -L "$tmp/extracted-entitlement-output.zip" ]]; then
  echo 'extracted entitlement failure replaced the prior output' >&2
  exit 1
fi
assert_no_staging

# Signature verification of the extracted bundle must gate the final rename.
printf 'previous signature-verified output\n' > "$tmp/signature-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/signature-codesign.log" \
  MOCK_CODE_SIGN_MODE=extracted-signature-fail \
  bash "$project/tool/package_macos.sh" "$tmp/signature-output.zip" \
  > "$tmp/signature.log" 2>&1; then
  echo 'package script accepted a ZIP with an invalid extracted app signature' >&2
  exit 1
fi
if ! grep -qx 'previous signature-verified output' "$tmp/signature-output.zip" || \
  [[ ! -f "$tmp/signature-output.zip" || -L "$tmp/signature-output.zip" ]]; then
  echo 'extracted signature failure replaced the prior output' >&2
  exit 1
fi
assert_no_staging

# A ZIP whose bundle metadata names another executable must not be committed.
printf 'previous bundle-metadata output\n' > "$tmp/bundle-metadata-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/bundle-metadata-codesign.log" \
  MOCK_DITTO_MODE=metadata bash "$project/tool/package_macos.sh" "$tmp/bundle-metadata-output.zip" \
  > "$tmp/bundle-metadata.log" 2>&1; then
  echo 'package script accepted mismatched extracted CFBundleExecutable metadata' >&2
  exit 1
fi
if ! grep -qx 'previous bundle-metadata output' "$tmp/bundle-metadata-output.zip" || \
  [[ ! -f "$tmp/bundle-metadata-output.zip" || -L "$tmp/bundle-metadata-output.zip" ]]; then
  echo 'bundle metadata failure replaced the prior output' >&2
  exit 1
fi
assert_no_staging

# Validate the staged ZIP before any extractor processes its member paths.
printf 'previous safe output\n' > "$tmp/unsafe-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/unsafe-codesign.log" \
  DITTO_LOG="$tmp/unsafe-ditto.log" MOCK_DITTO_MODE=unsafe \
  bash "$project/tool/package_macos.sh" "$tmp/unsafe-output.zip" \
  > "$tmp/unsafe.log" 2>&1; then
  echo 'package script accepted a ZIP with a path traversal entry' >&2
  exit 1
fi
if ! grep -qx 'previous safe output' "$tmp/unsafe-output.zip" || \
  [[ ! -f "$tmp/unsafe-output.zip" || -L "$tmp/unsafe-output.zip" ]] || \
  grep -q '^-x' "$tmp/unsafe-ditto.log" || [[ -e "$tmp/escaped.txt" ]]; then
  echo 'unsafe staged ZIP was extracted or replaced the previous output' >&2
  exit 1
fi
assert_no_staging

# Archive extraction must preserve the main executable bit before commit.
printf 'previous executable output\n' > "$tmp/nonexec-output.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/nonexec-codesign.log" \
  MOCK_DITTO_MODE=nonexec bash "$project/tool/package_macos.sh" "$tmp/nonexec-output.zip" \
  > "$tmp/nonexec.log" 2>&1; then
  echo 'package script accepted a staged app without an executable main binary' >&2
  exit 1
fi
if ! grep -qx 'previous executable output' "$tmp/nonexec-output.zip" || \
  [[ ! -f "$tmp/nonexec-output.zip" || -L "$tmp/nonexec-output.zip" ]]; then
  echo 'non-executable package replaced the previous output' >&2
  exit 1
fi
assert_no_staging

# Reject recursive outputs before mkdir can mutate the app bundle.
inside_app="$app/Contents/new/subdir/recursive.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/inside-codesign.log" \
  bash "$project/tool/package_macos.sh" "$inside_app" > "$tmp/inside.log" 2>&1; then
  echo 'package script accepted an output path inside the app bundle' >&2
  exit 1
fi
if [[ -e "$tmp/inside-codesign.log" || -e "$app/Contents/new" ]]; then
  echo 'package script mutated the app bundle before rejecting recursive output' >&2
  exit 1
fi

# Resolve symlinked output parents before creating any requested directories.
ln -s "$app/Contents" "$tmp/app-contents-link"
symlink_parent_output="$tmp/app-contents-link/symlink-created/deep/archive.zip"
if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/symlink-parent-codesign.log" \
  bash "$project/tool/package_macos.sh" "$symlink_parent_output" > "$tmp/symlink-parent.log" 2>&1; then
  echo 'package script accepted an output parent resolving inside the app bundle' >&2
  exit 1
fi
if [[ -e "$tmp/symlink-parent-codesign.log" || -e "$app/Contents/symlink-created" ]]; then
  echo 'package script followed a symlink into the app bundle before rejecting it' >&2
  exit 1
fi
assert_no_staging

# Case-insensitive filesystems must reject case-aliased bundle roots too.
casefolded_app="${app%LanDrop.app}landrop.app"
if [[ -d "$casefolded_app" ]]; then
  casefold_output="$casefolded_app/Contents/casefold-created/archive.zip"
  if PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/verify" CODESIGN_LOG="$tmp/casefold-codesign.log" \
    bash "$project/tool/package_macos.sh" "$casefold_output" > "$tmp/casefold.log" 2>&1; then
    echo 'package script accepted a case-aliased output path inside the app bundle' >&2
    exit 1
  fi
  if [[ -e "$tmp/casefold-codesign.log" || -e "$app/Contents/casefold-created" ]]; then
    echo 'package script mutated a case-aliased app path before rejecting it' >&2
    exit 1
  fi
  assert_no_staging
fi

echo 'macOS packaging path and atomic-output tests passed'
