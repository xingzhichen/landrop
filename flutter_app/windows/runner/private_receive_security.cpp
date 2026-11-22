#include "private_receive_security.h"

#include <aclapi.h>

#include <limits>

namespace landrop {
namespace {

class ScopedToken {
 public:
  explicit ScopedToken(HANDLE handle) : handle_(handle) {}
  ~ScopedToken() {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      ::CloseHandle(handle_);
    }
  }

  ScopedToken(const ScopedToken&) = delete;
  ScopedToken& operator=(const ScopedToken&) = delete;

  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_;
};

class ScopedSecurityDescriptor {
 public:
  explicit ScopedSecurityDescriptor(PSECURITY_DESCRIPTOR descriptor)
      : descriptor_(descriptor) {}
  ~ScopedSecurityDescriptor() {
    if (descriptor_ != nullptr) ::LocalFree(descriptor_);
  }

  ScopedSecurityDescriptor(const ScopedSecurityDescriptor&) = delete;
  ScopedSecurityDescriptor& operator=(const ScopedSecurityDescriptor&) = delete;

 private:
  PSECURITY_DESCRIPTOR descriptor_;
};

constexpr ACCESS_MASK kPrivateReceiveFileAccess =
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE | READ_CONTROL;

bool IsPrivateReceiveDacl(PSID owner, PACL dacl,
                          PSECURITY_DESCRIPTOR descriptor) {
  if (owner == nullptr || dacl == nullptr || descriptor == nullptr) return false;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!::GetSecurityDescriptorControl(descriptor, &control, &revision) ||
      (control & SE_DACL_PROTECTED) == 0) {
    return false;
  }

  ACL_SIZE_INFORMATION acl_info = {};
  if (!::GetAclInformation(dacl, &acl_info, sizeof(acl_info),
                           AclSizeInformation) ||
      acl_info.AceCount != 1) {
    return false;
  }
  void* raw_ace = nullptr;
  if (!::GetAce(dacl, 0, &raw_ace) || raw_ace == nullptr) return false;
  const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
  if (header->AceType != ACCESS_ALLOWED_ACE_TYPE || header->AceFlags != 0) {
    return false;
  }
  const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
  return ace->Mask == kPrivateReceiveFileAccess &&
         ::EqualSid(const_cast<DWORD*>(&ace->SidStart), owner);
}

}  // namespace

DWORD InitializePrivateReceiveSecurity(PrivateReceiveSecurity* security) {
  if (security == nullptr) return ERROR_INVALID_PARAMETER;

  HANDLE token_raw = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token_raw)) {
    return ::GetLastError();
  }
  ScopedToken token(token_raw);

  DWORD token_user_size = 0;
  if (::GetTokenInformation(token.get(), TokenUser, nullptr, 0,
                            &token_user_size)) {
    return ERROR_INVALID_DATA;
  }
  const DWORD size_error = ::GetLastError();
  if (size_error != ERROR_INSUFFICIENT_BUFFER ||
      token_user_size < sizeof(TOKEN_USER)) {
    return size_error == ERROR_SUCCESS ? ERROR_INVALID_DATA : size_error;
  }
  security->token_user_storage.resize(token_user_size);
  if (!::GetTokenInformation(token.get(), TokenUser,
                             security->token_user_storage.data(),
                             token_user_size, &token_user_size)) {
    return ::GetLastError();
  }

  const auto* token_user = reinterpret_cast<const TOKEN_USER*>(
      security->token_user_storage.data());
  PSID user_sid = token_user->User.Sid;
  if (!::IsValidSid(user_sid)) return ERROR_INVALID_SID;
  const DWORD sid_size = ::GetLengthSid(user_sid);
  if (sid_size == 0) return ERROR_INVALID_SID;

  const size_t acl_size = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) +
                          static_cast<size_t>(sid_size);
  if (acl_size > std::numeric_limits<DWORD>::max()) {
    return ERROR_ARITHMETIC_OVERFLOW;
  }
  security->acl_storage.resize(acl_size);
  PACL acl = reinterpret_cast<PACL>(security->acl_storage.data());
  if (!::InitializeAcl(acl, static_cast<DWORD>(acl_size), ACL_REVISION)) {
    return ::GetLastError();
  }

  if (!::AddAccessAllowedAceEx(acl, ACL_REVISION, 0,
                               kPrivateReceiveFileAccess, user_sid)) {
    return ::GetLastError();
  }
  if (!::InitializeSecurityDescriptor(&security->descriptor,
                                      SECURITY_DESCRIPTOR_REVISION)) {
    return ::GetLastError();
  }
  if (!::SetSecurityDescriptorOwner(&security->descriptor, user_sid, FALSE)) {
    return ::GetLastError();
  }
  if (!::SetSecurityDescriptorDacl(&security->descriptor, TRUE, acl, FALSE)) {
    return ::GetLastError();
  }
  if (!::SetSecurityDescriptorControl(&security->descriptor, SE_DACL_PROTECTED,
                                      SE_DACL_PROTECTED)) {
    return ::GetLastError();
  }
  return ERROR_SUCCESS;
}

