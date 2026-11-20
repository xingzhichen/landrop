#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
verify_script="$repo_root/flutter_app/tool/verify_release_archives.sh"
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
tmp="$(mktemp -d "$tmp_root/landrop-release-archives.XXXXXX")"
case "$tmp" in
  "$tmp_root"/landrop-release-archives.*) ;;
  *) echo "unexpected temporary directory: $tmp" >&2; exit 2 ;;
esac
trap 'case "$tmp" in "$tmp_root"/landrop-release-archives.*) rm -rf -- "$tmp";; *) exit 2;; esac' EXIT

python3 - "$tmp" <<'PY'
import pathlib
import stat
import struct
import sys
import warnings
import zipfile

root = pathlib.Path(sys.argv[1])

def pe_fixture(
    offset=0x80,
    signature=b'PE\x00\x00',
    machine=0x8664,
    optional_magic=0x020B,
    section_count=1,
    optional_size=240,
    characteristics=0x0002,
    directory_count=0,
    section_alignment=0x1000,
    file_alignment=0x200,
    size_of_image=0x2000,
    size_of_headers=0x200,
    raw_offset=0x200,
    raw_size=0x200,
    data_size=0x400,
):
    data = bytearray(0x400)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, offset)
    if offset == 0x80:
        data[0x80:0x84] = signature
        struct.pack_into(
            '<HHIIIHH', data, 0x84, machine, section_count, 0, 0, 0,
            optional_size, characteristics,
        )
        optional = bytearray(optional_size)
        if optional_size >= 2:
            struct.pack_into('<H', optional, 0, optional_magic)
        if optional_size >= 64:
            struct.pack_into('<I', optional, 32, section_alignment)
            struct.pack_into('<I', optional, 36, file_alignment)
            struct.pack_into('<I', optional, 56, size_of_image)
            struct.pack_into('<I', optional, 60, size_of_headers)
        if optional_size >= 112:
            struct.pack_into('<I', optional, 108, directory_count)
        data[0x98:0x98 + optional_size] = optional
        section_offset = 0x98 + optional_size
        if section_offset + 40 <= len(data):
            section = bytearray(40)
            section[:8] = b'.text\0\0\0'
            struct.pack_into('<IIII', section, 8, 8, 0x1000, raw_size, raw_offset)
            struct.pack_into('<I', section, 36, 0x60000020)
            data[section_offset:section_offset + 40] = section
        if raw_offset + raw_size <= len(data):
            data[raw_offset:raw_offset + raw_size] = bytes(raw_size)
    return bytes(data[:data_size])


def minimal_pe():
    return pe_fixture()


def elf_fixture(
    elf_class=2,
    machine=0x003E,
    magic=b'\x7fELF',
    elf_type=3,
    version=1,
    header_size=64,
    data_size=128,
    program_offset=64,
    program_entry_size=56,
    program_count=1,
    segment_offset=120,
    segment_file_size=8,
    segment_memory_size=8,
    segment_type=1,
):
    data = bytearray(128)
    data[:4] = magic
    data[4] = elf_class
    data[5] = 1
    data[6] = 1
    struct.pack_into('<H', data, 16, elf_type)
    struct.pack_into('<H', data, 18, machine)
    struct.pack_into('<I', data, 20, version)
    struct.pack_into('<Q', data, 32, program_offset)
    struct.pack_into('<H', data, 52, header_size)
    struct.pack_into('<H', data, 54, program_entry_size)
    struct.pack_into('<H', data, 56, program_count)
    struct.pack_into(
        '<IIQQQQQQ', data, 64, segment_type, 5, segment_offset, 0, 0,
        segment_file_size, segment_memory_size, 8,
    )
    if segment_offset + segment_file_size <= len(data):
        data[segment_offset:segment_offset + segment_file_size] = b'payload!'[:segment_file_size]
    return bytes(data[:data_size])


