#include "secure_fs.h"

#include <windows.h>
#include <winternl.h>

#include <algorithm>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <new>
#include <sstream>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

constexpr ULONG kFileOpen = 1;
constexpr ULONG kFileCreate = 2;
constexpr ULONG kFileDirectoryFile = 0x00000001;
constexpr ULONG kFileSynchronousIoNonalert = 0x00000020;
constexpr ULONG kFileNonDirectoryFile = 0x00000040;
constexpr ULONG kFileOpenReparsePoint = 0x00200000;
constexpr ULONG kObjectCaseInsensitive = 0x00000040;
// Parent and leaf handles intentionally deny concurrent write/delete opens:
// rename, replacement, or reparse-point mutation must not race this walk.
constexpr ULONG kPinnedShare = FILE_SHARE_READ;
constexpr ACCESS_MASK kDirectoryAccess =
    FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
constexpr ULONG kShareAll =
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
// FILE_ID_INFO is the layout returned by FileIdInfo (class value 18).
struct NativeFileIdInfo {
  ULONGLONG volume_serial_number;
  BYTE file_id[16];
};
static_assert(sizeof(NativeFileIdInfo) == 24, "Unexpected FileIdInfo layout");
constexpr FILE_INFO_BY_HANDLE_CLASS kFileIdInfoClass =
    static_cast<FILE_INFO_BY_HANDLE_CLASS>(18);

const NTSTATUS kStatusObjectNameNotFound = static_cast<NTSTATUS>(0xC0000034L);
const NTSTATUS kStatusObjectPathNotFound = static_cast<NTSTATUS>(0xC000003AL);
const NTSTATUS kStatusNoSuchFile = static_cast<NTSTATUS>(0xC000000FL);
const NTSTATUS kStatusFileIsADirectory = static_cast<NTSTATUS>(0xC00000BAL);
const NTSTATUS kStatusNotADirectory = static_cast<NTSTATUS>(0xC0000103L);

using NtCreateFileFunction = NTSTATUS(NTAPI*)(
    PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK, PLARGE_INTEGER,
    ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);

enum class ResultKind { kSuccess, kUnsafePath, kIoFailure };

struct SecureFsResult {
  ResultKind kind;
  DWORD native_error = ERROR_SUCCESS;
};

SecureFsResult Success() { return {ResultKind::kSuccess, ERROR_SUCCESS}; }
SecureFsResult UnsafePath() { return {ResultKind::kUnsafePath, ERROR_SUCCESS}; }
SecureFsResult IoFailure(DWORD error) {
  return {ResultKind::kIoFailure, error};
}

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = nullptr) : handle_(handle) {}
  ~ScopedHandle() { Close(); }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  ScopedHandle(ScopedHandle&& other) noexcept : handle_(other.Release()) {}
  ScopedHandle& operator=(ScopedHandle&& other) noexcept {
    if (this != &other) {
      Close();
      handle_ = other.Release();
    }
    return *this;
  }

  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE Release() {
    HANDLE handle = handle_;
    handle_ = nullptr;
    return handle;
  }

  void Close() {
    if (valid()) ::CloseHandle(handle_);
    handle_ = nullptr;
  }

  HANDLE handle_ = nullptr;
};

bool IsMissing(NTSTATUS status) {
  return status == kStatusObjectNameNotFound ||
         status == kStatusObjectPathNotFound || status == kStatusNoSuchFile;
}

bool IsStatusSuccess(NTSTATUS status) { return status >= 0; }

bool IsAsciiLetter(wchar_t value) {
  return (value >= L'A' && value <= L'Z') ||
         (value >= L'a' && value <= L'z');
}

bool IsControl(wchar_t value) {
  return value <= 0x001F || (value >= 0x007F && value <= 0x009F);
}

bool IsForbiddenWindowsNameCharacter(wchar_t value) {
  return value == L'<' || value == L'>' || value == L':' || value == L'"' ||
         value == L'|' || value == L'?' || value == L'*';
}

bool IsSafePathComponent(const std::wstring& component) {
  if (component.empty() || component == L"." || component == L".." ||
      component.size() > 255 || component.back() == L'.' ||
      component.back() == L' ') {
    return false;
  }
  for (wchar_t value : component) {
    if (value == L'\0' || value == L'/' || value == L'\\' ||
        IsControl(value) || IsForbiddenWindowsNameCharacter(value)) {
      return false;
    }
  }
  return true;
}

bool IsUuidPageId(const std::wstring& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != L'-') return false;
      continue;
    }
    const wchar_t digit = value[i];
    if (!((digit >= L'0' && digit <= L'9') ||
          (digit >= L'a' && digit <= L'f') ||
          (digit >= L'A' && digit <= L'F'))) {
      return false;
    }
  }
  return true;
}

bool IsReceiveEntryLeaf(const std::wstring& value) {
  return value.size() == 42 && value[0] == L'.' &&
         value.compare(37, 5, L".part") == 0 &&
         IsUuidPageId(value.substr(1, 36));
}

bool IsSafeReceiveEntryName(const std::wstring& value) {
  return IsReceiveEntryLeaf(value) || IsSafePathComponent(value);
}

bool SplitLocalDriveRootedPath(const std::wstring& path,
                               std::wstring* drive_root,
                               std::vector<std::wstring>* components,
                               bool require_page_uuid) {
  if (path.size() < 3 || path.size() > 32767 || !IsAsciiLetter(path[0]) ||
      path[1] != L':' || path[2] != L'\\' ||
      path.find(L'\0') != std::wstring::npos ||
      path.find(L'/') != std::wstring::npos) {
    return false;
  }

  std::wstring parsed = path;
  if (parsed.size() > 3 && parsed.back() == L'\\') {
    if (parsed[parsed.size() - 2] == L'\\') return false;
    parsed.pop_back();
  }
  *drive_root = parsed.substr(0, 3);
  size_t position = 3;
  while (position < parsed.size()) {
    const size_t end = parsed.find(L'\\', position);
    const size_t component_end =
        end == std::wstring::npos ? parsed.size() : end;
    std::wstring component =
        parsed.substr(position, component_end - position);
    if (!IsSafePathComponent(component)) return false;
    components->push_back(std::move(component));
    if (end == std::wstring::npos) break;
    position = end + 1;
  }
  return !components->empty() &&
         (!require_page_uuid || IsUuidPageId(components->back()));
}

