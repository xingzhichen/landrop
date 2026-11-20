#!/usr/bin/env python3
"""Validate ZIP paths, required runtime files, and optional binary headers."""

import argparse
import re
import stat
import struct
import sys
import unicodedata
from zipfile import BadZipFile, ZipFile

_DRIVE_PREFIX = re.compile(r"^[A-Za-z]:")
_WINDOWS_RESERVED = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
_MAX_SYMLINK_TARGET_BYTES = 4096
_MAX_PE_HEADER_OFFSET = 1 << 20
_MAX_PE_SECTIONS = 96
_PE_EXECUTABLE_IMAGE = 0x0002
_PE32_OPTIONAL_MAGIC = 0x010B
_PE32_PLUS_OPTIONAL_MAGIC = 0x020B
_PE32_OPTIONAL_MIN_SIZE = 96
_PE32_PLUS_OPTIONAL_MIN_SIZE = 112
_PE_PAGE_SIZE = 0x1000
_PE_MIN_FILE_ALIGNMENT = 0x200
_PE_MAX_FILE_ALIGNMENT = 0x10000
_PE_SECTION_HEADER_SIZE = 40
_X64_PE_MACHINE = 0x8664
_X64_ELF_MACHINE = 0x003E
_ELF_CURRENT_VERSION = 1
_ELF_SHARED_OBJECT = 3
_ELF64_HEADER_SIZE = 64
_ELF64_PROGRAM_HEADER_SIZE = 56
_ELF_PT_LOAD = 1
_MAX_ELF_PROGRAM_HEADER_OFFSET = 1 << 20
_MAX_ELF_PROGRAM_TABLE_BYTES = 1 << 20


def _is_power_of_two(value: int) -> bool:
    return value > 0 and value & (value - 1) == 0


def _validate_windows_component(component: str, context: str) -> None:
    if component.endswith((" ", ".")):
        raise ValueError(f"Windows-trimmed path component in {context}: {component!r}")
    if any(ord(char) < 32 or char in '<>:"|?*' for char in component):
        raise ValueError(f"invalid Windows path character in {context}: {component!r}")
    base = component.split(".", 1)[0].rstrip(" .").upper()
    if base in _WINDOWS_RESERVED or re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", base):
        raise ValueError(f"reserved Windows device name in {context}: {component!r}")


def _safe_member_parts(name: str, windows_target: bool) -> list[str]:
    if "\\" in name:
        raise ValueError(f"backslash in archive entry path: {name!r}")
    if "\x00" in name or name.startswith("/") or _DRIVE_PREFIX.match(name):
        raise ValueError(f"unsafe archive entry path: {name!r}")

    parts = name.split("/")
    if parts and parts[-1] == "":  # ZIP directory entries conventionally end in '/'.
        parts.pop()
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe archive entry path: {name!r}")
    if windows_target:
        for part in parts:
            _validate_windows_component(part, f"archive entry {name!r}")
    return parts


def _validate_symlink_target(
    archive: ZipFile, info, member_parts: list[str], windows_target: bool
) -> None:
    if info.file_size == 0 or info.file_size > _MAX_SYMLINK_TARGET_BYTES:
        raise ValueError(f"invalid symlink target size for {info.filename!r}")

    raw_target = archive.read(info)
    if b"\x00" in raw_target:
        raise ValueError(f"NUL byte in symlink target for {info.filename!r}")
    target = raw_target.decode("utf-8", errors="surrogateescape").replace("\\", "/")
    if target.startswith("/") or _DRIVE_PREFIX.match(target):
        raise ValueError(f"absolute symlink target for {info.filename!r}: {target!r}")

    resolved = member_parts[:-1]
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ValueError(f"symlink target escapes archive root for {info.filename!r}")
            resolved.pop()
        else:
            if windows_target:
                _validate_windows_component(part, f"symlink target for {info.filename!r}")
            resolved.append(part)