def make_zip(directory, name, contents=b'release payload', include_executable=True, omit_entry=None):
    path = root / directory / name
    path.parent.mkdir(parents=True, exist_ok=True)
    compression = zipfile.ZIP_DEFLATED if name == 'LanDrop-Windows.zip' else zipfile.ZIP_STORED
    with zipfile.ZipFile(path, 'w', compression=compression) as archive:
        if not include_executable:
            entries = ['payload.txt']
        elif name == 'LanDrop-macOS.zip':
            entries = [
                'LanDrop.app/Contents/Info.plist',
                'LanDrop.app/Contents/MacOS/LanDrop',
            ]
        elif name == 'LanDrop-Windows.zip':
            entries = [
                'landrop.exe',
                'flutter_windows.dll',
                'data/app.so',
                'data/icudtl.dat',
                'data/flutter_assets/AssetManifest.bin',
            ]
        else:
            entries = ['payload.txt']
        if omit_entry is not None:
            entries.remove(omit_entry)
        for entry in entries:
            payload = contents
            if name == 'LanDrop-Windows.zip' and entry in ('landrop.exe', 'flutter_windows.dll'):
                if not contents:
                    payload = b''
                elif directory == 'wrong-pe':
                    payload = b'not a PE image'
                elif directory == 'bad-pe-offset' and entry == 'landrop.exe':
                    payload = pe_fixture(offset=0x100001)
                elif directory == 'bad-pe-signature' and entry == 'flutter_windows.dll':
                    payload = pe_fixture(signature=b'NOPE')
                elif directory == 'wrong-pe-machine-exe' and entry == 'landrop.exe':
                    payload = pe_fixture(machine=0x014C)
                elif directory == 'wrong-pe-machine-dll' and entry == 'flutter_windows.dll':
                    payload = pe_fixture(machine=0x014C)
                elif directory == 'truncated-pe-image' and entry == 'landrop.exe':
                    payload = pe_fixture(data_size=0x8A)
                elif directory == 'wrong-pe-optional-magic' and entry == 'landrop.exe':
                    payload = pe_fixture(optional_magic=0x010B)
                elif directory == 'no-pe-sections' and entry == 'landrop.exe':
                    payload = pe_fixture(section_count=0)
                elif directory == 'bad-pe-section-range' and entry == 'flutter_windows.dll':
                    payload = pe_fixture(raw_offset=0x100000)
                elif directory == 'zero-pe-image-size' and entry == 'landrop.exe':
                    payload = pe_fixture(size_of_image=0)
                elif directory == 'zero-pe-headers-size' and entry == 'flutter_windows.dll':
                    payload = pe_fixture(size_of_headers=0)
                elif directory == 'bad-pe-image-size' and entry == 'landrop.exe':
                    payload = pe_fixture(size_of_image=0x1000)
                elif directory == 'bad-pe-headers-size' and entry == 'flutter_windows.dll':
                    payload = pe_fixture(size_of_headers=0x100)
                elif directory == 'bad-pe-alignment' and entry == 'landrop.exe':
                    payload = pe_fixture(
                        file_alignment=3, size_of_headers=510, raw_offset=510,
                        raw_size=3, data_size=513,
                    )
                else:
                    payload = minimal_pe()
            elif name == 'LanDrop-Windows.zip' and entry == 'data/app.so':
                if not contents:
                    payload = b''
                elif directory == 'wrong-elf':
                    payload = b'not an ELF image'
                elif directory == 'wrong-elf-class':
                    payload = elf_fixture(elf_class=1)
                elif directory == 'wrong-elf-machine':
                    payload = elf_fixture(machine=0x00B7)
                elif directory == 'truncated-elf-header':
                    payload = elf_fixture(data_size=20)
                elif directory == 'wrong-elf-version':
                    payload = elf_fixture(version=0)
                elif directory == 'wrong-elf-header-size':
                    payload = elf_fixture(header_size=52)
                elif directory == 'wrong-elf-type':
                    payload = elf_fixture(elf_type=1)
                elif directory == 'bad-elf-program-offset':
                    payload = elf_fixture(program_offset=0x100001)
                elif directory == 'bad-elf-program-entry-size':
                    payload = elf_fixture(program_entry_size=32)
                elif directory == 'bad-elf-load-range':
                    payload = elf_fixture(segment_offset=0x1000)
                elif directory == 'no-elf-load-segment':
                    payload = elf_fixture(segment_type=4)
                elif directory == 'zero-sized-load-segment':
                    payload = elf_fixture(segment_file_size=0, segment_memory_size=0)
                else:
                    payload = elf_fixture()
            archive.writestr(entry, payload)
    return path


def add_symlink(archive, name, target):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, target.encode('utf-8'))


