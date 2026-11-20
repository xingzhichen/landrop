#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo_root/flutter_app/tool/publish_release.sh"
notes_12="$repo_root/RELEASE-1.2.md"
notes_13="$repo_root/RELEASE-1.3.md"
version_check="$repo_root/flutter_app/tool/verify_release_version.sh"
source "$repo_root/flutter_app/tool/release_tag.sh"
tmp_root="${TMPDIR:-/tmp}"
if [[ "$tmp_root" != /* || ! -d "$tmp_root" ]]; then
  echo "invalid temporary directory root: $tmp_root" >&2
  exit 2
fi
tmp_root="$(cd "$tmp_root" && pwd -P)"
if [[ "$tmp_root" == "/" ]]; then
  echo 'temporary directory root must not be the filesystem root' >&2
  exit 2
fi
tmp="$(mktemp -d "$tmp_root/landrop-publish-test.XXXXXX")"
case "$tmp" in
  "$tmp_root"/landrop-publish-test.*) ;;
  *) echo "unexpected temporary directory: $tmp" >&2; exit 2 ;;
esac
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/dist"
pubspec_version="$(awk '$1 == "version:" { print $2; exit }' "$repo_root/flutter_app/pubspec.yaml")"
pubspec_version="${pubspec_version#\"}"
pubspec_version="${pubspec_version%\"}"
pubspec_version="${pubspec_version#\'}"
pubspec_version="${pubspec_version%\'}"
app_version="${pubspec_version%%+*}"
app_stable_version="${app_version%%-*}"
IFS=. read -r app_major app_minor app_patch <<< "$app_stable_version"
for tag in "v$app_stable_version" "v$app_stable_version-rc1+build.1" 'v0.1.0+build-1'; do
  if ! release_tag_is_valid "$tag"; then
    echo "expected valid SemVer tag: $tag" >&2
    exit 1
  fi
done
for tag in 'v1.3.0+.-x' 'v01.3.0' 'v1.3.0-01' 'v1.3.0-rc..1' 'v1.3.0+build..1'; do
  if release_tag_is_valid "$tag"; then
    echo "expected invalid SemVer tag to be rejected: $tag" >&2
    exit 1
  fi
  if bash "$version_check" "$tag" >/dev/null 2>&1; then
    echo "version guard accepted invalid SemVer tag: $tag" >&2
    exit 1
  fi
done
bash "$version_check" "v$app_version" >/dev/null
bash "$version_check" "v$app_version+build.1" >/dev/null
if [[ "$app_version" == "$app_stable_version" ]] && \
  bash "$version_check" "v$app_stable_version-rc1+build.1" >/dev/null 2>&1; then
  echo 'stable app version must not pass a prerelease tag' >&2
  exit 1
fi
printf "name: prerelease-fixture\nversion: '%s-rc1+9'\n" \
  "$app_stable_version" > "$tmp/pubspec-prerelease.yaml"
bash "$version_check" "v$app_stable_version-rc1+build.1" \
  "$tmp/pubspec-prerelease.yaml" >/dev/null
if bash "$version_check" "v$app_stable_version-rc2" \
  "$tmp/pubspec-prerelease.yaml" >/dev/null 2>&1; then
  echo 'prerelease suffix mismatch should fail' >&2
  exit 1
fi
mismatch_tag="v${app_major}.${app_minor}.$((app_patch + 1))"
if bash "$version_check" "$mismatch_tag" >/dev/null 2>&1; then
  echo "expected mismatched release tag $mismatch_tag to fail" >&2
  exit 1
fi
if bash "$version_check" 'not-a-release' >/dev/null 2>&1; then
  echo 'expected malformed release tag to fail' >&2
  exit 1
fi
printf '%s\n' 'archive' > "$tmp/dist/LanDrop-macOS.zip"
printf '%s\n' 'archive' > "$tmp/dist/LanDrop-Windows.zip"
(
  cd "$tmp/dist"
  shasum -a 256 *.zip > SHA256SUMS
  shasum -a 256 -c SHA256SUMS >/dev/null
)

cat > "$tmp/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [[ "$1 $2" == 'release view' ]]; then
  [[ "${GH_RELEASE_EXISTS:-0}" == '1' ]]
fi
if [[ "$1 $2" == 'release upload' && -f "$GH_FAIL_UPLOAD_MARKER" ]]; then
  rm -- "$GH_FAIL_UPLOAD_MARKER"
  exit 1
fi
MOCK_GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export GH_CALL_LOG="$tmp/calls.log"
export GH_FAIL_UPLOAD_MARKER="$tmp/fail-upload-once"

touch "$GH_CALL_LOG"
read_calls() {
  CALLS=()
  local line
  while IFS= read -r line; do
    CALLS[${#CALLS[@]}]="$line"
  done < "$GH_CALL_LOG"
}

for tag in 'v1.3.0+.-x' 'v01.3.0' 'v1.3.0-01' 'v1.3.0-rc..1' 'v1.3.0+build..1'; do
  if GH_RELEASE_EXISTS=0 bash "$script" "$tag" \
    "$tmp/dist/LanDrop-macOS.zip" >/dev/null 2>&1; then
    echo "publisher accepted invalid SemVer tag: $tag" >&2
    exit 1
  fi
done
read_calls
[[ ${#CALLS[@]} -eq 0 ]]

GH_RELEASE_EXISTS=1 bash "$script" v1.3.0 \
  "$tmp/dist/LanDrop-macOS.zip" "$tmp/dist/LanDrop-Windows.zip" \
  "$tmp/dist/SHA256SUMS"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[0]}" == 'release view v1.3.0' ]]
[[ "${CALLS[1]}" == "release edit v1.3.0 --title LanDrop 1.3.0 --notes-file $notes_13 --prerelease=false" ]]
[[ "${CALLS[2]}" == "release upload v1.3.0 $tmp/dist/LanDrop-macOS.zip $tmp/dist/LanDrop-Windows.zip $tmp/dist/SHA256SUMS --clobber" ]]

: > "$GH_CALL_LOG"
GH_RELEASE_EXISTS=0 bash "$script" v1.3.1 \
  "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[0]}" == 'release view v1.3.1' ]]
[[ "${CALLS[1]}" == "release create v1.3.1 --verify-tag --title LanDrop 1.3.1 --notes-file $notes_13" ]]
[[ "${CALLS[2]}" == "release upload v1.3.1 $tmp/dist/LanDrop-macOS.zip --clobber" ]]

: > "$GH_CALL_LOG"
GH_RELEASE_EXISTS=0 bash "$script" v1.3.0+build-1 "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[1]}" == "release create v1.3.0+build-1 --verify-tag --title LanDrop 1.3.0+build-1 --notes-file $notes_13" ]]

: > "$GH_CALL_LOG"
GH_RELEASE_EXISTS=0 bash "$script" v1.2.0 "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[1]}" == "release create v1.2.0 --verify-tag --title LanDrop 1.2.0 --notes-file $notes_12" ]]

: > "$GH_CALL_LOG"
GH_RELEASE_EXISTS=0 bash "$script" v1.3.0-rc1 "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[1]}" == "release create v1.3.0-rc1 --verify-tag --title LanDrop 1.3.0-rc1 --notes-file $notes_13 --prerelease" ]]

: > "$GH_CALL_LOG"
GH_RELEASE_EXISTS=1 bash "$script" v1.3.0-rc2 "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 3 ]]
[[ "${CALLS[1]}" == "release edit v1.3.0-rc2 --title LanDrop 1.3.0-rc2 --notes-file $notes_13 --prerelease" ]]

: > "$GH_CALL_LOG"
if GH_RELEASE_EXISTS=0 bash "$script" v9.9.9 "$tmp/dist/LanDrop-macOS.zip"; then
  echo 'expected a missing release-notes file to fail before publishing' >&2
  exit 1
fi
read_calls
[[ ${#CALLS[@]} -eq 0 ]]

: > "$GH_CALL_LOG"
touch "$GH_FAIL_UPLOAD_MARKER"
if GH_RELEASE_EXISTS=1 bash "$script" v1.3.2 \
  "$tmp/dist/LanDrop-macOS.zip"; then
  echo 'expected first asset upload attempt to fail' >&2
  exit 1
fi
GH_RELEASE_EXISTS=1 bash "$script" v1.3.2 \
  "$tmp/dist/LanDrop-macOS.zip"
read_calls
[[ ${#CALLS[@]} -eq 6 ]]
[[ "${CALLS[0]}" == 'release view v1.3.2' ]]
[[ "${CALLS[1]}" == "release edit v1.3.2 --title LanDrop 1.3.2 --notes-file $notes_13 --prerelease=false" ]]
[[ "${CALLS[2]}" == "release upload v1.3.2 $tmp/dist/LanDrop-macOS.zip --clobber" ]]
[[ "${CALLS[3]}" == 'release view v1.3.2' ]]
[[ "${CALLS[4]}" == "release edit v1.3.2 --title LanDrop 1.3.2 --notes-file $notes_13 --prerelease=false" ]]
[[ "${CALLS[5]}" == "release upload v1.3.2 $tmp/dist/LanDrop-macOS.zip --clobber" ]]

echo 'release publishing retry checks passed'
