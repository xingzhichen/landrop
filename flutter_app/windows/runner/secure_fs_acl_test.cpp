#include "private_receive_entry.h"
#include "private_receive_security.h"

#include <aclapi.h>
#include <sddl.h>
#include <windows.h>

#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = nullptr) : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      ::CloseHandle(handle_);
    }
  }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_;
};

class ScopedLocalMemory {
 public:
  explicit ScopedLocalMemory(HLOCAL memory = nullptr) : memory_(memory) {}
  ~ScopedLocalMemory() {
    if (memory_ != nullptr) ::LocalFree(memory_);
  }

  ScopedLocalMemory(const ScopedLocalMemory&) = delete;
  ScopedLocalMemory& operator=(const ScopedLocalMemory&) = delete;

  HLOCAL get() const { return memory_; }

 private:
  HLOCAL memory_;
};

class ScopedTestDirectory {
 public:
  explicit ScopedTestDirectory(std::wstring path)
      : path_(std::move(path)), control_file_(path_ + L"\\inherited.txt"),
        private_file_(path_ + L"\\private.txt"),
        legacy_file_(path_ + L"\\legacy.txt") {}
  ~ScopedTestDirectory() {
    ::DeleteFileW(control_file_.c_str());
    ::DeleteFileW(private_file_.c_str());
    ::DeleteFileW(legacy_file_.c_str());
    ::RemoveDirectoryW(path_.c_str());
  }

  const std::wstring& path() const { return path_; }
  const std::wstring& control_file() const { return control_file_; }
  const std::wstring& private_file() const { return private_file_; }
  const std::wstring& legacy_file() const { return legacy_file_; }

 private:
  std::wstring path_;
  std::wstring control_file_;
  std::wstring private_file_;
  std::wstring legacy_file_;
};

bool Fail(const wchar_t* message, DWORD error = ::GetLastError()) {
  std::wcerr << message << L" (error " << error << L")\n";
  return false;
}

bool CaptureCurrentUserSid(std::vector<std::uint8_t>* storage, PSID* sid) {
  if (storage == nullptr || sid == nullptr) return false;
  HANDLE token_raw = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token_raw)) {
    return false;
  }
  ScopedHandle token(token_raw);

  DWORD token_user_size = 0;
  if (::GetTokenInformation(token.get(), TokenUser, nullptr, 0,
                            &token_user_size)) {
    return false;
  }
  if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER ||
      token_user_size < sizeof(TOKEN_USER)) {
    return false;
  }
  storage->resize(token_user_size);
  if (!::GetTokenInformation(token.get(), TokenUser, storage->data(),
                             token_user_size, &token_user_size)) {
    return false;
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(storage->data());
  if (!::IsValidSid(user->User.Sid)) return false;
  *sid = user->User.Sid;
  return true;
}

bool AclContainsSid(PACL acl, PSID sid, bool* found, bool* inherited,
                    ACCESS_MASK* access_mask, DWORD* ace_count) {
  if (acl == nullptr || found == nullptr || inherited == nullptr ||
      ace_count == nullptr) {
    return false;
  }
  ACL_SIZE_INFORMATION size = {};
  if (!::GetAclInformation(acl, &size, sizeof(size), AclSizeInformation)) {
    return false;
  }
  *found = false;
  *inherited = false;
  if (access_mask != nullptr) *access_mask = 0;
  *ace_count = size.AceCount;
  for (DWORD index = 0; index < size.AceCount; ++index) {
    void* raw_ace = nullptr;
    if (!::GetAce(acl, index, &raw_ace)) return false;
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType == ACCESS_ALLOWED_ACE_TYPE) {
      auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw_ace);
      if (::EqualSid(&ace->SidStart, sid)) {
        *found = true;
        *inherited = (header->AceFlags & INHERITED_ACE) != 0;
        if (access_mask != nullptr) *access_mask = ace->Mask;
      }
    }
  }
  return true;
}