omitted_entries = {
    'missing-macos-info': 'LanDrop.app/Contents/Info.plist',
    'missing-macos-executable': 'LanDrop.app/Contents/MacOS/LanDrop',
    'missing-windows-executable': 'landrop.exe',
    'missing-windows-flutter': 'flutter_windows.dll',
    'missing-windows-aot': 'data/app.so',
    'missing-windows-icu': 'data/icudtl.dat',
    'missing-windows-assets': 'data/flutter_assets/AssetManifest.bin',
    'required-windows-symlink': 'landrop.exe',
}
base_cases = (
    'valid', 'missing', 'extra', 'extra-uppercase', 'extra-mixedcase',
    'extra-hidden', 'symlink', 'duplicate-path', 'casefold-alias',
    'separator-alias', 'traversal-forward',
    'traversal-backslash', 'absolute-path', 'drive-path', 'symlink-escape',
    'symlink-absolute', 'symlink-drive', 'special-file',
    'trailing-dot-alias', 'trailing-space-alias',
    'com-superscript-device', 'lpt-superscript-device', 'wrong-pe',
    'bad-pe-offset', 'bad-pe-signature', 'truncated-pe-image',
    'wrong-pe-optional-magic', 'no-pe-sections', 'bad-pe-section-range',
    'zero-pe-image-size', 'zero-pe-headers-size', 'bad-pe-image-size', 'bad-pe-headers-size',
    'bad-pe-alignment',
    'wrong-pe-machine-exe', 'wrong-pe-machine-dll',
    'wrong-elf', 'wrong-elf-class', 'wrong-elf-machine',
    'truncated-elf-header', 'wrong-elf-version', 'wrong-elf-header-size', 'wrong-elf-type',
    'bad-elf-program-offset', 'bad-elf-program-entry-size', 'bad-elf-load-range',
    'no-elf-load-segment', 'zero-sized-load-segment',
    'empty-required-entry', 'corrupt', 'empty', 'wrong-content'
)
unsafe_entry_names = {
    'traversal-forward': '../escape.txt',
    'traversal-backslash': r'..\escape.txt',
    'absolute-path': '/absolute.txt',
    'drive-path': r'C:\escape.txt',
    'com-superscript-device': 'COM¹.txt',
    'lpt-superscript-device': 'LPT³.log',
}
for case in (*base_cases, *omitted_entries):
    include_executable = case != 'wrong-content'
    omitted_entry = omitted_entries.get(case)
    mac_omit = omitted_entry if omitted_entry and omitted_entry.startswith('LanDrop.app/') else None
    windows_omit = omitted_entry if omitted_entry and not mac_omit else None
    make_zip(case, 'LanDrop-macOS.zip', include_executable=include_executable, omit_entry=mac_omit)
    if case != 'missing':
        windows_contents = b'' if case == 'empty-required-entry' else b'release payload'
        windows_zip = make_zip(
            case,
            'LanDrop-Windows.zip',
            contents=windows_contents,
            include_executable=include_executable,
            omit_entry=windows_omit,
        )
    if case == 'valid':
        mac_archive = root / case / 'LanDrop-macOS.zip'
        with zipfile.ZipFile(mac_archive, 'a') as archive:
            archive.writestr(
                'LanDrop.app/Contents/Frameworks/Test.framework/Versions/A/Resources/Info.plist',
                b'framework fixture',
            )
            add_symlink(
                archive,
                'LanDrop.app/Contents/Frameworks/Test.framework/Versions/Current',
                'A',
            )
            add_symlink(
                archive,
                'LanDrop.app/Contents/Frameworks/Test.framework/Resources',
                'Versions/Current/Resources',
            )
    elif case == 'symlink':
        mac_archive = root / case / 'LanDrop-macOS.zip'
        mac_payload = root / case / 'LanDrop-macOS.payload'
        mac_archive.rename(mac_payload)
        mac_archive.symlink_to(mac_payload.name)
    elif case == 'required-windows-symlink':
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            add_symlink(archive, 'landrop.exe', 'flutter_windows.dll')
    elif case == 'duplicate-path':
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(windows_zip, 'a') as archive:
                archive.writestr('landrop.exe', b'duplicate runtime entry')
    elif case == 'casefold-alias':
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr('LANDROP.EXE', b'case-folded runtime alias')
    elif case == 'separator-alias':
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr(r'data\app.so', b'backslash runtime alias')
    elif case == 'trailing-dot-alias':
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr('landrop.exe.', b'trailing-dot runtime alias')
    elif case == 'trailing-space-alias':
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr('landrop.exe ', b'trailing-space runtime alias')
    elif case in unsafe_entry_names:
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr(unsafe_entry_names[case], b'unsafe path fixture')
    elif case == 'symlink-escape':
        mac_archive = root / case / 'LanDrop-macOS.zip'
        with zipfile.ZipFile(mac_archive, 'a') as archive:
            add_symlink(
                archive,
                'LanDrop.app/Contents/Frameworks/Escape.framework/Contents',
                '../../../../../outside.txt',
            )
    elif case == 'symlink-absolute':
        mac_archive = root / case / 'LanDrop-macOS.zip'
        with zipfile.ZipFile(mac_archive, 'a') as archive:
            add_symlink(archive, 'LanDrop.app/Contents/absolute-link', '/outside.txt')
    elif case == 'symlink-drive':
        mac_archive = root / case / 'LanDrop-macOS.zip'
        with zipfile.ZipFile(mac_archive, 'a') as archive:
            add_symlink(archive, 'LanDrop.app/Contents/drive-link', r'C:\outside.txt')
    elif case == 'special-file':
        info = zipfile.ZipInfo('data/pipe')
        info.create_system = 3
        info.external_attr = (stat.S_IFIFO | 0o600) << 16
        with zipfile.ZipFile(windows_zip, 'a') as archive:
            archive.writestr(info, b'')
    elif case == 'extra':
        make_zip(case, 'unexpected.zip')
    elif case == 'extra-uppercase':
        make_zip(case, 'unexpected.ZIP')
    elif case == 'extra-mixedcase':
        make_zip(case, 'unexpected.Zip')
    elif case == 'extra-hidden':
        make_zip(case, '.unexpected.ZIP')
    elif case == 'corrupt':
        data = bytearray(windows_zip.read_bytes())
        name_length = int.from_bytes(data[26:28], 'little')
        extra_length = int.from_bytes(data[28:30], 'little')
        data[30 + name_length + extra_length] ^= 0xff
        windows_zip.write_bytes(data)
    elif case == 'empty':
        windows_zip.write_bytes(b'')