def _validate_elf64_x64_shared_object(archive: ZipFile, info) -> None:
    with archive.open(info) as binary:
        elf_header = binary.read(_ELF64_HEADER_SIZE)
        if (
            len(elf_header) < _ELF64_HEADER_SIZE
            or elf_header[:4] != b"\x7fELF"
            or elf_header[4] != 2
            or elf_header[5] != 1
            or elf_header[6] != _ELF_CURRENT_VERSION
        ):
            raise ValueError(
                f"required ELF file is not a complete little-endian ELF64 image: {info.filename}"
            )

        elf_type = struct.unpack_from("<H", elf_header, 16)[0]
        machine = struct.unpack_from("<H", elf_header, 18)[0]
        version = struct.unpack_from("<I", elf_header, 20)[0]
        header_size = struct.unpack_from("<H", elf_header, 52)[0]
        if (
            elf_type != _ELF_SHARED_OBJECT
            or version != _ELF_CURRENT_VERSION
            or header_size != _ELF64_HEADER_SIZE
        ):
            raise ValueError(f"invalid ELF64 shared-object header fields in {info.filename}")
        if machine != _X64_ELF_MACHINE:
            raise ValueError(
                f"required ELF file is not x64: {info.filename} (machine 0x{machine:04x})"
            )

        program_offset = struct.unpack_from("<Q", elf_header, 32)[0]
        program_entry_size, program_count = struct.unpack_from("<HH", elf_header, 54)
        program_table_size = program_entry_size * program_count
        if (
            program_entry_size != _ELF64_PROGRAM_HEADER_SIZE
            or program_count == 0
            or program_offset < _ELF64_HEADER_SIZE
            or program_offset > _MAX_ELF_PROGRAM_HEADER_OFFSET
            or program_table_size > _MAX_ELF_PROGRAM_TABLE_BYTES
            or program_offset + program_table_size > info.file_size
        ):
            raise ValueError(f"invalid ELF64 program-header table in {info.filename}")

        binary.seek(program_offset)
        load_segment_count = 0
        for _ in range(program_count):
            program_header = binary.read(program_entry_size)
            if len(program_header) != program_entry_size:
                raise ValueError(f"truncated ELF64 program-header table in {info.filename}")
            segment_type = struct.unpack_from("<I", program_header, 0)[0]
            if segment_type != _ELF_PT_LOAD:
                continue
            segment_offset = struct.unpack_from("<Q", program_header, 8)[0]
            segment_file_size = struct.unpack_from("<Q", program_header, 32)[0]
            segment_memory_size = struct.unpack_from("<Q", program_header, 40)[0]
            if (
                segment_memory_size < segment_file_size
                or segment_offset + segment_file_size > info.file_size
            ):
                raise ValueError(f"invalid ELF64 load segment in {info.filename}")
            # A zero-sized PT_LOAD does not make the shared object loadable.
            if segment_memory_size > 0:
                load_segment_count += 1
        if load_segment_count == 0:
            raise ValueError(f"ELF64 shared object has no loadable segment: {info.filename}")