bool InspectFileDacl(const std::wstring& path, PSID world_sid,
                     PSID expected_owner, bool expect_private) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  PSID owner = nullptr;
  PACL dacl = nullptr;
  const DWORD inspect_error = ::GetNamedSecurityInfoW(
      const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, nullptr,
      &dacl, nullptr, &descriptor);
  ScopedLocalMemory descriptor_memory(descriptor);
  if (inspect_error != ERROR_SUCCESS) {
    return Fail(L"Could not read created file security descriptor", inspect_error);
  }

  bool has_world = false;
  bool world_is_inherited = false;
  DWORD ace_count = 0;
  if (!AclContainsSid(dacl, world_sid, &has_world, &world_is_inherited,
                      nullptr, &ace_count)) {
    return Fail(L"Could not inspect created file DACL");
  }
  if (!expect_private) {
    if (!has_world || !world_is_inherited) {
      return Fail(L"Control file did not inherit the permissive parent ACE");
    }
    return true;
  }
  if (has_world) return Fail(L"Private file inherited the Everyone ACE");
  if (ace_count != 1) return Fail(L"Private file DACL is not a single owner ACE");
  if (owner == nullptr || !::EqualSid(owner, expected_owner)) {
    return Fail(L"Private file owner is not the current user");
  }
  bool has_owner_ace = false;
  bool owner_ace_is_inherited = false;
  ACCESS_MASK owner_access = 0;
  DWORD private_ace_count = 0;
  if (!AclContainsSid(dacl, expected_owner, &has_owner_ace,
                      &owner_ace_is_inherited, &owner_access,
                      &private_ace_count) ||
      !has_owner_ace || owner_ace_is_inherited || private_ace_count != 1) {
    return Fail(L"Private file DACL does not grant access to its owner");
  }
  constexpr ACCESS_MASK kExpectedOwnerAccess =
      FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE | READ_CONTROL;
  if ((owner_access & kExpectedOwnerAccess) != kExpectedOwnerAccess ||
      (owner_access & FILE_EXECUTE) != 0) {
    return Fail(L"Private file DACL does not limit access to read/write/delete");
  }

  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!::GetSecurityDescriptorControl(descriptor, &control, &revision)) {
    return Fail(L"Could not inspect private DACL inheritance control");
  }
  if ((control & SE_DACL_PROTECTED) == 0) {
    return Fail(L"Private file DACL is not protected from inheritance");
  }
  return true;
}