PY

bash "$verify_script" "$tmp/valid" >/dev/null
manifest_lines="$(wc -l < "$tmp/valid/SHA256SUMS" | tr -d '[:space:]')"
if [[ "$manifest_lines" != 2 ]]; then
  echo "expected two checksum entries, got $manifest_lines" >&2
  exit 1
fi
python3 - "$tmp/valid/SHA256SUMS" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
entries = []
for line in lines:
    match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
    if match is None:
        raise SystemExit(f'invalid checksum line: {line!r}')
    entries.append(match.group(2))
expected = {'LanDrop-macOS.zip', 'LanDrop-Windows.zip'}
if len(entries) != 2 or set(entries) != expected:
    raise SystemExit(f'unexpected checksum entries: {entries!r}')
PY
# Re-running on the same verified output should safely replace the manifest.
bash "$verify_script" "$tmp/valid" >/dev/null
real_sha256sum="$(command -v sha256sum)"
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-c' ]]; then
  exec "$REAL_SHA256SUM" "$@"
fi
for file in "$@"; do
  printf '%064d  %s\n' 0 "$file"
done
SH
chmod +x "$tmp/fakebin/sha256sum"
if LC_ALL=C REAL_SHA256SUM="$real_sha256sum" PATH="$tmp/fakebin:$PATH" \
  bash "$verify_script" "$tmp/valid" >"$tmp/fake-checksum.log" 2>&1; then
  echo 'archive verifier accepted a manifest with incorrect hashes' >&2
  exit 1
fi
if ! grep -q 'FAILED' "$tmp/fake-checksum.log"; then
  echo 'archive verifier failed before checking the incorrect hashes' >&2
  exit 1
fi
if ! (cd "$tmp/valid" && sha256sum -c SHA256SUMS >/dev/null); then
  echo 'checksum verification failure replaced the previous valid manifest' >&2
  exit 1
fi

