#pragma once

#include <windows.h>

#include <cstdint>
#include <vector>

namespace landrop {

// Owns the backing buffers referenced by descriptor until the OS consumes it.
struct PrivateReceiveSecurity {
  SECURITY_DESCRIPTOR descriptor = {};
  std::vector<std::uint8_t> token_user_storage;
  std::vector<std::uint8_t> acl_storage;
};

// Builds a protected DACL granting file access only to the current user.
DWORD InitializePrivateReceiveSecurity(PrivateReceiveSecurity* security);

// Ensures an existing, current-user-owned receive file has that protected DACL.
// The handle must include READ_CONTROL and WRITE_DAC access.
DWORD EnsurePrivateReceiveFileDacl(HANDLE file);

}  // namespace landrop