DWORD EnsurePrivateReceiveFileDacl(HANDLE file) {
  if (file == nullptr || file == INVALID_HANDLE_VALUE) {
    return ERROR_INVALID_HANDLE;
  }

  PrivateReceiveSecurity desired_security;
  DWORD error = InitializePrivateReceiveSecurity(&desired_security);
  if (error != ERROR_SUCCESS) return error;

  PSID expected_owner = nullptr;
  BOOL owner_defaulted = FALSE;
  if (!::GetSecurityDescriptorOwner(&desired_security.descriptor,
                                    &expected_owner, &owner_defaulted)) {
    const DWORD owner_error = ::GetLastError();
    return owner_error == ERROR_SUCCESS ? ERROR_INVALID_OWNER : owner_error;
  }
  if (expected_owner == nullptr) return ERROR_INVALID_OWNER;

  BOOL dacl_present = FALSE;
  BOOL dacl_defaulted = FALSE;
  PACL desired_dacl = nullptr;
  if (!::GetSecurityDescriptorDacl(&desired_security.descriptor, &dacl_present,
                                   &desired_dacl, &dacl_defaulted)) {
    const DWORD dacl_error = ::GetLastError();
    return dacl_error == ERROR_SUCCESS ? ERROR_INVALID_ACL : dacl_error;
  }
  if (!dacl_present || desired_dacl == nullptr) return ERROR_INVALID_ACL;

  PSID existing_owner = nullptr;
  PACL existing_dacl = nullptr;
  PSECURITY_DESCRIPTOR existing_descriptor_raw = nullptr;
  error = ::GetSecurityInfo(file, SE_FILE_OBJECT,
                            OWNER_SECURITY_INFORMATION |
                                DACL_SECURITY_INFORMATION,
                            &existing_owner, nullptr, &existing_dacl, nullptr,
                            &existing_descriptor_raw);
  if (error != ERROR_SUCCESS) return error;
  ScopedSecurityDescriptor existing_descriptor(existing_descriptor_raw);
  if (existing_owner == nullptr || !::EqualSid(existing_owner, expected_owner)) {
    return ERROR_ACCESS_DENIED;
  }
  if (IsPrivateReceiveDacl(existing_owner, existing_dacl,
                           existing_descriptor_raw)) {
    return ERROR_SUCCESS;
  }

  error = ::SetSecurityInfo(file, SE_FILE_OBJECT,
                            DACL_SECURITY_INFORMATION |
                                PROTECTED_DACL_SECURITY_INFORMATION,
                            nullptr, nullptr, desired_dacl, nullptr);
  if (error != ERROR_SUCCESS) return error;

  PSID verified_owner = nullptr;
  PACL verified_dacl = nullptr;
  PSECURITY_DESCRIPTOR verified_descriptor_raw = nullptr;
  error = ::GetSecurityInfo(file, SE_FILE_OBJECT,
                            OWNER_SECURITY_INFORMATION |
                                DACL_SECURITY_INFORMATION,
                            &verified_owner, nullptr, &verified_dacl, nullptr,
                            &verified_descriptor_raw);
  if (error != ERROR_SUCCESS) return error;
  ScopedSecurityDescriptor verified_descriptor(verified_descriptor_raw);
  if (verified_owner == nullptr ||
      !::EqualSid(verified_owner, expected_owner) ||
      !IsPrivateReceiveDacl(verified_owner, verified_dacl,
                            verified_descriptor_raw)) {
    return ERROR_INVALID_ACL;
  }
  return ERROR_SUCCESS;
}

}  // namespace landrop