bool TestLegacyPartialRepair(const ScopedTestDirectory& directory, PSID world_sid,
                             PSID expected_owner) {
  ScopedHandle legacy(::CreateFileW(
      directory.legacy_file().c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL | WRITE_DAC | WRITE_OWNER,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (legacy.get() == INVALID_HANDLE_VALUE) {
    return Fail(L"Could not create legacy partial with inherited DACL");
  }
  // Elevated CI processes may default new-file ownership to the Administrators
  // group. Model an app-created partial by pinning it to this process user while
  // retaining the deliberately inherited, permissive DACL under test.
  const DWORD owner_error = ::SetSecurityInfo(
      legacy.get(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, expected_owner,
      nullptr, nullptr, nullptr);
  if (owner_error != ERROR_SUCCESS) {
    return Fail(L"Could not set legacy partial owner", owner_error);
  }
  constexpr char kPayload[] = "resumable partial data";
  constexpr DWORD kPayloadSize =
      static_cast<DWORD>(sizeof(kPayload) - 1);
  DWORD bytes_written = 0;
  if (!::WriteFile(legacy.get(), kPayload, kPayloadSize, &bytes_written,
                   nullptr) ||
      bytes_written != kPayloadSize) {
    return Fail(L"Could not write legacy partial test payload");
  }
  if (!InspectFileDacl(directory.legacy_file(), world_sid, nullptr, false)) {
    return false;
  }

  BY_HANDLE_FILE_INFORMATION before = {};
  if (!::GetFileInformationByHandle(legacy.get(), &before)) {
    return Fail(L"Could not capture legacy partial identity");
  }

  ScopedHandle read_only(::CreateFileW(
      directory.legacy_file().c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (read_only.get() == INVALID_HANDLE_VALUE) {
    return Fail(L"Could not open legacy partial without WRITE_DAC");
  }
  const DWORD denied = landrop::EnsurePrivateReceiveFileDacl(read_only.get());
  if (denied == ERROR_SUCCESS) {
    return Fail(L"DACL repair unexpectedly succeeded without WRITE_DAC");
  }
  if (!InspectFileDacl(directory.legacy_file(), world_sid, nullptr, false)) {
    return Fail(L"Failed DACL repair changed the legacy partial ACL");
  }

  const DWORD repaired = landrop::EnsurePrivateReceiveFileDacl(legacy.get());
  if (repaired != ERROR_SUCCESS) {
    return Fail(L"Could not repair legacy partial DACL", repaired);
  }
  if (!InspectFileDacl(directory.legacy_file(), world_sid, expected_owner, true)) {
    return false;
  }

  BY_HANDLE_FILE_INFORMATION after = {};
  if (!::GetFileInformationByHandle(legacy.get(), &after)) {
    return Fail(L"Could not inspect repaired legacy partial identity");
  }
  if (before.dwVolumeSerialNumber != after.dwVolumeSerialNumber ||
      before.nFileIndexHigh != after.nFileIndexHigh ||
      before.nFileIndexLow != after.nFileIndexLow) {
    return Fail(L"DACL repair changed the legacy partial file identity");
  }
  LARGE_INTEGER zero = {};
  if (!::SetFilePointerEx(legacy.get(), zero, nullptr, FILE_BEGIN)) {
    return Fail(L"Could not seek repaired legacy partial");
  }
  char actual[sizeof(kPayload)] = {};
  DWORD bytes_read = 0;
  if (!::ReadFile(legacy.get(), actual, kPayloadSize, &bytes_read, nullptr) ||
      bytes_read != kPayloadSize ||
      std::string(actual, bytes_read) != std::string(kPayload, kPayloadSize)) {
    return Fail(L"DACL repair changed the legacy partial contents");
  }
  return true;
}

bool RunTest() {
  wchar_t temp_path[MAX_PATH + 1] = {};
  const DWORD temp_length = ::GetTempPathW(MAX_PATH, temp_path);
  if (temp_length == 0 || temp_length >= MAX_PATH) {
    return Fail(L"Could not locate a temporary directory");
  }
  std::wstring path(temp_path, temp_length);
  path += L"landrop-secure-acl-" + std::to_wstring(::GetCurrentProcessId()) +
          L"-" + std::to_wstring(::GetTickCount64());
  if (!::CreateDirectoryW(path.c_str(), nullptr)) {
    return Fail(L"Could not create test directory");
  }
  ScopedTestDirectory directory(path);

  PSECURITY_DESCRIPTOR parent_descriptor_raw = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:(A;OICI;GA;;;WD)", SDDL_REVISION_1, &parent_descriptor_raw,
          nullptr)) {
    return Fail(L"Could not build permissive test parent DACL");
  }
  ScopedLocalMemory parent_descriptor(parent_descriptor_raw);
  BOOL dacl_present = FALSE;
  BOOL dacl_defaulted = FALSE;
  PACL parent_dacl = nullptr;
  if (!::GetSecurityDescriptorDacl(parent_descriptor.get(), &dacl_present,
                                   &parent_dacl, &dacl_defaulted) ||
      !dacl_present || parent_dacl == nullptr) {
    return Fail(L"Could not obtain permissive test parent DACL");
  }
  const DWORD set_parent_error = ::SetNamedSecurityInfoW(
      const_cast<LPWSTR>(directory.path().c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
      nullptr, parent_dacl, nullptr);
  if (set_parent_error != ERROR_SUCCESS) {
    return Fail(L"Could not install permissive test parent DACL", set_parent_error);
  }

  DWORD world_sid_size = 0;
  ::CreateWellKnownSid(WinWorldSid, nullptr, nullptr, &world_sid_size);
  if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER || world_sid_size == 0) {
    return Fail(L"Could not size Everyone SID");
  }
  std::vector<std::uint8_t> world_sid_storage(world_sid_size);
  PSID world_sid = world_sid_storage.data();
  if (!::CreateWellKnownSid(WinWorldSid, nullptr, world_sid, &world_sid_size)) {
    return Fail(L"Could not create Everyone SID");
  }

  ScopedHandle inherited(::CreateFileW(
      directory.control_file().c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (inherited.get() == INVALID_HANDLE_VALUE) {
    return Fail(L"Could not create ACL inheritance control file");
  }
  if (!InspectFileDacl(directory.control_file(), world_sid, nullptr, false)) {
    return false;
  }

  std::vector<std::uint8_t> current_user_storage;
  PSID current_user_sid = nullptr;
  if (!CaptureCurrentUserSid(&current_user_storage, &current_user_sid)) {
    return Fail(L"Could not capture current user SID");
  }

  // Match the final receive-directory handle used by production: relative
  // creation requires FILE_ADD_FILE, and concurrent receives need write sharing.
  ScopedHandle parent(::CreateFileW(
      directory.path().c_str(),
      FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_TRAVERSE |
          FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  if (parent.get() == INVALID_HANDLE_VALUE) {
    return Fail(L"Could not open test parent directory");
  }

  HANDLE private_raw = nullptr;
  const landrop::ReceiveEntryCreateResult created =
      landrop::CreatePrivateReceiveEntryRelative(parent.get(), L"private.txt",
                                                &private_raw);
  if (created.kind != landrop::ReceiveEntryCreateKind::kSuccess) {
    return Fail(L"Could not create private receive-file test entry",
                created.error);
  }
  ScopedHandle private_file(private_raw);
  if (!InspectFileDacl(directory.private_file(), world_sid,
                       current_user_sid, true)) {
    return false;
  }
  return TestLegacyPartialRepair(directory, world_sid, current_user_sid);
}

}  // namespace

int wmain() {
  if (!RunTest()) return 1;
  std::wcout << L"Windows new and resumed receive ACLs are protected and owner-only.\n";
  return 0;
}
