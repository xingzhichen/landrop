#pragma once

#include <windows.h>

#include <string>

namespace landrop {

enum class ReceiveEntryCreateKind { kSuccess, kUnsafePath, kIoFailure };

struct ReceiveEntryCreateResult {
  ReceiveEntryCreateKind kind;
  DWORD error = ERROR_SUCCESS;
};

// Creates one file relative to a validated directory handle, with a protected
// owner-only DACL. The security descriptor remains alive through NtCreateFile.
ReceiveEntryCreateResult CreatePrivateReceiveEntryRelative(
    HANDLE parent, const std::wstring& component, HANDLE* output);

}  // namespace landrop