# A replacement after content validation must not become the published artifact.
mkdir -p "$tmp/toctou" "$tmp/toctou-bin"
cp "$tmp/valid/LanDrop-macOS.zip" "$tmp/toctou/LanDrop-macOS.zip"
cp "$tmp/valid/LanDrop-Windows.zip" "$tmp/toctou/LanDrop-Windows.zip"
printf 'previous manifest sentinel\n' > "$tmp/toctou/SHA256SUMS"
python3 - "$tmp/toctou-replacement.zip" <<'PY'
from zipfile import ZIP_STORED, ZipFile
import sys
with ZipFile(sys.argv[1], 'w', compression=ZIP_STORED) as archive:
    archive.writestr('LanDrop.app/Contents/Info.plist', b'plist')
    archive.writestr('LanDrop.app/Contents/MacOS/LanDrop', b'executable')
    archive.writestr('../escaped.txt', b'unsafe')
PY
cat > "$tmp/toctou-bin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != '-c' && ! -e "$TOCTOU_STAMP" ]]; then
  cp "$TOCTOU_REPLACEMENT" "$TOCTOU_DIST/LanDrop-macOS.zip"
  : > "$TOCTOU_STAMP"
fi
exec "$REAL_SHA256SUM" "$@"
SH
chmod +x "$tmp/toctou-bin/sha256sum"
PATH="$tmp/toctou-bin:$PATH" REAL_SHA256SUM="$real_sha256sum" \
  TOCTOU_REPLACEMENT="$tmp/toctou-replacement.zip" TOCTOU_DIST="$tmp/toctou" \
  TOCTOU_STAMP="$tmp/toctou-replaced" \
  bash "$verify_script" "$tmp/toctou" "$tmp/toctou-verified" > "$tmp/toctou.log" 2>&1
if [[ ! -e "$tmp/toctou-replaced" ]]; then
  echo 'TOCTOU fixture did not replace the live archive after validation' >&2
  exit 1
fi
python3 "$repo_root/flutter_app/tool/verify_zip_paths.py" \
  --require-nonempty 'LanDrop.app/Contents/Info.plist' \
  --require-nonempty 'LanDrop.app/Contents/MacOS/LanDrop' \
  "$tmp/toctou/LanDrop-macOS.zip"
if ! (cd "$tmp/toctou" && sha256sum -c SHA256SUMS >/dev/null); then
  echo 'TOCTOU mitigation published a manifest that does not match installed archives' >&2
  exit 1
fi
python3 - "$tmp/toctou-verified" <<'PY'
from pathlib import Path
import sys
verified = Path(sys.argv[1])
expected = {'LanDrop-macOS.zip', 'LanDrop-Windows.zip', 'SHA256SUMS'}
actual = {entry.name for entry in verified.iterdir()}
if actual != expected or any(not entry.is_file() or entry.is_symlink() for entry in verified.iterdir()):
    raise SystemExit(f'unexpected retained verified artifacts: {actual!r}')
PY
python3 "$repo_root/flutter_app/tool/verify_zip_paths.py" \
  --require-nonempty 'LanDrop.app/Contents/Info.plist' \
  --require-nonempty 'LanDrop.app/Contents/MacOS/LanDrop' \
  "$tmp/toctou-verified/LanDrop-macOS.zip"
if ! (cd "$tmp/toctou-verified" && sha256sum -c SHA256SUMS >/dev/null); then
  echo 'retained verified snapshot checksum manifest is invalid' >&2
  exit 1
fi

# A late extra ZIP must fail the final archive-set recheck.
mkdir -p "$tmp/archive-set-race" "$tmp/archive-set-race-bin"
cp "$tmp/valid/LanDrop-macOS.zip" "$tmp/archive-set-race/LanDrop-macOS.zip"
cp "$tmp/valid/LanDrop-Windows.zip" "$tmp/archive-set-race/LanDrop-Windows.zip"
printf 'previous manifest sentinel\n' > "$tmp/archive-set-race/SHA256SUMS"
cat > "$tmp/archive-set-race-bin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != '-c' && ! -e "$ARCHIVE_SET_STAMP" ]]; then
  cp "$EXTRA_ARCHIVE" "$ARCHIVE_SET_DIST/unexpected.zip"
  : > "$ARCHIVE_SET_STAMP"
