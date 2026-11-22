#include "private_receive_entry.h"

#include "private_receive_security.h"

#include <winternl.h>

#include <limits>

namespace landrop {
namespace {

constexpr ULONG kFileCreate = 2;
constexpr ULONG kFileNonDirectoryFile = 0x00000040;
constexpr ULONG kFileOpenReparsePoint = 0x00200000;
constexpr ULONG kFileSynchronousIoNonalert = 0x00000020;
constexpr ULONG kObjectCaseInsensitive = 0x00000040;
constexpr ULONG kPinnedShare = FILE_SHARE_READ;

const NTSTATUS kStatusFileIsADirectory = static_cast<NTSTATUS>(0xC00000BAL);
const NTSTATUS kStatusNotADirectory = static_cast<NTSTATUS>(0xC0000103L);

using NtCreateFileFunction = NTSTATUS(NTAPI*)(
    PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK, PLARGE_INTEGER,
    ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);

NtCreateFileFunction GetNtCreateFile() {
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return nullptr;
  return reinterpret_cast<NtCreateFileFunction>(
      ::GetProcAddress(ntdll, "NtCreateFile"));
}

ReceiveEntryCreateResult Success() {
  return {ReceiveEntryCreateKind::kSuccess, ERROR_SUCCESS};
}

ReceiveEntryCreateResult UnsafePath() {
  return {ReceiveEntryCreateKind::kUnsafePath, ERROR_SUCCESS};
}

ReceiveEntryCreateResult IoFailure(DWORD error) {
  return {ReceiveEntryCreateKind::kIoFailure, error};
}

}  // namespace

ReceiveEntryCreateResult CreatePrivateReceiveEntryRelative(
    HANDLE parent, const std::wstring& component, HANDLE* output) {
  if (parent == nullptr || parent == INVALID_HANDLE_VALUE || output == nullptr ||
      component.empty() || component.find(L'\0') != std::wstring::npos ||
      component.find_first_of(L"\\/") != std::wstring::npos ||
      component.size() > std::numeric_limits<USHORT>::max() / sizeof(wchar_t)) {
    return UnsafePath();
  }

  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (nt_create_file == nullptr) return IoFailure(ERROR_PROC_NOT_FOUND);

  // POSIX receive entries use mode 0600. On Windows, prevent inherited parent
  // ACLs from exposing partial uploads to other local users.
  PrivateReceiveSecurity private_security;
  const DWORD security_error =
      InitializePrivateReceiveSecurity(&private_security);
  if (security_error != ERROR_SUCCESS) return IoFailure(security_error);

  UNICODE_STRING name = {};
  name.Buffer = const_cast<PWSTR>(component.c_str());
  name.Length = static_cast<USHORT>(component.size() * sizeof(wchar_t));
  name.MaximumLength = name.Length;

  OBJECT_ATTRIBUTES attributes = {};
  attributes.Length = static_cast<ULONG>(sizeof(attributes));
  attributes.RootDirectory = parent;
  attributes.ObjectName = &name;
  attributes.Attributes = kObjectCaseInsensitive;
  attributes.SecurityDescriptor = &private_security.descriptor;

  IO_STATUS_BLOCK io_status = {};
  constexpr ULONG options = kFileOpenReparsePoint | kFileSynchronousIoNonalert |
                            kFileNonDirectoryFile;
  HANDLE created_raw = nullptr;
  const NTSTATUS status = nt_create_file(
      &created_raw,
      DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_DATA | SYNCHRONIZE,
      &attributes, &io_status, nullptr, FILE_ATTRIBUTE_NORMAL, kPinnedShare,
      kFileCreate, options, nullptr, 0);
  if (status < 0) {
    if (created_raw != nullptr && created_raw != INVALID_HANDLE_VALUE) {
      ::CloseHandle(created_raw);
    }
    if (status == kStatusFileIsADirectory || status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(status));
  }
  if (created_raw == nullptr || created_raw == INVALID_HANDLE_VALUE) {
    return IoFailure(ERROR_INVALID_HANDLE);
  }
  *output = created_raw;
  return Success();
}

}  // namespace landrop
