#!/usr/bin/env bash
set -euo pipefail

if (($# < 1 || $# > 2)); then
  echo "usage: $0 <dist-directory> [verified-output-directory]" >&2
  exit 2
fi

tool_dir="$(cd "$(dirname "$0")" && pwd -P)"
dist_dir="$1"
verified_output_input="${2:-}"
if [[ ! -d "$dist_dir" ]]; then
  echo "release archive directory not found: $dist_dir" >&2
  exit 2
fi
dist_dir="$(cd "$dist_dir" && pwd -P)"
verified_dir=''
verified_parent=''
if [[ -n "$verified_output_input" ]]; then
  if [[ "$verified_output_input" == */ ]]; then
    echo "verified output directory must not end with a slash: $verified_output_input" >&2
    exit 2
  fi
  verified_name="$(basename "$verified_output_input")"
  verified_parent_input="$(dirname "$verified_output_input")"
  if [[ -z "$verified_name" || "$verified_name" == '.' || "$verified_name" == '..' || \
    ! -d "$verified_parent_input" ]]; then
    echo "invalid verified output directory: $verified_output_input" >&2
    exit 2
  fi
  verified_parent="$(cd "$verified_parent_input" && pwd -P)"
  verified_dir="$verified_parent/$verified_name"
  case "$verified_dir" in
    "$dist_dir"|"$dist_dir"/*)
      echo 'verified output directory must be outside the distribution directory' >&2
      exit 2
      ;;
  esac
  if [[ -e "$verified_dir" || -L "$verified_dir" ]]; then
    echo "verified output path already exists: $verified_dir" >&2
    exit 2
  fi
fi

(
  cd "$dist_dir"
  # Include hidden archives and ignore caller filters when enforcing the exact set.
  unset GLOBIGNORE
  shopt -s nullglob dotglob
  assert_expected_archive_set() {
    local -a current_archives=( *.[zZ][iI][pP] )
    if [[ ${#current_archives[@]} -ne 2 \
      || ! -f LanDrop-macOS.zip || -L LanDrop-macOS.zip || ! -s LanDrop-macOS.zip \
      || ! -f LanDrop-Windows.zip || -L LanDrop-Windows.zip || ! -s LanDrop-Windows.zip ]]; then
      echo 'expected exactly the macOS and Windows release archives' >&2
      return 1
    fi
  }
  assert_verified_output_directory() {
    local directory="$1"
    python3 - "$directory" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
expected = {"LanDrop-macOS.zip", "LanDrop-Windows.zip", "SHA256SUMS"}
try:
    if not stat.S_ISDIR(os.lstat(root).st_mode):
        raise ValueError("not a real directory")
    names = set(os.listdir(root))
    if names != expected:
        raise ValueError(f"unexpected top-level entries: {sorted(names)!r}")
    for name in expected:
        if not stat.S_ISREG(os.lstat(os.path.join(root, name)).st_mode):
            raise ValueError(f"verified output is not a regular file: {name}")
except (OSError, ValueError) as error:
    raise SystemExit(f"invalid verified output directory {root}: {error}")
PY
    if ! cmp -s "$manifest_tmp" "$directory/SHA256SUMS"; then
      echo "verified output manifest differs from validated snapshot hashes: $directory" >&2
      return 1
    fi
    (
      cd "$directory"
      assert_expected_archive_set
      sha256sum -c SHA256SUMS
    )
  }
  archives=( *.[zZ][iI][pP] )
  assert_expected_archive_set
  if [[ -L SHA256SUMS || ( -e SHA256SUMS && ! -f SHA256SUMS ) ]]; then
    echo 'checksum output path must not be a symlink or special file: SHA256SUMS' >&2
    exit 1
  fi

  snapshot_dir=''
  manifest_tmp=''
  verified_stage_dir=''
  verified_output_installed=0
  cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$manifest_tmp" ]]; then
      case "$manifest_tmp" in
        "$dist_dir"/.SHA256SUMS.*) rm -f -- "$manifest_tmp" || status=2 ;;
        *) echo "refusing to clean unexpected manifest temp: $manifest_tmp" >&2; status=2 ;;
      esac
    fi
    if [[ -n "$snapshot_dir" ]]; then
      case "$snapshot_dir" in
        "$dist_dir"/.landrop-release-snapshot.*) rm -rf -- "$snapshot_dir" || status=2 ;;
        *) echo "refusing to clean unexpected snapshot directory: $snapshot_dir" >&2; status=2 ;;
      esac
    fi
    if [[ -n "$verified_stage_dir" ]]; then
      case "$verified_stage_dir" in
        "$verified_parent"/.landrop-verified-release.*) rm -rf -- "$verified_stage_dir" || status=2 ;;
        *) echo "refusing to clean unexpected verified staging directory: $verified_stage_dir" >&2; status=2 ;;
      esac
    fi
    if ((status != 0 && verified_output_installed)); then
      case "$verified_dir" in
        "$verified_parent"/"$verified_name") rm -rf -- "$verified_dir" || status=2 ;;
        *) echo "refusing to clean unexpected verified output directory: $verified_dir" >&2; status=2 ;;
      esac
    fi
    exit "$status"
  }
  trap cleanup EXIT
  snapshot_dir="$(mktemp -d "$dist_dir/.landrop-release-snapshot.XXXXXX")"
  case "$snapshot_dir" in
    "$dist_dir"/.landrop-release-snapshot.*) ;;
    *) echo "unexpected snapshot directory: $snapshot_dir" >&2; exit 2 ;;
  esac
  python3 - "$dist_dir" "$snapshot_dir" "${archives[@]}" <<'PY'
import os
import stat
import sys

source_dir, snapshot_dir, *names = sys.argv[1:]
no_follow = getattr(os, "O_NOFOLLOW", None)
if no_follow is None:
    raise SystemExit("O_NOFOLLOW is required to snapshot release archives safely")
for name in names:
    if os.path.basename(name) != name:
        raise SystemExit(f"unsafe archive basename: {name!r}")
    source_fd = os.open(
        os.path.join(source_dir, name), os.O_RDONLY | os.O_NONBLOCK | no_follow
    )
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size == 0:
            raise SystemExit(f"release archive is not a non-empty regular file: {name}")
        target_fd = os.open(
            os.path.join(snapshot_dir, name),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            copied = 0
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(target_fd, view)
                    if written <= 0:
                        raise OSError("failed to write complete archive snapshot")
                    view = view[written:]
                copied += len(chunk)
            after = os.fstat(source_fd)
            before_identity = (
                before.st_dev, before.st_ino, before.st_size,
                before.st_mtime_ns, before.st_ctime_ns,
            )
            after_identity = (
                after.st_dev, after.st_ino, after.st_size,
                after.st_mtime_ns, after.st_ctime_ns,
            )
            if copied != before.st_size or before_identity != after_identity:
                raise SystemExit(f"release archive changed while snapshotting: {name}")
            os.fchmod(target_fd, stat.S_IMODE(before.st_mode) & 0o777)
            os.fsync(target_fd)
        finally:
            os.close(target_fd)
    finally:
        os.close(source_fd)
PY

  for archive in "${archives[@]}"; do
    snapshot="$snapshot_dir/$archive"
    if ! unzip -t "$snapshot" >/dev/null; then
      echo "invalid ZIP archive: $archive" >&2
      exit 1
    fi
    if [[ "$archive" == 'LanDrop-macOS.zip' ]]; then
      required_entries=(
        'LanDrop.app/Contents/Info.plist'
        'LanDrop.app/Contents/MacOS/LanDrop'
      )
      path_check_args=("$snapshot")
    else
      required_entries=(
        'landrop.exe'
        'flutter_windows.dll'
        'data/app.so'
        'data/icudtl.dat'
        'data/flutter_assets/AssetManifest.bin'
      )
      path_check_args=(
        --windows-target
        --require-pe-x64 'landrop.exe'
        --require-pe-x64 'flutter_windows.dll'
        --require-elf64-x64 'data/app.so'
        "$snapshot"
      )
    fi
    for entry in "${required_entries[@]}"; do
      path_check_args+=(--require-nonempty "$entry")
    done
    if ! python3 "$tool_dir/verify_zip_paths.py" "${path_check_args[@]}"; then
      echo "ZIP content verification failed: $archive" >&2
      exit 1
    fi
  done
  manifest_tmp="$(mktemp "$dist_dir/.SHA256SUMS.XXXXXX")"
  case "$manifest_tmp" in
    "$dist_dir"/.SHA256SUMS.*) ;;
    *) echo "unexpected checksum temporary file: $manifest_tmp" >&2; exit 2 ;;
  esac
  (
    cd "$snapshot_dir"
    sha256sum "${archives[@]}" > "$manifest_tmp"
    sha256sum -c "$manifest_tmp"
  )
  if [[ -n "$verified_dir" ]]; then
    verified_stage_dir="$(mktemp -d "$verified_parent/.landrop-verified-release.XXXXXX")"
    case "$verified_stage_dir" in
      "$verified_parent"/.landrop-verified-release.*) ;;
      *) echo "unexpected verified staging directory: $verified_stage_dir" >&2; exit 2 ;;
    esac
    for archive in "${archives[@]}"; do
      cp -p "$snapshot_dir/$archive" "$verified_stage_dir/$archive"
    done
    cp "$manifest_tmp" "$verified_stage_dir/SHA256SUMS"
    (
      cd "$verified_stage_dir"
      assert_expected_archive_set
      sha256sum -c SHA256SUMS
    )
    python3 - --install-verified-output "$verified_stage_dir" "$verified_dir" <<'PY'
import ctypes
import os
import sys

_, marker, source, destination = sys.argv
if marker != "--install-verified-output":
    raise SystemExit("invalid verified-output install request")
libc = ctypes.CDLL(None, use_errno=True)
if sys.platform.startswith("linux"):
    rename = getattr(libc, "renameat2", None)
    if rename is None:
        raise SystemExit("atomic no-replace directory rename is unavailable")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    result = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
elif sys.platform == "darwin":
    rename = getattr(libc, "renamex_np", None)
    if rename is None:
        raise SystemExit("atomic no-replace directory rename is unavailable")
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    result = rename(os.fsencode(source), os.fsencode(destination), 4)
else:
    raise SystemExit(f"atomic no-replace directory rename unsupported on {sys.platform}")
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), destination)
PY
    verified_stage_dir=''
    verified_output_installed=1
    assert_verified_output_directory "$verified_dir"
    echo "Verified release snapshots: $verified_dir"
  fi
  # Install exactly the validated snapshots before publishing their manifest.
  for archive in "${archives[@]}"; do
    mv -f -- "$snapshot_dir/$archive" "$dist_dir/$archive"
    if [[ ! -f "$dist_dir/$archive" || -L "$dist_dir/$archive" || ! -s "$dist_dir/$archive" ]]; then
      echo "verified archive was not installed as a regular file: $archive" >&2
      exit 1
    fi
  done
  assert_expected_archive_set
  sha256sum -c "$manifest_tmp"
  mv -f -- "$manifest_tmp" "$dist_dir/SHA256SUMS"
  sha256sum -c "$dist_dir/SHA256SUMS"
  assert_expected_archive_set
)