fi
exec "$REAL_SHA256SUM" "$@"
SH
chmod +x "$tmp/archive-set-race-bin/sha256sum"
if PATH="$tmp/archive-set-race-bin:$PATH" REAL_SHA256SUM="$real_sha256sum" \
  ARCHIVE_SET_DIST="$tmp/archive-set-race" \
  EXTRA_ARCHIVE="$tmp/valid/LanDrop-macOS.zip" \
  ARCHIVE_SET_STAMP="$tmp/archive-set-race-added" \
  bash "$verify_script" "$tmp/archive-set-race" > "$tmp/archive-set-race.log" 2>&1; then
  echo 'archive verifier accepted an extra ZIP added during validation' >&2
  exit 1
fi
if [[ ! -e "$tmp/archive-set-race-added" || ! -f "$tmp/archive-set-race/unexpected.zip" ]] || \
  ! grep -qx 'previous manifest sentinel' "$tmp/archive-set-race/SHA256SUMS"; then
  echo 'late extra ZIP was not rejected before replacing the previous manifest' >&2
  exit 1
fi

# Claim the retained output path with no-replace semantics at install time.
mkdir -p "$tmp/install-race" "$tmp/install-race-bin"
cp "$tmp/valid/LanDrop-macOS.zip" "$tmp/install-race/LanDrop-macOS.zip"
cp "$tmp/valid/LanDrop-Windows.zip" "$tmp/install-race/LanDrop-Windows.zip"
printf 'previous manifest sentinel\n' > "$tmp/install-race/SHA256SUMS"
cat > "$tmp/install-race-bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-' && "${2:-}" == '--install-verified-output' && \
  ! -e "$INSTALL_RACE_STAMP" ]]; then
  mkdir "$INSTALL_RACE_DEST"
  printf 'UNVERIFIED EVIL' > "$INSTALL_RACE_DEST/LanDrop-macOS.zip"
  printf 'UNVERIFIED EVIL' > "$INSTALL_RACE_DEST/LanDrop-Windows.zip"
  printf 'UNVERIFIED EVIL' > "$INSTALL_RACE_DEST/SHA256SUMS"
  : > "$INSTALL_RACE_STAMP"
fi
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$tmp/install-race-bin/python3"
real_python="$(command -v python3)"
if PATH="$tmp/install-race-bin:$PATH" REAL_PYTHON="$real_python" \
  INSTALL_RACE_DEST="$tmp/install-race-verified" \
  INSTALL_RACE_STAMP="$tmp/install-race-created" \
  bash "$verify_script" "$tmp/install-race" "$tmp/install-race-verified" \
  > "$tmp/install-race.log" 2>&1; then
  echo 'verified output install overwrote or nested into a concurrently-created directory' >&2
  exit 1
fi
if [[ ! -e "$tmp/install-race-created" || \
  ! -f "$tmp/install-race-verified/LanDrop-macOS.zip" ]] || \
  ! grep -qi 'File exists' "$tmp/install-race.log" || \
  ! grep -qx 'previous manifest sentinel' "$tmp/install-race/SHA256SUMS"; then
  echo 'verified output path race was not rejected with no-replace installation' >&2
  exit 1