bool IsValidDateDirectory(const std::wstring& value) {
  if (value.empty()) return true;
  if (value.size() != 10 || value[4] != L'-' || value[7] != L'-') {
    return false;
  }
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 4 || i == 7) continue;
    if (value[i] < L'0' || value[i] > L'9') return false;
  }
  const int year = (value[0] - L'0') * 1000 + (value[1] - L'0') * 100 +
                   (value[2] - L'0') * 10 + (value[3] - L'0');
  const int month = (value[5] - L'0') * 10 + (value[6] - L'0');
  const int day = (value[8] - L'0') * 10 + (value[9] - L'0');
  if (year == 0 || month < 1 || month > 12) return false;
  static constexpr int kDaysPerMonth[] =
      {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  int max_day = kDaysPerMonth[month - 1];
  const bool leap_year = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  if (month == 2 && leap_year) ++max_day;
  return day >= 1 && day <= max_day;
}

bool Utf8ToWide(const std::string& input, std::wstring* output) {
  if (input.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  if (input.empty()) {
    output->clear();
    return true;
  }
  const int input_length = static_cast<int>(input.size());
  const int wide_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), input_length, nullptr, 0);
  if (wide_length <= 0) return false;
  output->resize(static_cast<size_t>(wide_length));
  return ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                               input_length, output->data(), wide_length) ==
         wide_length;
}

NtCreateFileFunction GetNtCreateFile() {
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return nullptr;
  return reinterpret_cast<NtCreateFileFunction>(
      ::GetProcAddress(ntdll, "NtCreateFile"));
}

NTSTATUS OpenRelative(
    NtCreateFileFunction nt_create_file, HANDLE parent,
    const std::wstring& component, bool directory, HANDLE* output,
    ACCESS_MASK leaf_access = DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE) {
  if (!nt_create_file || component.empty() ||
      component.size() > std::numeric_limits<USHORT>::max() / sizeof(wchar_t)) {
    return static_cast<NTSTATUS>(0xC000000DL);  // STATUS_INVALID_PARAMETER
  }
  UNICODE_STRING name = {};
  name.Buffer = const_cast<PWSTR>(component.c_str());
  name.Length = static_cast<USHORT>(component.size() * sizeof(wchar_t));
  name.MaximumLength = name.Length;

  OBJECT_ATTRIBUTES attributes = {};
  attributes.Length = static_cast<ULONG>(sizeof(attributes));
  attributes.RootDirectory = parent;
  attributes.ObjectName = &name;
  attributes.Attributes = kObjectCaseInsensitive;

  IO_STATUS_BLOCK io_status = {};
  const ACCESS_MASK access = directory ? kDirectoryAccess : leaf_access;
  const ULONG options = kFileOpenReparsePoint | kFileSynchronousIoNonalert |
                        (directory ? kFileDirectoryFile
                                   : kFileNonDirectoryFile);
  return nt_create_file(output, access, &attributes, &io_status, nullptr,
                        FILE_ATTRIBUTE_NORMAL, kPinnedShare, kFileOpen, options,
                        nullptr, 0);
}

NTSTATUS CreateReceiveEntryRelative(NtCreateFileFunction nt_create_file,
                                    HANDLE parent,
                                    const std::wstring& component,
                                    HANDLE* output) {
  if (!nt_create_file || component.empty() ||
      component.size() > std::numeric_limits<USHORT>::max() / sizeof(wchar_t)) {
    return static_cast<NTSTATUS>(0xC000000DL);  // STATUS_INVALID_PARAMETER
  }
  UNICODE_STRING name = {};
  name.Buffer = const_cast<PWSTR>(component.c_str());
  name.Length = static_cast<USHORT>(component.size() * sizeof(wchar_t));
  name.MaximumLength = name.Length;

  OBJECT_ATTRIBUTES attributes = {};
  attributes.Length = static_cast<ULONG>(sizeof(attributes));
  attributes.RootDirectory = parent;
  attributes.ObjectName = &name;
  attributes.Attributes = kObjectCaseInsensitive;

  IO_STATUS_BLOCK io_status = {};
  const ULONG options = kFileOpenReparsePoint | kFileSynchronousIoNonalert |
                        kFileNonDirectoryFile;
  return nt_create_file(
      output, DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_DATA | SYNCHRONIZE,
      &attributes, &io_status, nullptr, FILE_ATTRIBUTE_NORMAL, kPinnedShare,
      kFileCreate, options, nullptr, 0);
}