def _validate_pe_image(archive: ZipFile, info, require_x64: bool) -> None:
    with archive.open(info) as binary:
        dos_header = binary.read(64)
        if len(dos_header) < 64 or dos_header[:2] != b"MZ":
            raise ValueError(f"required PE file has no valid DOS header: {info.filename}")
        pe_offset = struct.unpack_from("<I", dos_header, 0x3C)[0]
        if pe_offset < 64 or pe_offset > _MAX_PE_HEADER_OFFSET or pe_offset + 24 > info.file_size:
            raise ValueError(f"invalid PE header offset in {info.filename}: {pe_offset}")

        binary.seek(pe_offset)
        if binary.read(4) != b"PE\x00\x00":
            raise ValueError(f"required PE file has no valid PE signature: {info.filename}")
        coff_header = binary.read(20)
        if len(coff_header) != 20:
            raise ValueError(f"truncated PE COFF header in {info.filename}")
        machine, section_count = struct.unpack_from("<HH", coff_header, 0)
        optional_size = struct.unpack_from("<H", coff_header, 16)[0]
        characteristics = struct.unpack_from("<H", coff_header, 18)[0]
        if require_x64 and machine != _X64_PE_MACHINE:
            raise ValueError(
                f"required PE file is not x64: {info.filename} (machine 0x{machine:04x})"
            )
        if section_count == 0 or section_count > _MAX_PE_SECTIONS:
            raise ValueError(f"invalid PE section count in {info.filename}: {section_count}")
        if not characteristics & _PE_EXECUTABLE_IMAGE:
            raise ValueError(f"PE file is not marked executable: {info.filename}")

        optional_offset = pe_offset + 24
        if optional_size < 2 or optional_offset + optional_size > info.file_size:
            raise ValueError(f"invalid PE optional-header size in {info.filename}")
        optional_header = binary.read(optional_size)
        if len(optional_header) != optional_size:
            raise ValueError(f"truncated PE optional header in {info.filename}")
        optional_magic = struct.unpack_from("<H", optional_header, 0)[0]
        if optional_magic == _PE32_PLUS_OPTIONAL_MAGIC:
            directory_count_offset = 108
            minimum_optional_size = _PE32_PLUS_OPTIONAL_MIN_SIZE
        elif optional_magic == _PE32_OPTIONAL_MAGIC and not require_x64:
            directory_count_offset = 92
            minimum_optional_size = _PE32_OPTIONAL_MIN_SIZE
        else:
            raise ValueError(f"invalid PE optional-header magic in {info.filename}")
        if optional_size < minimum_optional_size:
            raise ValueError(f"truncated PE optional header in {info.filename}")
        directory_count = struct.unpack_from("<I", optional_header, directory_count_offset)[0]
        if minimum_optional_size + directory_count * 8 > optional_size:
            raise ValueError(f"invalid PE data-directory table in {info.filename}")

        section_alignment = struct.unpack_from("<I", optional_header, 32)[0]
        file_alignment = struct.unpack_from("<I", optional_header, 36)[0]
        size_of_image = struct.unpack_from("<I", optional_header, 56)[0]
        size_of_headers = struct.unpack_from("<I", optional_header, 60)[0]
        invalid_alignment = (
            not _is_power_of_two(section_alignment)
            or not _is_power_of_two(file_alignment)
            or (
                section_alignment < _PE_PAGE_SIZE
                and file_alignment != section_alignment
            )
            or (
                section_alignment >= _PE_PAGE_SIZE
                and (
                    file_alignment < _PE_MIN_FILE_ALIGNMENT
                    or file_alignment > _PE_MAX_FILE_ALIGNMENT
                    or file_alignment > section_alignment
                )
            )
        )
        if (
            invalid_alignment
            or not size_of_image
            or not size_of_headers
            or size_of_image < size_of_headers
            or size_of_image % section_alignment
            or size_of_headers % file_alignment
        ):
            raise ValueError(f"invalid PE image-size or alignment fields in {info.filename}")

        section_table_size = section_count * _PE_SECTION_HEADER_SIZE
        section_table_end = optional_offset + optional_size + section_table_size
        if section_table_end > info.file_size:
            raise ValueError(f"truncated PE section table in {info.filename}")
        if size_of_headers < section_table_end or size_of_headers > info.file_size:
            raise ValueError(f"invalid PE SizeOfHeaders in {info.filename}")
        section_headers = binary.read(section_table_size)
        if len(section_headers) != section_table_size:
            raise ValueError(f"truncated PE section table in {info.filename}")
        for index in range(section_count):
            start = index * _PE_SECTION_HEADER_SIZE
            end = start + _PE_SECTION_HEADER_SIZE
            section = section_headers[start:end]
            virtual_size, virtual_address = struct.unpack_from("<II", section, 8)
            raw_size, raw_offset = struct.unpack_from("<II", section, 16)
            if (
                virtual_address % section_alignment
                or virtual_address + max(virtual_size, raw_size) > size_of_image
            ):
                raise ValueError(f"PE section is outside SizeOfImage in {info.filename}")
            if raw_size and (
                raw_offset < size_of_headers
                or raw_offset % file_alignment
                or raw_size % file_alignment
                or raw_offset + raw_size > info.file_size
            ):
                raise ValueError(f"PE section data is out of bounds in {info.filename}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--windows-target", action="store_true")
    parser.add_argument("--require-nonempty", action="append", default=[])
    parser.add_argument("--require-pe", action="append", default=[])
    parser.add_argument("--require-pe-x64", action="append", default=[])
    parser.add_argument("--require-elf64-x64", action="append", default=[])
    parser.add_argument("archive")
    args = parser.parse_args()
    windows_target = args.windows_target
    required_pe_x64_entries = set(args.require_pe_x64)
    required_elf64_x64_entries = set(args.require_elf64_x64)
    required_pe_entries = set(args.require_pe) | required_pe_x64_entries
    required_entries = (
        set(args.require_nonempty)
        | required_pe_entries
        | required_elf64_x64_entries
    )
    archive_path = args.archive
    try:
        with ZipFile(archive_path) as archive:
            required_status = {}
            seen_paths = {}
            seen_spellings = {}
            seen_nodes = set()
            file_paths = set()
            for info in archive.infolist():
                parts = _safe_member_parts(info.filename, windows_target)
                key = tuple(
                    unicodedata.normalize("NFC", part).casefold() for part in parts
                )
                if key in seen_paths:
                    raise ValueError(
                        "duplicate or case-insensitive path collision: "
                        f"{seen_paths[key]!r} and {info.filename!r}"
                    )

                for length in range(1, len(parts) + 1):
                    prefix = key[:length]
                    spelling = tuple(parts[:length])
                    previous_spelling = seen_spellings.get(prefix)
                    if previous_spelling is not None and previous_spelling != spelling:
                        raise ValueError(
                            "case-insensitive path alias: "
                            f"{previous_spelling!r} and {spelling!r}"
                        )
                    seen_spellings.setdefault(prefix, spelling)

                unix_mode = info.external_attr >> 16
                file_type = stat.S_IFMT(unix_mode)
                allowed_types = (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK)
                if file_type not in allowed_types:
                    raise ValueError(
                        f"unsupported special file type for {info.filename!r}"
                    )
                is_symlink = file_type == stat.S_IFLNK
                if info.is_dir() and file_type in (stat.S_IFREG, stat.S_IFLNK):
                    raise ValueError(f"non-directory has directory path: {info.filename!r}")
                is_directory = (info.is_dir() or file_type == stat.S_IFDIR) and not is_symlink
                if info.filename in required_entries:
                    required_status[info.filename] = (
                        not is_directory
                        and not is_symlink
                        and file_type in (0, stat.S_IFREG)
                        and info.file_size > 0
                    )
                if any(parent in file_paths for parent in key[:-1]):
                    raise ValueError(f"file path is a parent of another entry: {info.filename!r}")
                if not is_directory and key in seen_nodes and key not in seen_paths:
                    raise ValueError(f"file path conflicts with a child entry: {info.filename!r}")

                seen_paths[key] = info.filename
                seen_nodes.update(key[:length] for length in range(1, len(key) + 1))
                if not is_directory:
                    file_paths.add(key)
                if is_symlink:
                    _validate_symlink_target(archive, info, parts, windows_target)
            for required in sorted(required_entries):
                if required not in required_status:
                    raise ValueError(f"missing required runtime file: {required}")
                if not required_status[required]:
                    raise ValueError(
                        f"required runtime entry is not a non-empty regular file: {required}"
                    )
            for required_pe in sorted(required_pe_entries):
                info = archive.getinfo(required_pe)
                is_x64 = required_pe in required_pe_x64_entries
                _validate_pe_image(archive, info, is_x64)
            for required_elf in sorted(required_elf64_x64_entries):
                info = archive.getinfo(required_elf)
                _validate_elf64_x64_shared_object(archive, info)
    except (BadZipFile, EOFError, OSError, RuntimeError, struct.error, ValueError) as error:
        print(f"{archive_path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