fi
for invalid_case in \
  missing extra extra-uppercase extra-mixedcase extra-hidden symlink duplicate-path \
  casefold-alias separator-alias traversal-forward traversal-backslash \
  absolute-path drive-path symlink-escape symlink-absolute symlink-drive \
  special-file trailing-dot-alias trailing-space-alias \
  com-superscript-device lpt-superscript-device wrong-pe bad-pe-offset bad-pe-signature \
  truncated-pe-image wrong-pe-optional-magic no-pe-sections bad-pe-section-range \
  zero-pe-image-size zero-pe-headers-size bad-pe-image-size bad-pe-headers-size \
  bad-pe-alignment \
  wrong-pe-machine-exe wrong-pe-machine-dll wrong-elf wrong-elf-class wrong-elf-machine \
  truncated-elf-header wrong-elf-version wrong-elf-header-size wrong-elf-type \
  bad-elf-program-offset bad-elf-program-entry-size bad-elf-load-range no-elf-load-segment \
  zero-sized-load-segment \
  required-windows-symlink \
  empty-required-entry corrupt empty wrong-content \
  missing-macos-info missing-macos-executable \
  missing-windows-executable missing-windows-flutter missing-windows-aot \
  missing-windows-icu missing-windows-assets; do
  if bash "$verify_script" "$tmp/$invalid_case" >"$tmp/$invalid_case.log" 2>&1; then
    echo "archive verifier accepted invalid case: $invalid_case" >&2
    exit 1
  fi
  if [[ -e "$tmp/$invalid_case/SHA256SUMS" ]]; then
    echo "archive verifier wrote checksums for invalid case: $invalid_case" >&2
    exit 1
  fi
  case "$invalid_case" in
    duplicate-path|casefold-alias|separator-alias|traversal-forward|traversal-backslash|\
      absolute-path|drive-path|symlink-escape|symlink-absolute|symlink-drive|\
      special-file|trailing-dot-alias|trailing-space-alias|\
      com-superscript-device|lpt-superscript-device|\
      required-windows-symlink|empty-required-entry|wrong-pe|bad-pe-offset|bad-pe-signature|\
      truncated-pe-image|wrong-pe-optional-magic|no-pe-sections|bad-pe-section-range|\
      zero-pe-image-size|zero-pe-headers-size|bad-pe-image-size|bad-pe-headers-size|\
      bad-pe-alignment|\
      wrong-pe-machine-exe|wrong-pe-machine-dll|wrong-elf|wrong-elf-class|wrong-elf-machine|\
      truncated-elf-header|wrong-elf-version|wrong-elf-header-size|wrong-elf-type|\
      bad-elf-program-offset|bad-elf-program-entry-size|bad-elf-load-range|\
      no-elf-load-segment|zero-sized-load-segment)
      if ! grep -q 'ZIP content verification failed:' "$tmp/$invalid_case.log"; then
        echo "ZIP safety fixture was rejected before content validation: $invalid_case" >&2
        exit 1
      fi
      ;;
  esac
done
mkdir -p "$tmp/manifest-symlink"
cp "$tmp/valid/LanDrop-macOS.zip" "$tmp/manifest-symlink/LanDrop-macOS.zip"
cp "$tmp/valid/LanDrop-Windows.zip" "$tmp/manifest-symlink/LanDrop-Windows.zip"
printf 'preserve-me\n' > "$tmp/manifest-target"
ln -s "$tmp/manifest-target" "$tmp/manifest-symlink/SHA256SUMS"
if bash "$verify_script" "$tmp/manifest-symlink" >"$tmp/manifest-symlink.log" 2>&1; then
  echo 'archive verifier accepted a symlinked checksum output path' >&2
  exit 1
fi
if ! grep -qx 'preserve-me' "$tmp/manifest-target" || \
  [[ ! -L "$tmp/manifest-symlink/SHA256SUMS" ]]; then
  echo 'archive verifier followed or replaced a symlinked checksum path' >&2
  exit 1
fi
mkdir -p "$tmp/manifest-hardlink"
cp "$tmp/valid/LanDrop-macOS.zip" "$tmp/manifest-hardlink/LanDrop-macOS.zip"
cp "$tmp/valid/LanDrop-Windows.zip" "$tmp/manifest-hardlink/LanDrop-Windows.zip"
printf 'preserve-hardlink\n' > "$tmp/manifest-hardlink-target"
ln "$tmp/manifest-hardlink-target" "$tmp/manifest-hardlink/SHA256SUMS"
if ! bash "$verify_script" "$tmp/manifest-hardlink" >"$tmp/manifest-hardlink.log" 2>&1; then
  echo 'archive verifier failed to atomically replace a hard-linked checksum path' >&2
  exit 1
fi
if ! grep -qx 'preserve-hardlink' "$tmp/manifest-hardlink-target" || \
  [[ "$tmp/manifest-hardlink/SHA256SUMS" -ef "$tmp/manifest-hardlink-target" ]]; then
  echo 'archive verifier modified the target of a hard-linked checksum path' >&2
  exit 1
fi
if GLOBIGNORE='unexpected.zip' bash "$verify_script" "$tmp/extra" \
  >"$tmp/globignore.log" 2>&1; then
  echo 'archive verifier ignored an extra ZIP filtered by GLOBIGNORE' >&2
  exit 1
fi
if [[ -e "$tmp/extra/SHA256SUMS" ]]; then
  echo 'archive verifier wrote checksums while GLOBIGNORE hid an extra ZIP' >&2
  exit 1
fi

echo 'release archive verification tests passed'