bool IsSafeDirectoryHandle(HANDLE handle, SecureFsResult* failure) {
  BY_HANDLE_FILE_INFORMATION information = {};
  if (!::GetFileInformationByHandle(handle, &information)) {
    *failure = IoFailure(::GetLastError());
    return false;
  }
  if ((information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    *failure = UnsafePath();
    return false;
  }
  return true;
}

bool IsRegularLeafHandle(HANDLE handle, SecureFsResult* failure) {
  BY_HANDLE_FILE_INFORMATION information = {};
  if (!::GetFileInformationByHandle(handle, &information)) {
    *failure = IoFailure(::GetLastError());
    return false;
  }
  if ((information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    *failure = UnsafePath();
    return false;
  }
  return true;
}

bool ReadHandleIdentity(HANDLE handle, std::string* identity,
                        SecureFsResult* failure) {
  NativeFileIdInfo information = {};
  if (!::GetFileInformationByHandleEx(
          handle, kFileIdInfoClass, &information,
          static_cast<DWORD>(sizeof(information)))) {
    *failure = IoFailure(::GetLastError());
    return false;
  }

  std::ostringstream encoded;
  encoded << std::hex << std::nouppercase << std::setfill('0')
          << std::setw(16)
          << static_cast<unsigned long long>(information.volume_serial_number)
          << ':';
  for (BYTE value : information.file_id) {
    encoded << std::setw(2) << static_cast<unsigned int>(value);
  }
  *identity = encoded.str();
  return true;
}

SecureFsResult OpenReceiveDirectories(
    const std::wstring& root, const std::wstring& relative_parent,
    std::vector<ScopedHandle>* directory_handles, std::string* root_identity,
    std::string* parent_identity, bool* has_parent_identity) {
  std::wstring drive_root;
  std::vector<std::wstring> root_components;
  if (!SplitLocalDriveRootedPath(root, &drive_root, &root_components, true) ||
      !IsValidDateDirectory(relative_parent)) {
    return UnsafePath();
  }
  *root_identity = {};
  *parent_identity = {};
  *has_parent_identity = false;

  const UINT drive_type = ::GetDriveTypeW(drive_root.c_str());
  if (drive_type == DRIVE_REMOTE || drive_type == DRIVE_UNKNOWN ||
      drive_type == DRIVE_NO_ROOT_DIR) {
    return UnsafePath();
  }

  directory_handles->clear();
  ScopedHandle drive_handle(::CreateFileW(
      drive_root.c_str(), kDirectoryAccess,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!drive_handle.valid()) return IoFailure(::GetLastError());
  // Keep the newly opened handle owned locally until vector growth succeeds.
  directory_handles->push_back(std::move(drive_handle));

  SecureFsResult handle_failure = UnsafePath();
  if (!IsSafeDirectoryHandle(directory_handles->back().get(), &handle_failure)) {
    return handle_failure;
  }
  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  for (const std::wstring& component : root_components) {
    HANDLE child_raw = nullptr;
    const NTSTATUS status = OpenRelative(
        nt_create_file, directory_handles->back().get(), component, true,
        &child_raw);
    ScopedHandle child(child_raw);
    // A missing canonical root is not an idempotent unlink: Dart may have
    // validated another directory object which was moved or replaced.
    if (!IsStatusSuccess(status)) {
      return IoFailure(static_cast<DWORD>(status));
    }
    if (!child.valid()) return IoFailure(ERROR_INVALID_HANDLE);
    if (!IsSafeDirectoryHandle(child.get(), &handle_failure)) {
      return handle_failure;
    }
    directory_handles->push_back(std::move(child));
  }

  if (!ReadHandleIdentity(directory_handles->back().get(), root_identity,
                             &handle_failure)) {
    return handle_failure;
  }
  if (!relative_parent.empty()) {
    HANDLE date_raw = nullptr;
    const NTSTATUS status = OpenRelative(
        nt_create_file, directory_handles->back().get(), relative_parent, true,
        &date_raw);
    ScopedHandle date_directory(date_raw);
    if (!IsStatusSuccess(status)) {
      return IoFailure(static_cast<DWORD>(status));
    }
    if (!date_directory.valid()) return IoFailure(ERROR_INVALID_HANDLE);
    if (!IsSafeDirectoryHandle(date_directory.get(), &handle_failure)) {
      return handle_failure;
    }
    directory_handles->push_back(std::move(date_directory));
    if (!ReadHandleIdentity(directory_handles->back().get(), parent_identity,
                               &handle_failure)) {
      return handle_failure;
    }
    *has_parent_identity = true;
  }
  return Success();
}

SecureFsResult OpenVerifiedReceiveDirectories(
    const std::wstring& root, const std::wstring& relative_parent,
    const std::string& expected_root_identity,
    bool has_expected_parent_identity,
    const std::string& expected_parent_identity,
    std::vector<ScopedHandle>* directory_handles) {
  std::string root_identity;
  std::string parent_identity;
  bool has_parent_identity = false;
  const SecureFsResult opened = OpenReceiveDirectories(
      root, relative_parent, directory_handles, &root_identity, &parent_identity,
      &has_parent_identity);
  if (opened.kind != ResultKind::kSuccess) return opened;
  if (root_identity != expected_root_identity ||
      has_parent_identity != has_expected_parent_identity ||
      (has_parent_identity && parent_identity != expected_parent_identity)) {
    return UnsafePath();
  }
  return Success();
}

SecureFsResult OpenManagedDirectory(
    const std::wstring& root, std::vector<ScopedHandle>* directory_handles,
    std::string* root_identity) {
  std::wstring drive_root;
  std::vector<std::wstring> root_components;
  if (!SplitLocalDriveRootedPath(root, &drive_root, &root_components, false)) {
    return UnsafePath();
  }
  root_identity->clear();

  const UINT drive_type = ::GetDriveTypeW(drive_root.c_str());
  if (drive_type == DRIVE_REMOTE || drive_type == DRIVE_UNKNOWN ||
      drive_type == DRIVE_NO_ROOT_DIR) {
    return UnsafePath();
  }

  directory_handles->clear();
  ScopedHandle drive_handle(::CreateFileW(
      drive_root.c_str(), kDirectoryAccess,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!drive_handle.valid()) return IoFailure(::GetLastError());
  // Keep the newly opened handle owned locally until vector growth succeeds.
  directory_handles->push_back(std::move(drive_handle));

  SecureFsResult handle_failure = UnsafePath();
  if (!IsSafeDirectoryHandle(directory_handles->back().get(), &handle_failure)) {
    return handle_failure;
  }
  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  for (const std::wstring& component : root_components) {
    HANDLE child_raw = nullptr;
    const NTSTATUS status = OpenRelative(
        nt_create_file, directory_handles->back().get(), component, true,
        &child_raw);
    ScopedHandle child(child_raw);
    if (!IsStatusSuccess(status)) {
      return IoFailure(static_cast<DWORD>(status));
    }
    if (!child.valid()) return IoFailure(ERROR_INVALID_HANDLE);
    if (!IsSafeDirectoryHandle(child.get(), &handle_failure)) {
      return handle_failure;
    }
    directory_handles->push_back(std::move(child));
  }
  if (!ReadHandleIdentity(directory_handles->back().get(), root_identity,
                             &handle_failure)) {
    return handle_failure;
  }
  return Success();
}

SecureFsResult CaptureManagedFileLeafIdentity(
    const std::wstring& root, const std::wstring& leaf,
    const std::string& expected_root_identity, std::string* leaf_identity) {
  if (!IsUuidPageId(leaf)) return UnsafePath();

  std::vector<ScopedHandle> directory_handles;
  std::string root_identity;
  const SecureFsResult opened =
      OpenManagedDirectory(root, &directory_handles, &root_identity);
  if (opened.kind != ResultKind::kSuccess) return opened;
  if (root_identity != expected_root_identity) return UnsafePath();

  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = OpenRelative(
      nt_create_file, directory_handles.back().get(), leaf, false, &leaf_raw);
  ScopedHandle file(leaf_raw);
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);

  SecureFsResult handle_failure = UnsafePath();
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  if (!ReadHandleIdentity(file.get(), leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  return Success();
}

SecureFsResult ReadManagedFileChunk(
    const std::wstring& root, const std::wstring& leaf,
    const std::string& expected_root_identity,
    const std::string& expected_leaf_identity, int64_t offset,
    int64_t max_bytes, std::vector<std::uint8_t>* bytes, int64_t* file_length,
    int64_t* modified_time_micros) {
  constexpr int64_t kMaxChunkBytes = 1024 * 1024;
  if (!IsUuidPageId(leaf) || offset < 0 || max_bytes < 1 ||
      max_bytes > kMaxChunkBytes ||
      offset > std::numeric_limits<int64_t>::max() - max_bytes) {
    return UnsafePath();
  }

  std::vector<ScopedHandle> directory_handles;
  std::string root_identity;
  const SecureFsResult opened =
      OpenManagedDirectory(root, &directory_handles, &root_identity);
  if (opened.kind != ResultKind::kSuccess) return opened;
  if (root_identity != expected_root_identity) return UnsafePath();

  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = OpenRelative(
      nt_create_file, directory_handles.back().get(), leaf, false, &leaf_raw,
      FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE);
  ScopedHandle file(leaf_raw);
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);

  SecureFsResult handle_failure = UnsafePath();
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  std::string leaf_identity;
  if (!ReadHandleIdentity(file.get(), &leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  if (leaf_identity != expected_leaf_identity) return UnsafePath();

  BY_HANDLE_FILE_INFORMATION information = {};
  if (!::GetFileInformationByHandle(file.get(), &information)) {
    return IoFailure(::GetLastError());
  }
  const ULONGLONG unsigned_length =
      (static_cast<ULONGLONG>(information.nFileSizeHigh) << 32) |
      information.nFileSizeLow;
  if (unsigned_length >
      static_cast<ULONGLONG>(std::numeric_limits<int64_t>::max())) {
    return IoFailure(ERROR_FILE_TOO_LARGE);
  }
  *file_length = static_cast<int64_t>(unsigned_length);
  const ULONGLONG modified_ticks =
      (static_cast<ULONGLONG>(information.ftLastWriteTime.dwHighDateTime)
       << 32) |
      information.ftLastWriteTime.dwLowDateTime;
  constexpr int64_t kWindowsToUnixEpochMicros = 11644473600000000LL;
  *modified_time_micros =
      static_cast<int64_t>(modified_ticks / 10) -
      kWindowsToUnixEpochMicros;

  bytes->clear();
  if (offset < *file_length) {
    const int64_t available = *file_length - offset;
    const int64_t count = std::min(max_bytes, available);
    bytes->resize(static_cast<size_t>(count));
    LARGE_INTEGER position = {};
    position.QuadPart = offset;
    if (!::SetFilePointerEx(file.get(), position, nullptr, FILE_BEGIN)) {
      return IoFailure(::GetLastError());
    }
    DWORD bytes_read = 0;
    if (!::ReadFile(file.get(), bytes->data(), static_cast<DWORD>(count),
                    &bytes_read, nullptr)) {
      return IoFailure(::GetLastError());
    }
    bytes->resize(bytes_read);
  }

  // Detect a concurrent change while reading, even if this filesystem permits
  // a writer despite the pinned share mode. Keep the initial values as the
  // snapshot returned to the caller only when the handle remains unchanged.
  std::string final_leaf_identity;
  if (!ReadHandleIdentity(file.get(), &final_leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  BY_HANDLE_FILE_INFORMATION final_information = {};
  if (!::GetFileInformationByHandle(file.get(), &final_information)) {
    return IoFailure(::GetLastError());
  }
  const ULONGLONG final_unsigned_length =
      (static_cast<ULONGLONG>(final_information.nFileSizeHigh) << 32) |
      final_information.nFileSizeLow;
  if (final_leaf_identity != leaf_identity ||
      final_unsigned_length != unsigned_length ||
      final_information.ftLastWriteTime.dwHighDateTime !=
          information.ftLastWriteTime.dwHighDateTime ||
      final_information.ftLastWriteTime.dwLowDateTime !=
          information.ftLastWriteTime.dwLowDateTime) {
    return IoFailure(ERROR_FILE_INVALID);
  }
  return Success();
}

SecureFsResult UnlinkManagedFile(
    const std::wstring& root, const std::wstring& leaf,
    const std::string& expected_root_identity,
    const std::string& expected_leaf_identity) {
  if (!IsUuidPageId(leaf)) return UnsafePath();

  std::vector<ScopedHandle> directory_handles;
  std::string root_identity;
  const SecureFsResult opened =
      OpenManagedDirectory(root, &directory_handles, &root_identity);
  if (opened.kind != ResultKind::kSuccess) return opened;
  // Do not inspect the leaf until the opened directory is confirmed to be the
  // same managed directory whose identity was captured by the caller.
  if (root_identity != expected_root_identity) return UnsafePath();

  SecureFsResult handle_failure = UnsafePath();
  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = OpenRelative(
      nt_create_file, directory_handles.back().get(), leaf, false, &leaf_raw);
  ScopedHandle file(leaf_raw);
  if (IsMissing(leaf_status)) return Success();
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  std::string leaf_identity;
  if (!ReadHandleIdentity(file.get(), &leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  if (leaf_identity != expected_leaf_identity) return UnsafePath();

  FILE_DISPOSITION_INFO disposition = {};
  disposition.DeleteFile = static_cast<BOOLEAN>(TRUE);
  if (!::SetFileInformationByHandle(file.get(), FileDispositionInfo,
                                    &disposition,
                                    static_cast<DWORD>(sizeof(disposition)))) {
    return IoFailure(::GetLastError());
  }
  return Success();
}

SecureFsResult CreateReceiveEntry(
    const std::wstring& root, const std::wstring& relative_parent,
    const std::wstring& leaf, const std::string& expected_root_identity,
    bool has_expected_parent_identity,
    const std::string& expected_parent_identity, std::string* leaf_identity) {
  if (!IsSafeReceiveEntryName(leaf)) return UnsafePath();

  std::vector<ScopedHandle> directory_handles;
  const SecureFsResult opened = OpenVerifiedReceiveDirectories(
      root, relative_parent, expected_root_identity,
      has_expected_parent_identity, expected_parent_identity,
      &directory_handles);
  if (opened.kind != ResultKind::kSuccess) return opened;

  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = CreateReceiveEntryRelative(
      nt_create_file, directory_handles.back().get(), leaf, &leaf_raw);
  ScopedHandle file(leaf_raw);
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);

  SecureFsResult handle_failure = UnsafePath();
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  if (!ReadHandleIdentity(file.get(), leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  return Success();
}

SecureFsResult CaptureReceiveEntryIdentity(
    const std::wstring& root, const std::wstring& relative_parent,
    const std::wstring& leaf, const std::string& expected_root_identity,
    bool has_expected_parent_identity,
    const std::string& expected_parent_identity, std::string* leaf_identity) {
  if (!IsReceiveEntryLeaf(leaf)) return UnsafePath();

  std::vector<ScopedHandle> directory_handles;
  const SecureFsResult opened = OpenVerifiedReceiveDirectories(
      root, relative_parent, expected_root_identity,
      has_expected_parent_identity, expected_parent_identity,
      &directory_handles);
  if (opened.kind != ResultKind::kSuccess) return opened;

  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = OpenRelative(
      nt_create_file, directory_handles.back().get(), leaf, false, &leaf_raw);
  ScopedHandle file(leaf_raw);
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);

  SecureFsResult handle_failure = UnsafePath();
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  if (!ReadHandleIdentity(file.get(), leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  return Success();
}

SecureFsResult UnlinkReceiveEntry(
    const std::wstring& root, const std::wstring& relative_parent,
    const std::wstring& leaf, const std::string& expected_root_identity,
    bool has_expected_parent_identity,
    const std::string& expected_parent_identity,
    const std::string& expected_leaf_identity) {
  if (!IsSafeReceiveEntryName(leaf)) return UnsafePath();

  std::vector<ScopedHandle> directory_handles;
  const SecureFsResult opened = OpenVerifiedReceiveDirectories(
      root, relative_parent, expected_root_identity,
      has_expected_parent_identity, expected_parent_identity,
      &directory_handles);
  if (opened.kind != ResultKind::kSuccess) return opened;

  SecureFsResult handle_failure = UnsafePath();
  NtCreateFileFunction nt_create_file = GetNtCreateFile();
  if (!nt_create_file) return IoFailure(ERROR_PROC_NOT_FOUND);
  HANDLE leaf_raw = nullptr;
  const NTSTATUS leaf_status = OpenRelative(
      nt_create_file, directory_handles.back().get(), leaf, false, &leaf_raw);
  ScopedHandle file(leaf_raw);
  if (IsMissing(leaf_status)) return Success();
  if (!IsStatusSuccess(leaf_status)) {
    if (leaf_status == kStatusFileIsADirectory ||
        leaf_status == kStatusNotADirectory) {
      return UnsafePath();
    }
    return IoFailure(static_cast<DWORD>(leaf_status));
  }
  if (!file.valid()) return IoFailure(ERROR_INVALID_HANDLE);
  if (!IsRegularLeafHandle(file.get(), &handle_failure)) return handle_failure;
  std::string leaf_identity;
  if (!ReadHandleIdentity(file.get(), &leaf_identity, &handle_failure)) {
    return handle_failure;
  }
  if (leaf_identity != expected_leaf_identity) return UnsafePath();

  FILE_DISPOSITION_INFO disposition = {};
  disposition.DeleteFile = static_cast<BOOLEAN>(TRUE);
  if (!::SetFileInformationByHandle(file.get(), FileDispositionInfo,
                                    &disposition,
                                    static_cast<DWORD>(sizeof(disposition)))) {
    return IoFailure(::GetLastError());
  }
  return Success();
}

const flutter::EncodableValue* FindValue(
    const flutter::EncodableMap& arguments, const char* key) {
  const auto entry = arguments.find(flutter::EncodableValue(key));
  return entry == arguments.end() ? nullptr : &entry->second;
}

const std::string* FindString(const flutter::EncodableMap& arguments,
                              const char* key) {
  const flutter::EncodableValue* value = FindValue(arguments, key);
  return value ? std::get_if<std::string>(value) : nullptr;
}

bool FindInteger(const flutter::EncodableMap& arguments, const char* key,
                 int64_t* output) {
  const flutter::EncodableValue* value = FindValue(arguments, key);
  if (!value) return false;
  if (const int64_t* integer = std::get_if<int64_t>(value)) {
    *output = *integer;
    return true;
  }
  if (const int32_t* integer = std::get_if<int32_t>(value)) {
    *output = *integer;
    return true;
  }
  return false;
}

bool IsCanonicalIdentityToken(const std::string& value) {
  if (value.size() != 49 || value[16] != ':') return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 16) continue;
    const char digit = value[i];
    if (!((digit >= '0' && digit <= '9') ||
          (digit >= 'a' && digit <= 'f'))) {
      return false;
    }
  }
  return true;
}

void CompleteOperationError(
    const SecureFsResult& operation,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  if (operation.kind == ResultKind::kUnsafePath) {
    result->Error("unsafe_path", "The target is not a safe local file entry.");
  } else {
    result->Error("io_error", "Secure file operation failed (native error " +
                                   std::to_string(operation.native_error) +").");
  }
}

using SecureFsMethodResult =
    flutter::MethodResult<flutter::EncodableValue>;

struct CaptureIdentityWork {
  std::wstring root;
  std::wstring relative_parent;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct ReceiveEntryIdentityWork {
  std::wstring root;
  std::wstring relative_parent;
  std::wstring leaf;
  std::string expected_root_identity;
  bool has_expected_parent_identity = false;
  std::string expected_parent_identity;
  bool create = false;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct UnlinkEntryWork {
  std::wstring root;
  std::wstring relative_parent;
  std::wstring leaf;
  std::string expected_root_identity;
  bool has_expected_parent_identity = false;
  std::string expected_parent_identity;
  std::string expected_leaf_identity;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct CaptureManagedIdentityWork {
  std::wstring root;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct CaptureManagedFileLeafIdentityWork {
  std::wstring root;
  std::wstring leaf;
  std::string expected_root_identity;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct UnlinkManagedFileWork {
  std::wstring root;
  std::wstring leaf;
  std::string expected_root_identity;
  std::string expected_leaf_identity;
  std::unique_ptr<SecureFsMethodResult> result;
};

struct ReadManagedFileChunkWork {
  std::wstring root;
  std::wstring leaf;
  std::string expected_root_identity;
  std::string expected_leaf_identity;
  int64_t offset = 0;
  int64_t max_bytes = 0;
  std::unique_ptr<SecureFsMethodResult> result;
};

DWORD WINAPI CaptureIdentityWorker(void* context) {
  std::unique_ptr<CaptureIdentityWork> work(
      static_cast<CaptureIdentityWork*>(context));
  try {
    std::vector<ScopedHandle> directory_handles;
    std::string root_identity;
    std::string parent_identity;
    bool has_parent_identity = false;
    const SecureFsResult operation = OpenReceiveDirectories(
        work->root, work->relative_parent, &directory_handles, &root_identity,
        &parent_identity, &has_parent_identity);
    if (operation.kind != ResultKind::kSuccess) {
      CompleteOperationError(operation, work->result.get());
      return 0;
    }

    flutter::EncodableMap identity;
    identity.emplace(flutter::EncodableValue("rootIdentity"),
                     flutter::EncodableValue(root_identity));
    identity.emplace(
        flutter::EncodableValue("parentIdentity"),
        has_parent_identity ? flutter::EncodableValue(parent_identity)
                            : flutter::EncodableValue());
    work->result->Success(flutter::EncodableValue(std::move(identity)));
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI ReceiveEntryIdentityWorker(void* context) {
  std::unique_ptr<ReceiveEntryIdentityWork> work(
      static_cast<ReceiveEntryIdentityWork*>(context));
  try {
    std::string leaf_identity;
    const SecureFsResult operation = work->create
        ? CreateReceiveEntry(
              work->root, work->relative_parent, work->leaf,
              work->expected_root_identity,
              work->has_expected_parent_identity,
              work->expected_parent_identity, &leaf_identity)
        : CaptureReceiveEntryIdentity(
              work->root, work->relative_parent, work->leaf,
              work->expected_root_identity,
              work->has_expected_parent_identity,
              work->expected_parent_identity, &leaf_identity);
    if (operation.kind != ResultKind::kSuccess) {
      CompleteOperationError(operation, work->result.get());
      return 0;
    }

    flutter::EncodableMap identity;
    identity.emplace(flutter::EncodableValue("leafIdentity"),
                     flutter::EncodableValue(std::move(leaf_identity)));
    work->result->Success(flutter::EncodableValue(std::move(identity)));
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI UnlinkEntryWorker(void* context) {
  std::unique_ptr<UnlinkEntryWork> work(
      static_cast<UnlinkEntryWork*>(context));
  try {
    const SecureFsResult operation = UnlinkReceiveEntry(
        work->root, work->relative_parent, work->leaf,
        work->expected_root_identity, work->has_expected_parent_identity,
        work->expected_parent_identity, work->expected_leaf_identity);
    if (operation.kind == ResultKind::kSuccess) {
      work->result->Success();
    } else {
      CompleteOperationError(operation, work->result.get());
    }
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI CaptureManagedIdentityWorker(void* context) {
  std::unique_ptr<CaptureManagedIdentityWork> work(
      static_cast<CaptureManagedIdentityWork*>(context));
  try {
    std::vector<ScopedHandle> directory_handles;
    std::string root_identity;
    const SecureFsResult operation =
        OpenManagedDirectory(work->root, &directory_handles, &root_identity);
    if (operation.kind != ResultKind::kSuccess) {
      CompleteOperationError(operation, work->result.get());
      return 0;
    }

    flutter::EncodableMap identity;
    identity.emplace(flutter::EncodableValue("rootIdentity"),
                     flutter::EncodableValue(root_identity));
    work->result->Success(flutter::EncodableValue(std::move(identity)));
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI CaptureManagedFileLeafIdentityWorker(void* context) {
  std::unique_ptr<CaptureManagedFileLeafIdentityWork> work(
      static_cast<CaptureManagedFileLeafIdentityWork*>(context));
  try {
    std::string leaf_identity;
    const SecureFsResult operation = CaptureManagedFileLeafIdentity(
        work->root, work->leaf, work->expected_root_identity, &leaf_identity);
    if (operation.kind != ResultKind::kSuccess) {
      CompleteOperationError(operation, work->result.get());
      return 0;
    }

    flutter::EncodableMap identity;
    identity.emplace(flutter::EncodableValue("leafIdentity"),
                     flutter::EncodableValue(std::move(leaf_identity)));
    work->result->Success(flutter::EncodableValue(std::move(identity)));
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI UnlinkManagedFileWorker(void* context) {
  std::unique_ptr<UnlinkManagedFileWork> work(
      static_cast<UnlinkManagedFileWork*>(context));
  try {
    const SecureFsResult operation = UnlinkManagedFile(
        work->root, work->leaf, work->expected_root_identity,
        work->expected_leaf_identity);
    if (operation.kind == ResultKind::kSuccess) {
      work->result->Success();
    } else {
      CompleteOperationError(operation, work->result.get());
    }
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

DWORD WINAPI ReadManagedFileChunkWorker(void* context) {
  std::unique_ptr<ReadManagedFileChunkWork> work(
      static_cast<ReadManagedFileChunkWork*>(context));
  try {
    std::vector<std::uint8_t> bytes;
    int64_t file_length = 0;
    int64_t modified_time_micros = 0;
    const SecureFsResult operation = ReadManagedFileChunk(
        work->root, work->leaf, work->expected_root_identity,
        work->expected_leaf_identity, work->offset, work->max_bytes, &bytes,
        &file_length, &modified_time_micros);
    if (operation.kind != ResultKind::kSuccess) {
      CompleteOperationError(operation, work->result.get());
      return 0;
    }

    flutter::EncodableMap chunk;
    chunk.emplace(flutter::EncodableValue("bytes"),
                  flutter::EncodableValue(std::move(bytes)));
    chunk.emplace(flutter::EncodableValue("fileLength"),
                  flutter::EncodableValue(file_length));
    chunk.emplace(flutter::EncodableValue("modifiedTimeMicros"),
                  flutter::EncodableValue(modified_time_micros));
    work->result->Success(flutter::EncodableValue(std::move(chunk)));
  } catch (...) {
    work->result->Error("io_error", "Secure file operation failed.");
  }
  return 0;
}

}  // namespace

void HandleSecureFileSystemMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool capture_managed =
      call.method_name() == "captureManagedFileDirectoryIdentity";
  const bool capture_managed_leaf =
      call.method_name() == "captureManagedFileLeafIdentity";
  const bool read_managed =
      call.method_name() == "readManagedFileChunk";
  const bool unlink_managed = call.method_name() == "unlinkManagedFile";
  const bool capture =
      call.method_name() == "captureReceiveDirectoryIdentity";
  const bool create_entry = call.method_name() == "createReceiveEntry";
  const bool capture_entry =
      call.method_name() == "captureReceiveEntryIdentity";
  const bool unlink = call.method_name() == "unlinkReceiveEntry";
  if (!capture_managed && !capture_managed_leaf && !read_managed &&
      !unlink_managed && !capture && !create_entry && !capture_entry &&
      !unlink) {
    result->NotImplemented();
    return;
  }

  if (capture_managed || capture_managed_leaf || read_managed ||
      unlink_managed) {
    const auto* arguments =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    const std::string* root_utf8 =
        arguments ? FindString(*arguments, "root") : nullptr;
    if (!root_utf8) {
      result->Error("invalid_arguments", "Expected string argument root.");
      return;
    }

    std::wstring root;
    if (!Utf8ToWide(*root_utf8, &root)) {
      result->Error("invalid_arguments", "Root must be a valid UTF-8 string.");
      return;
    }

    if (capture_managed) {
      auto* work = new (std::nothrow) CaptureManagedIdentityWork{
          std::move(root), std::move(result)};
      if (!work) {
        result->Error("io_error", "Could not start secure file operation.");
        return;
      }
      if (!::QueueUserWorkItem(CaptureManagedIdentityWorker, work,
                               WT_EXECUTELONGFUNCTION)) {
        std::unique_ptr<CaptureManagedIdentityWork> failed_work(work);
        failed_work->result->Error("io_error",
                                   "Could not start secure file operation.");
      }
      return;
    }

    const std::string* leaf_utf8 =
        arguments ? FindString(*arguments, "leaf") : nullptr;
    const std::string* expected_root_identity =
        arguments ? FindString(*arguments, "expectedRootIdentity") : nullptr;
    const std::string* expected_leaf_identity =
        (unlink_managed || read_managed)
            ? (arguments ? FindString(*arguments, "expectedLeafIdentity")
                         : nullptr)
            : nullptr;
    int64_t offset = 0;
    int64_t max_bytes = 0;
    const bool valid_chunk_range =
        !read_managed ||
        (arguments && FindInteger(*arguments, "offset", &offset) &&
         FindInteger(*arguments, "maxBytes", &max_bytes) && offset >= 0 &&
         max_bytes >= 1 && max_bytes <= 1024 * 1024 &&
         offset <= std::numeric_limits<int64_t>::max() - max_bytes);
    if (!leaf_utf8 || !expected_root_identity ||
        !IsCanonicalIdentityToken(*expected_root_identity) ||
        ((unlink_managed || read_managed) &&
         (!expected_leaf_identity ||
          !IsCanonicalIdentityToken(*expected_leaf_identity))) ||
        !valid_chunk_range) {
      result->Error("invalid_arguments",
                    "Expected UUID, identity, and valid chunk range arguments.");
      return;
    }

    std::wstring leaf;
    if (!Utf8ToWide(*leaf_utf8, &leaf) || !IsUuidPageId(leaf)) {
      result->Error("invalid_arguments", "Leaf must be a UUID.");
      return;
    }

    if (capture_managed_leaf) {
      CaptureManagedFileLeafIdentityWork* work = nullptr;
      try {
        work = new (std::nothrow) CaptureManagedFileLeafIdentityWork{
            std::move(root), std::move(leaf), *expected_root_identity,
            std::move(result)};
      } catch (...) {
        result->Error("io_error", "Could not start secure file operation.");
        return;
      }
      if (!work) {
        result->Error("io_error", "Could not start secure file operation.");
        return;
      }
      if (!::QueueUserWorkItem(CaptureManagedFileLeafIdentityWorker, work,
                               WT_EXECUTELONGFUNCTION)) {
        std::unique_ptr<CaptureManagedFileLeafIdentityWork> failed_work(work);
        failed_work->result->Error("io_error",
                                   "Could not start secure file operation.");
      }
      return;
    }

    if (read_managed) {
      ReadManagedFileChunkWork* work = nullptr;
      try {
        work = new (std::nothrow) ReadManagedFileChunkWork{
            std::move(root), std::move(leaf), *expected_root_identity,
            *expected_leaf_identity, offset, max_bytes, std::move(result)};
      } catch (...) {
        result->Error("io_error", "Could not start secure file operation.");
        return;
      }
      if (!work) {
        result->Error("io_error", "Could not start secure file operation.");
        return;
      }
      if (!::QueueUserWorkItem(ReadManagedFileChunkWorker, work,
                               WT_EXECUTELONGFUNCTION)) {
        std::unique_ptr<ReadManagedFileChunkWork> failed_work(work);
        failed_work->result->Error("io_error",
                                   "Could not start secure file operation.");
      }
      return;
    }

    UnlinkManagedFileWork* work = nullptr;
    try {
      work = new (std::nothrow) UnlinkManagedFileWork{
          std::move(root), std::move(leaf), *expected_root_identity,
          *expected_leaf_identity, std::move(result)};
    } catch (...) {
      result->Error("io_error", "Could not start secure file operation.");
      return;
    }
    if (!work) {
      result->Error("io_error", "Could not start secure file operation.");
      return;
    }
    if (!::QueueUserWorkItem(UnlinkManagedFileWorker, work,
                             WT_EXECUTELONGFUNCTION)) {
      std::unique_ptr<UnlinkManagedFileWork> failed_work(work);
      failed_work->result->Error("io_error",
                                 "Could not start secure file operation.");
    }
    return;
  }

  const auto* arguments =
      call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments())
          : nullptr;
  const std::string* root_utf8 =
      arguments ? FindString(*arguments, "root") : nullptr;
  const std::string* parent_utf8 =
      arguments ? FindString(*arguments, "relativeParent") : nullptr;
  if (!root_utf8 || !parent_utf8) {
    result->Error("invalid_arguments",
                  "Expected string arguments root and relativeParent.");
    return;
  }

  std::wstring root;
  std::wstring relative_parent;
  if (!Utf8ToWide(*root_utf8, &root) ||
      !Utf8ToWide(*parent_utf8, &relative_parent)) {
    result->Error("invalid_arguments", "Arguments must be valid UTF-8 strings.");
    return;
  }

  if (create_entry || capture_entry) {
    const std::string* leaf_utf8 =
        arguments ? FindString(*arguments, "leaf") : nullptr;
    const std::string* expected_root_identity =
        arguments ? FindString(*arguments, "expectedRootIdentity") : nullptr;
    const flutter::EncodableValue* expected_parent_value =
        arguments ? FindValue(*arguments, "expectedParentIdentity") : nullptr;
    const std::string* expected_parent_identity = expected_parent_value
        ? std::get_if<std::string>(expected_parent_value)
        : nullptr;
    const bool expected_parent_is_null =
        expected_parent_value &&
        std::holds_alternative<std::monostate>(*expected_parent_value);
    if (!leaf_utf8 || !expected_root_identity ||
        !IsCanonicalIdentityToken(*expected_root_identity) ||
        !expected_parent_value ||
        (!expected_parent_identity && !expected_parent_is_null) ||
        (expected_parent_identity &&
         !IsCanonicalIdentityToken(*expected_parent_identity))) {
      result->Error("invalid_arguments",
                    "Expected leaf and directory identity arguments.");
      return;
    }

    std::wstring leaf;
    if (!Utf8ToWide(*leaf_utf8, &leaf) ||
        (create_entry ? !IsSafeReceiveEntryName(leaf)
                      : !IsReceiveEntryLeaf(leaf))) {
      result->Error(
          "invalid_arguments",
          create_entry
              ? "Leaf must be a safe basename or .UUID.part receive entry."
              : "Leaf must be a .UUID.part receive entry.");
      return;
    }

    ReceiveEntryIdentityWork* work = nullptr;
    try {
      work = new (std::nothrow) ReceiveEntryIdentityWork{
          std::move(root),
          std::move(relative_parent),
          std::move(leaf),
          *expected_root_identity,
          expected_parent_identity != nullptr,
          expected_parent_identity ? *expected_parent_identity : std::string(),
          create_entry,
          std::move(result)};
    } catch (...) {
      result->Error("io_error", "Could not start secure file operation.");
      return;
    }
    if (!work) {
      result->Error("io_error", "Could not start secure file operation.");
      return;
    }
    if (!::QueueUserWorkItem(ReceiveEntryIdentityWorker, work,
                             WT_EXECUTELONGFUNCTION)) {
      std::unique_ptr<ReceiveEntryIdentityWork> failed_work(work);
      failed_work->result->Error("io_error",
                                 "Could not start secure file operation.");
    }
    return;
  }

  if (capture) {
    auto* work = new (std::nothrow) CaptureIdentityWork{
        std::move(root), std::move(relative_parent), std::move(result)};
    if (!work) {
      result->Error("io_error", "Could not start secure file operation.");
      return;
    }
    if (!::QueueUserWorkItem(CaptureIdentityWorker, work,
                             WT_EXECUTELONGFUNCTION)) {
      std::unique_ptr<CaptureIdentityWork> failed_work(work);
      failed_work->result->Error("io_error",
                                 "Could not start secure file operation.");
    }
    return;
  }

  const std::string* leaf_utf8 =
      arguments ? FindString(*arguments, "leaf") : nullptr;
  const std::string* expected_root_identity =
      arguments ? FindString(*arguments, "expectedRootIdentity") : nullptr;
  const flutter::EncodableValue* expected_parent_value =
      arguments ? FindValue(*arguments, "expectedParentIdentity") : nullptr;
  const std::string* expected_leaf_identity =
      arguments ? FindString(*arguments, "expectedLeafIdentity") : nullptr;
  const std::string* expected_parent_identity = expected_parent_value
      ? std::get_if<std::string>(expected_parent_value)
      : nullptr;
  const bool expected_parent_is_null =
      expected_parent_value &&
      std::holds_alternative<std::monostate>(*expected_parent_value);
  if (!leaf_utf8 || !expected_root_identity || !expected_leaf_identity ||
      !IsCanonicalIdentityToken(*expected_root_identity) ||
      !IsCanonicalIdentityToken(*expected_leaf_identity) ||
      !expected_parent_value ||
      (!expected_parent_identity && !expected_parent_is_null) ||
      (expected_parent_identity &&
       !IsCanonicalIdentityToken(*expected_parent_identity))) {
    result->Error("invalid_arguments",
                  "Expected leaf and directory identity arguments.");
    return;
  }

  std::wstring leaf;
  if (!Utf8ToWide(*leaf_utf8, &leaf) || !IsSafeReceiveEntryName(leaf)) {
    result->Error("invalid_arguments",
                  "Leaf must be a safe basename or .UUID.part receive entry.");
    return;
  }

  UnlinkEntryWork* work = nullptr;
  try {
    work = new (std::nothrow) UnlinkEntryWork{
        std::move(root),
        std::move(relative_parent),
        std::move(leaf),
        *expected_root_identity,
        expected_parent_identity != nullptr,
        expected_parent_identity ? *expected_parent_identity : std::string(),
        *expected_leaf_identity,
        std::move(result)};
  } catch (...) {
    result->Error("io_error", "Could not start secure file operation.");
    return;
  }
  if (!work) {
    result->Error("io_error", "Could not start secure file operation.");
    return;
  }
  if (!::QueueUserWorkItem(UnlinkEntryWorker, work, WT_EXECUTELONGFUNCTION)) {
    std::unique_ptr<UnlinkEntryWork> failed_work(work);
    failed_work->result->Error("io_error",
                               "Could not start secure file operation.");
  }
}
