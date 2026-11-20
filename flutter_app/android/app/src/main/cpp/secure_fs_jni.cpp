#include <jni.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <dirent.h>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static_assert(sizeof(off_t) >= sizeof(int64_t),
              "Android secure filesystem requires 64-bit file offsets");

namespace {

class ScopedFd {
 public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ~ScopedFd() { reset(); }

  ScopedFd(const ScopedFd&) = delete;
  ScopedFd& operator=(const ScopedFd&) = delete;

  ScopedFd(ScopedFd&& other) noexcept : fd_(other.release()) {}
  ScopedFd& operator=(ScopedFd&& other) noexcept {
    if (this != &other) {
      reset();
      fd_ = other.release();
    }
    return *this;
  }

  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }

 private:
  int release() {
    const int released = fd_;
    fd_ = -1;
    return released;
  }

  void reset() {
    if (fd_ >= 0) {
      const int saved_errno = errno;
      (void)::close(fd_);
      errno = saved_errno;
      fd_ = -1;
    }
  }

  int fd_;
};

bool appendUtf8(JNIEnv* env, jstring value, std::string* output) {
  if (value == nullptr || output == nullptr) return false;
  const jsize length = env->GetStringLength(value);
  const jchar* chars = env->GetStringChars(value, nullptr);
  if (chars == nullptr) return false;
  struct ScopedChars {
    JNIEnv* env;
    jstring value;
    const jchar* chars;
    ~ScopedChars() { env->ReleaseStringChars(value, chars); }
  } chars_guard{env, value, chars};

  bool valid = true;
  for (jsize index = 0; index < length; ++index) {
    uint32_t code_point = chars[index];
    if (code_point >= 0xd800 && code_point <= 0xdbff) {
      if (index + 1 >= length) {
        valid = false;
        break;
      }
      const uint32_t low = chars[index + 1];
      if (low < 0xdc00 || low > 0xdfff) {
        valid = false;
        break;
      }
      code_point = 0x10000 + ((code_point - 0xd800) << 10) + (low - 0xdc00);
      ++index;
    } else if (code_point >= 0xdc00 && code_point <= 0xdfff) {
      valid = false;
      break;
    }

    if (code_point == 0 || code_point < 0x20 ||
        (code_point >= 0x7f && code_point <= 0x9f)) {
      valid = false;
      break;
    }
    if (code_point <= 0x7f) {
      output->push_back(static_cast<char>(code_point));
    } else if (code_point <= 0x7ff) {
      output->push_back(static_cast<char>(0xc0 | (code_point >> 6)));
      output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
    } else if (code_point <= 0xffff) {
      output->push_back(static_cast<char>(0xe0 | (code_point >> 12)));
      output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
      output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
    } else {
      output->push_back(static_cast<char>(0xf0 | (code_point >> 18)));
      output->push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3f)));
      output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
      output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
    }
  }
  return valid;
}

bool isDateComponent(const std::string& value) {
  if (value.size() != 10 || value[4] != '-' || value[7] != '-') return false;
  for (size_t index = 0; index < value.size(); ++index) {
    if (index == 4 || index == 7) continue;
    if (value[index] < '0' || value[index] > '9') return false;
  }
  const int year = (value[0] - '0') * 1000 + (value[1] - '0') * 100 +
                   (value[2] - '0') * 10 + (value[3] - '0');
  const int month = (value[5] - '0') * 10 + (value[6] - '0');
  const int day = (value[8] - '0') * 10 + (value[9] - '0');
  if (year == 0 || month < 1 || month > 12) return false;
  static constexpr int kDaysPerMonth[] =
      {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  int maximum_day = kDaysPerMonth[month - 1];
  const bool leap_year = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  if (month == 2 && leap_year) ++maximum_day;
  return day >= 1 && day <= maximum_day;
}

bool isUuidComponent(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t index = 0; index < value.size(); ++index) {
    const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
    const char byte = value[index];
    if (separator) {
      if (byte != '-') return false;
    } else if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') ||
                 (byte >= 'A' && byte <= 'F'))) {
      return false;
    }
  }
  return true;
}

bool isSafeLeaf(const std::string& value) {
  if (value.empty() || value == "." || value == "..") return false;
  for (const unsigned char byte : value) {
    if (byte == '/' || byte == '\\') return false;
  }
  return true;
}

bool isUuidPartLeaf(const std::string& value) {
  // .<8-4-4-4-12 hexadecimal UUID>.part; only the UUID hex is case-insensitive.
  if (value.size() != 42 || value[0] != '.' || value.compare(37, 5, ".part") != 0) {
    return false;
  }
  for (size_t index = 1; index <= 36; ++index) {
    const bool separator = index == 9 || index == 14 || index == 19 || index == 24;
    const char byte = value[index];
    if (separator) {
      if (byte != '-') return false;
    } else if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') ||
                 (byte >= 'A' && byte <= 'F'))) {
      return false;
    }
  }
  return true;
}

bool rootComponents(const std::string& root, std::vector<std::string>* components) {
  if (root.empty() || root[0] != '/' || root.find("//") != std::string::npos ||
      root.back() == '/' || components == nullptr) {
    return false;
  }
  size_t start = 1;
  while (start < root.size()) {
    const size_t slash = root.find('/', start);
    const size_t end = slash == std::string::npos ? root.size() : slash;
    if (end > start) {
      std::string component = root.substr(start, end - start);
      if (component == "." || component == "..") return false;
      for (const unsigned char byte : component) {
        if (byte < 0x20 || byte == 0x7f) return false;
      }
      components->push_back(std::move(component));
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return !components->empty() && isUuidComponent(components->back());
}

bool managedRootComponents(const std::string& root,
                          std::vector<std::string>* components) {
  if (root.empty() || root == "/" || root[0] != '/' ||
      root.find("//") != std::string::npos || root.back() == '/' ||
      components == nullptr) {
    return false;
  }
  size_t start = 1;
  while (start < root.size()) {
    const size_t slash = root.find('/', start);
    const size_t end = slash == std::string::npos ? root.size() : slash;
    if (end == start) return false;
    std::string component = root.substr(start, end - start);
    if (component == "." || component == "..") return false;
    for (const unsigned char byte : component) {
      if (byte < 0x20 || byte == 0x7f) return false;
    }
    components->push_back(std::move(component));
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return !components->empty();
}

struct SecureFsDirectories {
  ScopedFd root_fd;
  ScopedFd parent_fd;
  bool has_parent = false;

  int target_fd() const { return has_parent ? parent_fd.get() : root_fd.get(); }
};

bool parseUnsignedDecimal(const std::string& value, size_t begin, size_t end,
                          unsigned long long* parsed) {
  if (parsed == nullptr || begin >= end) return false;
  unsigned long long result = 0;
  for (size_t index = begin; index < end; ++index) {
    const char byte = value[index];
    if (byte < '0' || byte > '9') return false;
    const unsigned int digit = static_cast<unsigned int>(byte - '0');
    if (result > (ULLONG_MAX - digit) / 10) return false;
    result = result * 10 + digit;
  }
  *parsed = result;
  return true;
}

bool parseIdentityString(const std::string& value, unsigned long long* device,
                         unsigned long long* inode) {
  if (value.compare(0, 4, "dev=") != 0) return false;
  const size_t separator = value.find(";ino=", 4);
  if (separator == std::string::npos || separator == 4 || separator + 5 >= value.size()) {
    return false;
  }
  return parseUnsignedDecimal(value, 4, separator, device) &&
         parseUnsignedDecimal(value, separator + 5, value.size(), inode);
}

bool isIdentityString(const std::string& value) {
  unsigned long long device = 0;
  unsigned long long inode = 0;
  return parseIdentityString(value, &device, &inode);
}

std::string formatFileIdentity(dev_t device, ino_t inode) {
  return "dev=" + std::to_string(static_cast<unsigned long long>(device)) +
         ";ino=" + std::to_string(static_cast<unsigned long long>(inode));
}

bool identityMatchesStat(const std::string& expected, const struct stat& value) {
  unsigned long long expected_device = 0;
  unsigned long long expected_inode = 0;
  return parseIdentityString(expected, &expected_device, &expected_inode) &&
         expected_device == static_cast<unsigned long long>(value.st_dev) &&
         expected_inode == static_cast<unsigned long long>(value.st_ino);
}

int openReceiveDirectories(const std::string& root, const std::string& relative_parent,
                           SecureFsDirectories* directories) {
  std::vector<std::string> components;
  if (directories == nullptr || !rootComponents(root, &components) ||
      (!relative_parent.empty() && !isDateComponent(relative_parent))) {
    return EINVAL;
  }

  const int directory_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  directories->root_fd = ScopedFd(::open("/", directory_flags));
  if (!directories->root_fd.valid()) return errno;
  for (const std::string& component : components) {
    ScopedFd next_fd(::openat(directories->root_fd.get(), component.c_str(), directory_flags));
    if (!next_fd.valid()) return errno;
    directories->root_fd = std::move(next_fd);
  }

  if (!relative_parent.empty()) {
    directories->parent_fd = ScopedFd(
        ::openat(directories->root_fd.get(), relative_parent.c_str(), directory_flags));
    if (!directories->parent_fd.valid()) return errno;
    directories->has_parent = true;
  }
  return 0;
}

int openManagedDirectory(const std::string& root, ScopedFd* root_fd) {
  std::vector<std::string> components;
  if (root_fd == nullptr || !managedRootComponents(root, &components)) return EINVAL;

  const int directory_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  ScopedFd current_fd(::open("/", directory_flags));
  if (!current_fd.valid()) return errno;
  for (const std::string& component : components) {
    ScopedFd next_fd(::openat(current_fd.get(), component.c_str(), directory_flags));
    if (!next_fd.valid()) return errno;
    struct stat component_stat {};
    if (::fstat(next_fd.get(), &component_stat) != 0) return errno;
    if (!S_ISDIR(component_stat.st_mode)) return ENOTDIR;
    current_fd = std::move(next_fd);
  }
  *root_fd = std::move(current_fd);
  return 0;
}

int readDirectoryIdentity(int fd, std::string* identity) {
  if (identity == nullptr) return EINVAL;
  struct stat directory_stat {};
  if (::fstat(fd, &directory_stat) != 0) return errno;
  if (!S_ISDIR(directory_stat.st_mode)) return ENOTDIR;
  *identity = formatFileIdentity(directory_stat.st_dev, directory_stat.st_ino);
  return 0;
}

int validateReceiveDirectoryIdentities(const SecureFsDirectories& directories,
                                       const std::string& expected_root_identity,
                                       const std::string* expected_parent_identity) {
  if (!isIdentityString(expected_root_identity) ||
      (directories.has_parent != (expected_parent_identity != nullptr)) ||
      (expected_parent_identity != nullptr && !isIdentityString(*expected_parent_identity))) {
    return EINVAL;
  }

  std::string actual_root_identity;
  int error_number = readDirectoryIdentity(directories.root_fd.get(), &actual_root_identity);
  if (error_number != 0) return error_number;
  if (actual_root_identity != expected_root_identity) return EINVAL;
  if (directories.has_parent) {
    std::string actual_parent_identity;
    error_number = readDirectoryIdentity(directories.parent_fd.get(), &actual_parent_identity);
    if (error_number != 0) return error_number;
    if (actual_parent_identity != *expected_parent_identity) return EINVAL;
  }
  return 0;
}

int captureReceiveDirectoryIdentity(const std::string& root, const std::string& relative_parent,
                                   std::string* root_identity,
                                   std::string* parent_identity) {
  if (root_identity == nullptr || parent_identity == nullptr) return EINVAL;
  SecureFsDirectories directories;
  const int open_error = openReceiveDirectories(root, relative_parent, &directories);
  if (open_error != 0) return open_error;
  int error_number = readDirectoryIdentity(directories.root_fd.get(), root_identity);
  if (error_number != 0) return error_number;
  if (directories.has_parent) {
    error_number = readDirectoryIdentity(directories.parent_fd.get(), parent_identity);
    if (error_number != 0) return error_number;
  } else {
    parent_identity->clear();
  }
  return 0;
}

int createReceiveEntry(const std::string& root, const std::string& relative_parent,
                       const std::string& leaf, const std::string& expected_root_identity,
                       const std::string* expected_parent_identity,
                       std::string* leaf_identity) {
  if (!(isUuidPartLeaf(leaf) || isSafeLeaf(leaf)) || leaf_identity == nullptr) {
    return EINVAL;
  }

  SecureFsDirectories directories;
  int error_number = openReceiveDirectories(root, relative_parent, &directories);
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(
      directories, expected_root_identity, expected_parent_identity);
  if (error_number != 0) return error_number;

  ScopedFd entry_fd(::openat(directories.target_fd(), leaf.c_str(),
                             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                             0600));
  if (!entry_fd.valid()) return errno;
  if (::fchmod(entry_fd.get(), 0600) != 0) return errno;

  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode)) return EINVAL;
  *leaf_identity = formatFileIdentity(entry_stat.st_dev, entry_stat.st_ino);
  return 0;
}

int captureReceiveEntryIdentity(const std::string& root, const std::string& relative_parent,
                                const std::string& leaf,
                                const std::string& expected_root_identity,
                                const std::string* expected_parent_identity,
                                std::string* leaf_identity) {
  if (!isUuidPartLeaf(leaf) || leaf_identity == nullptr) return EINVAL;

  SecureFsDirectories directories;
  int error_number = openReceiveDirectories(root, relative_parent, &directories);
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(
      directories, expected_root_identity, expected_parent_identity);
  if (error_number != 0) return error_number;

  // O_NONBLOCK avoids hanging if the leaf was replaced with a FIFO before this open.
  ScopedFd entry_fd(::openat(directories.target_fd(), leaf.c_str(),
                             O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (!entry_fd.valid()) return errno;
  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode)) return EINVAL;
  *leaf_identity = formatFileIdentity(entry_stat.st_dev, entry_stat.st_ino);
  return 0;
}

int renameNoReplace(int old_directory_fd, const char* old_leaf,
                     int new_directory_fd, const char* new_leaf) {
#if defined(SYS_renameat2)
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif
  if (::syscall(SYS_renameat2, old_directory_fd, old_leaf, new_directory_fd,
                new_leaf, RENAME_NOREPLACE) == 0) {
    return 0;
  }
  return errno;
#else
  (void)old_directory_fd;
  (void)old_leaf;
  (void)new_directory_fd;
  (void)new_leaf;
  return ENOSYS;
#endif
}

int ensureQuarantineRoot(int root_fd, ScopedFd* quarantine_root_fd) {
  if (quarantine_root_fd == nullptr) return EINVAL;
  static constexpr char kQuarantineDirectory[] = ".landrop-quarantine";
  if (::mkdirat(root_fd, kQuarantineDirectory, 0700) != 0 && errno != EEXIST) {
    return errno;
  }

  ScopedFd opened(::openat(root_fd, kQuarantineDirectory,
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!opened.valid()) return errno;
  struct stat root_stat {};
  struct stat quarantine_root_stat {};
  if (::fstat(root_fd, &root_stat) != 0) return errno;
  if (::fstat(opened.get(), &quarantine_root_stat) != 0) return errno;
  if (!S_ISDIR(quarantine_root_stat.st_mode)) return ENOTDIR;
  if (quarantine_root_stat.st_uid != ::geteuid() ||
      quarantine_root_stat.st_dev != root_stat.st_dev) {
    return EACCES;
  }
  if (::fchmod(opened.get(), 0700) != 0) return errno;
  if (::fsync(root_fd) != 0) return errno;
  if (::fsync(opened.get()) != 0) return errno;
  *quarantine_root_fd = std::move(opened);
  return 0;
}

int validatePrivateDirectory(int directory_fd, dev_t expected_device) {
  struct stat directory_stat {};
  if (::fstat(directory_fd, &directory_stat) != 0) return errno;
  if (!S_ISDIR(directory_stat.st_mode)) return ENOTDIR;
  if (directory_stat.st_uid != ::geteuid() || directory_stat.st_dev != expected_device) {
    return EACCES;
  }
  if ((directory_stat.st_mode & 07777) != 0700) return EACCES;
  return 0;
}

int openPinnedQuarantineDirectory(int root_fd, const std::string& session_id,
                                  const std::string& expected_identity,
                                  ScopedFd* session_directory_fd) {
  if (session_directory_fd == nullptr || !isUuidComponent(session_id) ||
      !isIdentityString(expected_identity)) {
    return EINVAL;
  }
  ScopedFd quarantine_root_fd(::openat(root_fd, ".landrop-quarantine",
                                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!quarantine_root_fd.valid()) return errno;
  struct stat root_stat {};
  if (::fstat(root_fd, &root_stat) != 0) return errno;
  int error_number = validatePrivateDirectory(quarantine_root_fd.get(), root_stat.st_dev);
  if (error_number != 0) return error_number;

  ScopedFd session_fd(::openat(quarantine_root_fd.get(), session_id.c_str(),
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!session_fd.valid()) return errno;
  error_number = validatePrivateDirectory(session_fd.get(), root_stat.st_dev);
  if (error_number != 0) return error_number;
  std::string actual_identity;
  error_number = readDirectoryIdentity(session_fd.get(), &actual_identity);
  if (error_number != 0) return error_number;
  if (actual_identity != expected_identity) return EINVAL;
  *session_directory_fd = std::move(session_fd);
  return 0;
}

int isDirectoryEmpty(int directory_fd) {
  const int duplicate_fd = ::dup(directory_fd);
  if (duplicate_fd < 0) return errno;
  DIR* directory = ::fdopendir(duplicate_fd);
  if (directory == nullptr) {
    const int error_number = errno;
    (void)::close(duplicate_fd);
    return error_number;
  }
  errno = 0;
  struct dirent* entry = nullptr;
  while ((entry = ::readdir(directory)) != nullptr) {
    if (std::string(entry->d_name) != "." && std::string(entry->d_name) != "..") {
      (void)::closedir(directory);
      return ENOTEMPTY;
    }
  }
  const int read_error = errno;
  (void)::closedir(directory);
  return read_error;
}

int removeReceiveQuarantine(const std::string& root, const std::string& session_id,
                            const std::string& expected_root_identity,
                            const std::string& expected_quarantine_identity) {
  if (!isUuidComponent(session_id) || !isIdentityString(expected_root_identity) ||
      !isIdentityString(expected_quarantine_identity)) {
    return EINVAL;
  }

  SecureFsDirectories directories;
  int error_number = openReceiveDirectories(root, "", &directories);
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(directories, expected_root_identity,
                                                    nullptr);
  if (error_number != 0) return error_number;

  ScopedFd quarantine_root_fd(::openat(directories.root_fd.get(), ".landrop-quarantine",
                                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!quarantine_root_fd.valid()) return errno;
  struct stat root_stat {};
  if (::fstat(directories.root_fd.get(), &root_stat) != 0) return errno;
  error_number = validatePrivateDirectory(quarantine_root_fd.get(), root_stat.st_dev);
  if (error_number != 0) return error_number;

  ScopedFd session_fd(::openat(quarantine_root_fd.get(), session_id.c_str(),
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!session_fd.valid()) return errno;
  error_number = validatePrivateDirectory(session_fd.get(), root_stat.st_dev);
  if (error_number != 0) return error_number;
  std::string actual_identity;
  error_number = readDirectoryIdentity(session_fd.get(), &actual_identity);
  if (error_number != 0) return error_number;
  if (actual_identity != expected_quarantine_identity) return EINVAL;

  error_number = isDirectoryEmpty(session_fd.get());
  if (error_number != 0) return error_number;

  // Recheck the directory entry before removal so a replacement is not deleted by name.
  struct stat named_session_stat {};
  if (::fstatat(quarantine_root_fd.get(), session_id.c_str(), &named_session_stat,
                AT_SYMLINK_NOFOLLOW) != 0) {
    return errno;
  }
  if (!S_ISDIR(named_session_stat.st_mode) ||
      !identityMatchesStat(expected_quarantine_identity, named_session_stat) ||
      named_session_stat.st_uid != ::geteuid() ||
      named_session_stat.st_dev != root_stat.st_dev ||
      (named_session_stat.st_mode & 07777) != 0700) {
    return EINVAL;
  }
  // unlinkat cannot bind removal to the opened fd; a same-UID rename race remains possible.
  if (::unlinkat(quarantine_root_fd.get(), session_id.c_str(), AT_REMOVEDIR) != 0) {
    return errno;
  }
  if (::fsync(quarantine_root_fd.get()) != 0) return errno;
  return 0;
}

int prepareReceiveQuarantine(const std::string& root,
                             const std::string& relative_parent,
                             const std::string& leaf,
                             const std::string& quarantine_session_id,
                             const std::string& quarantine_leaf,
                             const std::string& expected_root_identity,
                             const std::string* expected_parent_identity,
                             const std::string& expected_leaf_identity,
                             std::string* quarantine_identity) {
  if (!isSafeLeaf(leaf) || !isUuidComponent(quarantine_session_id) ||
      quarantine_leaf != "." + quarantine_session_id + ".quarantine" ||
      !isIdentityString(expected_leaf_identity) ||
      !isIdentityString(expected_root_identity) || quarantine_identity == nullptr ||
      (isUuidPartLeaf(leaf) && leaf.substr(1, 36) != quarantine_session_id) ||
      (relative_parent.empty()
           ? expected_parent_identity != nullptr
           : expected_parent_identity == nullptr ||
                 !isIdentityString(*expected_parent_identity))) {
    return EINVAL;
  }
  SecureFsDirectories directories;
  int error_number = openReceiveDirectories(root, relative_parent, &directories);
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(directories, expected_root_identity,
                                                    expected_parent_identity);
  if (error_number != 0) return error_number;

  struct stat source_stat {};
  if (::fstatat(directories.target_fd(), leaf.c_str(), &source_stat,
                AT_SYMLINK_NOFOLLOW) != 0) {
    return errno;
  }
  if (!S_ISREG(source_stat.st_mode) ||
      !identityMatchesStat(expected_leaf_identity, source_stat)) {
    return EINVAL;
  }

  ScopedFd quarantine_root_fd;
  error_number = ensureQuarantineRoot(directories.root_fd.get(), &quarantine_root_fd);
  if (error_number != 0) return error_number;
  if (::mkdirat(quarantine_root_fd.get(), quarantine_session_id.c_str(), 0700) != 0 &&
      errno != EEXIST) {
    return errno;
  }
  ScopedFd session_fd(::openat(quarantine_root_fd.get(), quarantine_session_id.c_str(),
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!session_fd.valid()) return errno;
  struct stat root_stat {};
  struct stat session_stat {};
  if (::fstat(directories.root_fd.get(), &root_stat) != 0) return errno;
  if (::fstat(session_fd.get(), &session_stat) != 0) return errno;
  if (!S_ISDIR(session_stat.st_mode)) return ENOTDIR;
  if (session_stat.st_uid != ::geteuid() || session_stat.st_dev != root_stat.st_dev) {
    return EACCES;
  }
  if (::fchmod(session_fd.get(), 0700) != 0) return errno;
  error_number = validatePrivateDirectory(session_fd.get(), root_stat.st_dev);
  if (error_number != 0) return error_number;
  error_number = isDirectoryEmpty(session_fd.get());
  if (error_number != 0) return error_number;

  if (::fsync(quarantine_root_fd.get()) != 0) return errno;
  if (::fsync(directories.root_fd.get()) != 0) return errno;
  return readDirectoryIdentity(session_fd.get(), quarantine_identity);
}

int fsyncReceiveDirectories(int source_directory_fd, int quarantine_directory_fd) {
  int first_error = 0;
  if (::fsync(source_directory_fd) != 0) first_error = errno;
  if (::fsync(quarantine_directory_fd) != 0 && first_error == 0) first_error = errno;
  return first_error;
}

int processQuarantinedEntry(int quarantine_fd, const std::string& quarantine_leaf,
                            int source_directory_fd, const std::string& source_leaf,
                            const std::string& expected_leaf_identity) {
  ScopedFd entry_fd(::openat(quarantine_fd, quarantine_leaf.c_str(),
                             O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (!entry_fd.valid()) return errno;
  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode)) return EINVAL;

  if (identityMatchesStat(expected_leaf_identity, entry_stat)) {
    // The fd identity check is not atomic with unlinkat by name; same-UID mutation remains a
    // TOCTOU boundary even though the private directory excludes different UIDs.
    if (::unlinkat(quarantine_fd, quarantine_leaf.c_str(), 0) != 0) return errno;
    if (::fsync(quarantine_fd) != 0) return errno;
    return 0;
  }

  struct stat source_stat {};
  if (::fstatat(source_directory_fd, source_leaf.c_str(), &source_stat,
                AT_SYMLINK_NOFOLLOW) == 0) {
    return EEXIST;
  }
  const int source_stat_error = errno;
  if (source_stat_error != ENOENT) return source_stat_error;

  const int restore_error = renameNoReplace(quarantine_fd, quarantine_leaf.c_str(),
                                            source_directory_fd, source_leaf.c_str());
  if (restore_error != 0) return restore_error;
  const int sync_error = fsyncReceiveDirectories(source_directory_fd, quarantine_fd);
  return sync_error != 0 ? sync_error : EINVAL;
}

bool isValidQuarantineRequest(const std::string& leaf,
                              const std::string& quarantine_session_id,
                              const std::string& quarantine_leaf,
                              const std::string& expected_leaf_identity) {
  return isSafeLeaf(leaf) && isUuidComponent(quarantine_session_id) &&
         quarantine_leaf == "." + quarantine_session_id + ".quarantine" &&
         (!isUuidPartLeaf(leaf) || leaf.substr(1, 36) == quarantine_session_id) &&
         isIdentityString(expected_leaf_identity);
}

int unlinkMatchingQuarantinedEntry(int quarantine_fd,
                                   const std::string& quarantine_leaf,
                                   const std::string& expected_leaf_identity) {
  ScopedFd entry_fd(::openat(quarantine_fd, quarantine_leaf.c_str(),
                             O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (!entry_fd.valid()) {
    const int open_error = errno;
    return open_error == ENOENT ? 0 : open_error;
  }
  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode) ||
      !identityMatchesStat(expected_leaf_identity, entry_stat)) {
    return EINVAL;
  }
  // The fd identity check is not atomic with unlinkat by name; same-UID mutation remains a
  // TOCTOU boundary even though the private directory excludes different UIDs.
  if (::unlinkat(quarantine_fd, quarantine_leaf.c_str(), 0) != 0) return errno;
  if (::fsync(quarantine_fd) != 0) return errno;
  return 0;
}

int unlinkReceiveEntryQuarantinedParentMissing(
    const std::string& root, const std::string& expected_root_identity,
    const std::string& quarantine_session_id, const std::string& quarantine_leaf,
    const std::string& expected_leaf_identity,
    const std::string& expected_quarantine_identity) {
  SecureFsDirectories root_directories;
  int error_number = openReceiveDirectories(root, "", &root_directories);
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(root_directories,
                                                    expected_root_identity, nullptr);
  if (error_number != 0) return error_number;

  ScopedFd quarantine_fd;
  error_number = openPinnedQuarantineDirectory(
      root_directories.root_fd.get(), quarantine_session_id,
      expected_quarantine_identity, &quarantine_fd);
  if (error_number != 0) return error_number;
  // With the source parent gone, mismatched entries cannot be safely restored. Preserve them.
  return unlinkMatchingQuarantinedEntry(quarantine_fd.get(), quarantine_leaf,
                                        expected_leaf_identity);
}

int unlinkReceiveEntryQuarantined(const SecureFsDirectories& directories,
                                  const std::string& leaf,
                                  const std::string& quarantine_session_id,
                                  const std::string& quarantine_leaf,
                                  const std::string& expected_leaf_identity,
                                  const std::string& expected_quarantine_identity) {
  if (!isValidQuarantineRequest(leaf, quarantine_session_id, quarantine_leaf,
                                expected_leaf_identity)) {
    return EINVAL;
  }

  const int source_directory_fd = directories.target_fd();
  ScopedFd quarantine_fd;
  int error_number = openPinnedQuarantineDirectory(
      directories.root_fd.get(), quarantine_session_id, expected_quarantine_identity,
      &quarantine_fd);
  if (error_number != 0) return error_number;
  ScopedFd existing_entry(::openat(quarantine_fd.get(), quarantine_leaf.c_str(),
                                   O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (existing_entry.valid()) {
    existing_entry = ScopedFd();
    return processQuarantinedEntry(quarantine_fd.get(), quarantine_leaf,
                                   source_directory_fd, leaf, expected_leaf_identity);
  }
  error_number = errno;
  if (error_number != ENOENT) return error_number;

  struct stat source_stat {};
  if (::fstatat(source_directory_fd, leaf.c_str(), &source_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    error_number = errno;
    return error_number == ENOENT ? 0 : error_number;
  }

  error_number = renameNoReplace(source_directory_fd, leaf.c_str(),
                                 quarantine_fd.get(), quarantine_leaf.c_str());
  if (error_number == ENOENT) {
    // A concurrent retry may have populated the deterministic quarantine name.
    ScopedFd raced_entry(::openat(quarantine_fd.get(), quarantine_leaf.c_str(),
                                  O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (raced_entry.valid()) {
      raced_entry = ScopedFd();
      return processQuarantinedEntry(quarantine_fd.get(), quarantine_leaf,
                                     source_directory_fd, leaf, expected_leaf_identity);
    }
    const int quarantine_open_error = errno;
    if (quarantine_open_error != ENOENT) return quarantine_open_error;
    if (::fstatat(source_directory_fd, leaf.c_str(), &source_stat, AT_SYMLINK_NOFOLLOW) != 0 &&
        errno == ENOENT) {
      return 0;
    }
    return ENOENT;
  }
  if (error_number != 0) return error_number;

  error_number = fsyncReceiveDirectories(source_directory_fd, quarantine_fd.get());
  if (error_number != 0) return error_number;
  return processQuarantinedEntry(quarantine_fd.get(), quarantine_leaf,
                                 source_directory_fd, leaf, expected_leaf_identity);
}

int unlinkReceiveEntry(const std::string& root, const std::string& relative_parent,
                       const std::string& leaf, const std::string& expected_root_identity,
                       const std::string* expected_parent_identity,
                       const std::string& expected_leaf_identity,
                       const std::string* quarantine_session_id,
                        const std::string* quarantine_leaf,
                       const std::string* expected_quarantine_identity) {
  if (!isSafeLeaf(leaf) || !isIdentityString(expected_leaf_identity)) {
    return EINVAL;
  }
  const bool has_quarantine_request = quarantine_session_id != nullptr &&
                                      quarantine_leaf != nullptr &&
                                      expected_quarantine_identity != nullptr;
  if ((quarantine_session_id != nullptr || quarantine_leaf != nullptr ||
       expected_quarantine_identity != nullptr) && !has_quarantine_request) {
    return EINVAL;
  }
  if (has_quarantine_request &&
      (!isValidQuarantineRequest(leaf, *quarantine_session_id, *quarantine_leaf,
                                 expected_leaf_identity) ||
       !isIdentityString(*expected_quarantine_identity) ||
       !isIdentityString(expected_root_identity) ||
       (relative_parent.empty()
            ? expected_parent_identity != nullptr
            : expected_parent_identity == nullptr ||
                  !isIdentityString(*expected_parent_identity)))) {
    return EINVAL;
  }

  SecureFsDirectories directories;
  int error_number = openReceiveDirectories(root, relative_parent, &directories);
  if (error_number == ENOENT && has_quarantine_request && !relative_parent.empty()) {
    return unlinkReceiveEntryQuarantinedParentMissing(
        root, expected_root_identity, *quarantine_session_id, *quarantine_leaf,
        expected_leaf_identity, *expected_quarantine_identity);
  }
  if (error_number != 0) return error_number;
  error_number = validateReceiveDirectoryIdentities(
      directories, expected_root_identity, expected_parent_identity);
  if (error_number != 0) return error_number;
  if (has_quarantine_request) {
    return unlinkReceiveEntryQuarantined(directories, leaf, *quarantine_session_id,
                                         *quarantine_leaf, expected_leaf_identity,
                                         *expected_quarantine_identity);
  }

  const int target_directory_fd = directories.target_fd();
  struct stat entry_stat {};
  if (::fstatat(target_directory_fd, leaf.c_str(), &entry_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    error_number = errno;
    return error_number == ENOENT ? 0 : error_number;
  }
  if (!S_ISREG(entry_stat.st_mode) || !identityMatchesStat(expected_leaf_identity, entry_stat)) {
    return EINVAL;
  }

  // This identity check is not atomic with unlinkat: a replacement between these calls remains
  // possible, so this does not eliminate the fstatat/unlinkat race.
  if (::unlinkat(target_directory_fd, leaf.c_str(), 0) != 0) {
    error_number = errno;
    return error_number == ENOENT ? 0 : error_number;
  }
  return 0;
}

int captureManagedFileDirectoryIdentity(const std::string& root,
                                        std::string* root_identity) {
  if (root_identity == nullptr) return EINVAL;
  ScopedFd root_fd;
  const int open_error = openManagedDirectory(root, &root_fd);
  if (open_error != 0) return open_error;
  return readDirectoryIdentity(root_fd.get(), root_identity);
}

int captureManagedFileLeafIdentity(const std::string& root, const std::string& leaf,
                                   const std::string& expected_root_identity,
                                   std::string* leaf_identity) {
  if (!isUuidComponent(leaf) || !isIdentityString(expected_root_identity) ||
      leaf_identity == nullptr) {
    return EINVAL;
  }

  ScopedFd root_fd;
  const int open_error = openManagedDirectory(root, &root_fd);
  if (open_error != 0) return open_error;

  std::string actual_root_identity;
  int error_number = readDirectoryIdentity(root_fd.get(), &actual_root_identity);
  if (error_number != 0) return error_number;
  if (actual_root_identity != expected_root_identity) return EINVAL;

  // O_NONBLOCK avoids hanging if the leaf is replaced with a FIFO before this open.
  ScopedFd entry_fd(::openat(root_fd.get(), leaf.c_str(),
                             O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (!entry_fd.valid()) return errno;
  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode)) return EINVAL;
  *leaf_identity = formatFileIdentity(entry_stat.st_dev, entry_stat.st_ino);
  return 0;
}

int readManagedFileChunk(const std::string& root, const std::string& leaf,
                         const std::string& expected_root_identity,
                         const std::string& expected_leaf_identity, int64_t offset,
                         int max_bytes, std::vector<uint8_t>* bytes,
                         int64_t* file_length, int64_t* modified_time_micros) {
  constexpr int kMaximumChunkBytes = 1024 * 1024;
  if (!isUuidComponent(leaf) || !isIdentityString(expected_root_identity) ||
      !isIdentityString(expected_leaf_identity) || offset < 0 || max_bytes < 1 ||
      max_bytes > kMaximumChunkBytes || bytes == nullptr || file_length == nullptr ||
      modified_time_micros == nullptr) {
    return EINVAL;
  }
  ScopedFd root_fd;
  int error_number = openManagedDirectory(root, &root_fd);
  if (error_number != 0) return error_number;

  std::string actual_root_identity;
  error_number = readDirectoryIdentity(root_fd.get(), &actual_root_identity);
  if (error_number != 0) return error_number;
  if (actual_root_identity != expected_root_identity) return EINVAL;

  // O_NONBLOCK avoids hanging if the leaf was replaced with a FIFO before this open.
  ScopedFd entry_fd(::openat(root_fd.get(), leaf.c_str(),
                             O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
  if (!entry_fd.valid()) return errno;

  struct stat entry_stat {};
  if (::fstat(entry_fd.get(), &entry_stat) != 0) return errno;
  if (!S_ISREG(entry_stat.st_mode) ||
      !identityMatchesStat(expected_leaf_identity, entry_stat)) {
    return EINVAL;
  }
  if (entry_stat.st_size < 0 ||
      static_cast<unsigned long long>(entry_stat.st_size) >
          static_cast<unsigned long long>(std::numeric_limits<int64_t>::max())) {
    return EOVERFLOW;
  }
  const int64_t modified_seconds = static_cast<int64_t>(entry_stat.st_mtim.tv_sec);
  const int64_t modified_nanoseconds =
      static_cast<int64_t>(entry_stat.st_mtim.tv_nsec);
  if (modified_nanoseconds < 0 || modified_nanoseconds >= 1000000000) return EINVAL;
  constexpr int64_t kMicrosPerSecond = 1000000;
  if (modified_seconds > std::numeric_limits<int64_t>::max() / kMicrosPerSecond ||
      modified_seconds < std::numeric_limits<int64_t>::min() / kMicrosPerSecond) {
    return EOVERFLOW;
  }
  const int64_t modified_time_base = modified_seconds * kMicrosPerSecond;
  const int64_t modified_time_fraction = modified_nanoseconds / 1000;
  if (modified_time_base >
      std::numeric_limits<int64_t>::max() - modified_time_fraction) {
    return EOVERFLOW;
  }

  *file_length = static_cast<int64_t>(entry_stat.st_size);
  *modified_time_micros = modified_time_base + modified_time_fraction;
  const int64_t available = offset >= *file_length ? 0 : *file_length - offset;
  const size_t requested_bytes = static_cast<size_t>(
      std::min<int64_t>(available, static_cast<int64_t>(max_bytes)));
  bytes->assign(requested_bytes, 0);
  size_t total_read = 0;
  while (total_read < requested_bytes) {
    const ssize_t read_count = ::pread(
        entry_fd.get(), bytes->data() + total_read, requested_bytes - total_read,
        static_cast<off_t>(offset + static_cast<int64_t>(total_read)));
    if (read_count < 0) {
      if (errno == EINTR) continue;
      return errno;
    }
    if (read_count == 0) break;
    total_read += static_cast<size_t>(read_count);
  }

  struct stat final_stat {};
  if (::fstat(entry_fd.get(), &final_stat) != 0) return errno;
  if (!S_ISREG(final_stat.st_mode) ||
      !identityMatchesStat(expected_leaf_identity, final_stat) ||
      final_stat.st_size != entry_stat.st_size ||
      final_stat.st_mtim.tv_sec != entry_stat.st_mtim.tv_sec ||
      final_stat.st_mtim.tv_nsec != entry_stat.st_mtim.tv_nsec) {
    return EINVAL;
  }

  bytes->resize(total_read);
  return 0;
}

int unlinkManagedFile(const std::string& root, const std::string& leaf,
                      const std::string& expected_root_identity,
                      const std::string& expected_leaf_identity) {
  if (!isUuidComponent(leaf) || !isIdentityString(expected_root_identity) ||
      !isIdentityString(expected_leaf_identity)) {
    return EINVAL;
  }

  ScopedFd root_fd;
  const int open_error = openManagedDirectory(root, &root_fd);
  if (open_error != 0) return open_error;

  std::string actual_root_identity;
  int error_number = readDirectoryIdentity(root_fd.get(), &actual_root_identity);
  if (error_number != 0) return error_number;
  if (actual_root_identity != expected_root_identity) return EINVAL;

  struct stat entry_stat {};
  if (::fstatat(root_fd.get(), leaf.c_str(), &entry_stat, AT_SYMLINK_NOFOLLOW) != 0) {
    return errno == ENOENT ? 0 : errno;
  }
  if (!S_ISREG(entry_stat.st_mode) ||
      !identityMatchesStat(expected_leaf_identity, entry_stat)) {
    return EINVAL;
  }

  // unlinkat is name-based, not bound to the checked inode; a same-UID rename/replacement
  // race between fstatat and unlinkat remains possible on POSIX.
  if (::unlinkat(root_fd.get(), leaf.c_str(), 0) != 0) return errno;
  return 0;
}

void throwIoException(JNIEnv* env) {
  jclass exception_class = env->FindClass("java/io/IOException");
  if (exception_class == nullptr) return;
  env->ThrowNew(exception_class, "Secure filesystem operation failed.");
  env->DeleteLocalRef(exception_class);
}

}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_xingzhichen_landrop_MainActivity_captureReceiveDirectoryIdentityNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring relative_parent_value) {
  try {
    std::string root;
    std::string relative_parent;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, relative_parent_value, &relative_parent)) {
      throwIoException(env);
      return nullptr;
    }

    std::string root_identity;
    std::string parent_identity;
    const int error_number = captureReceiveDirectoryIdentity(
        root, relative_parent, &root_identity, &parent_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }

    jclass string_class = env->FindClass("java/lang/String");
    if (string_class == nullptr) return nullptr;
    jobjectArray identities = env->NewObjectArray(2, string_class, nullptr);
    env->DeleteLocalRef(string_class);
    if (identities == nullptr) return nullptr;

    jstring root_identity_value = env->NewStringUTF(root_identity.c_str());
    if (root_identity_value == nullptr) return nullptr;
    env->SetObjectArrayElement(identities, 0, root_identity_value);
    env->DeleteLocalRef(root_identity_value);
    if (env->ExceptionCheck()) return nullptr;

    if (!parent_identity.empty()) {
      jstring parent_identity_value = env->NewStringUTF(parent_identity.c_str());
      if (parent_identity_value == nullptr) return nullptr;
      env->SetObjectArrayElement(identities, 1, parent_identity_value);
      env->DeleteLocalRef(parent_identity_value);
      if (env->ExceptionCheck()) return nullptr;
    }
    return identities;
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_xingzhichen_landrop_MainActivity_createReceiveEntryNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring relative_parent_value,
    jstring leaf_value, jstring expected_root_identity_value,
    jstring expected_parent_identity_value) {
  try {
    std::string root;
    std::string relative_parent;
    std::string leaf;
    std::string expected_root_identity;
    std::string expected_parent_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, relative_parent_value, &relative_parent) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity)) {
      throwIoException(env);
      return nullptr;
    }
    const std::string* expected_parent_identity_pointer = nullptr;
    if (expected_parent_identity_value != nullptr) {
      if (!appendUtf8(env, expected_parent_identity_value, &expected_parent_identity)) {
        throwIoException(env);
        return nullptr;
      }
      expected_parent_identity_pointer = &expected_parent_identity;
    }

    std::string leaf_identity;
    const int error_number = createReceiveEntry(
        root, relative_parent, leaf, expected_root_identity,
        expected_parent_identity_pointer, &leaf_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }
    return env->NewStringUTF(leaf_identity.c_str());
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_xingzhichen_landrop_MainActivity_captureReceiveEntryIdentityNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring relative_parent_value,
    jstring leaf_value, jstring expected_root_identity_value,
    jstring expected_parent_identity_value) {
  try {
    std::string root;
    std::string relative_parent;
    std::string leaf;
    std::string expected_root_identity;
    std::string expected_parent_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, relative_parent_value, &relative_parent) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity)) {
      throwIoException(env);
      return nullptr;
    }
    const std::string* expected_parent_identity_pointer = nullptr;
    if (expected_parent_identity_value != nullptr) {
      if (!appendUtf8(env, expected_parent_identity_value, &expected_parent_identity)) {
        throwIoException(env);
        return nullptr;
      }
      expected_parent_identity_pointer = &expected_parent_identity;
    }

    std::string leaf_identity;
    const int error_number = captureReceiveEntryIdentity(
        root, relative_parent, leaf, expected_root_identity,
        expected_parent_identity_pointer, &leaf_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }
    return env->NewStringUTF(leaf_identity.c_str());
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_xingzhichen_landrop_MainActivity_prepareReceiveQuarantineNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring relative_parent_value,
    jstring leaf_value, jstring quarantine_session_id_value,
    jstring quarantine_leaf_value, jstring expected_root_identity_value,
    jstring expected_parent_identity_value, jstring expected_leaf_identity_value) {
  try {
    std::string root;
    std::string relative_parent;
    std::string leaf;
    std::string quarantine_session_id;
    std::string quarantine_leaf;
    std::string expected_root_identity;
    std::string expected_parent_identity;
    std::string expected_leaf_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, relative_parent_value, &relative_parent) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, quarantine_session_id_value, &quarantine_session_id) ||
        !appendUtf8(env, quarantine_leaf_value, &quarantine_leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity) ||
        !appendUtf8(env, expected_leaf_identity_value, &expected_leaf_identity)) {
      throwIoException(env);
      return nullptr;
    }
    const std::string* expected_parent_identity_pointer = nullptr;
    if (expected_parent_identity_value != nullptr) {
      if (!appendUtf8(env, expected_parent_identity_value, &expected_parent_identity)) {
        throwIoException(env);
        return nullptr;
      }
      expected_parent_identity_pointer = &expected_parent_identity;
    }

    std::string quarantine_identity;
    const int error_number = prepareReceiveQuarantine(
        root, relative_parent, leaf, quarantine_session_id, quarantine_leaf,
        expected_root_identity, expected_parent_identity_pointer, expected_leaf_identity,
        &quarantine_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }
    return env->NewStringUTF(quarantine_identity.c_str());
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_xingzhichen_landrop_MainActivity_unlinkReceiveEntryNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring relative_parent_value,
    jstring leaf_value, jstring expected_root_identity_value,
    jstring expected_parent_identity_value, jstring expected_leaf_identity_value,
    jstring quarantine_session_id_value, jstring quarantine_leaf_value,
    jstring expected_quarantine_identity_value) {
  try {
    std::string root;
    std::string relative_parent;
    std::string leaf;
    std::string expected_root_identity;
    std::string expected_parent_identity;
    std::string expected_leaf_identity;
    std::string quarantine_session_id;
    std::string quarantine_leaf;
    std::string expected_quarantine_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, relative_parent_value, &relative_parent) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity) ||
        !appendUtf8(env, expected_leaf_identity_value, &expected_leaf_identity)) {
      return EINVAL;
    }
    const std::string* expected_parent_identity_pointer = nullptr;
    if (expected_parent_identity_value != nullptr) {
      if (!appendUtf8(env, expected_parent_identity_value, &expected_parent_identity)) {
        return EINVAL;
      }
      expected_parent_identity_pointer = &expected_parent_identity;
    }
    const std::string* quarantine_session_id_pointer = nullptr;
    if (quarantine_session_id_value != nullptr) {
      if (!appendUtf8(env, quarantine_session_id_value, &quarantine_session_id)) {
        return EINVAL;
      }
      quarantine_session_id_pointer = &quarantine_session_id;
    }
    const std::string* quarantine_leaf_pointer = nullptr;
    if (quarantine_leaf_value != nullptr) {
      if (!appendUtf8(env, quarantine_leaf_value, &quarantine_leaf)) return EINVAL;
      quarantine_leaf_pointer = &quarantine_leaf;
    }
    const std::string* expected_quarantine_identity_pointer = nullptr;
    if (expected_quarantine_identity_value != nullptr) {
      if (!appendUtf8(env, expected_quarantine_identity_value,
                      &expected_quarantine_identity)) {
        return EINVAL;
      }
      expected_quarantine_identity_pointer = &expected_quarantine_identity;
    }
    return unlinkReceiveEntry(root, relative_parent, leaf, expected_root_identity,
                              expected_parent_identity_pointer, expected_leaf_identity,
                              quarantine_session_id_pointer, quarantine_leaf_pointer,
                              expected_quarantine_identity_pointer);
  } catch (...) {
    return ENOMEM;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_xingzhichen_landrop_MainActivity_removeReceiveQuarantineNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring session_id_value,
    jstring expected_root_identity_value, jstring expected_quarantine_identity_value) {
  try {
    std::string root;
    std::string session_id;
    std::string expected_root_identity;
    std::string expected_quarantine_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, session_id_value, &session_id) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity) ||
        !appendUtf8(env, expected_quarantine_identity_value,
                    &expected_quarantine_identity)) {
      return EINVAL;
    }
    return removeReceiveQuarantine(root, session_id, expected_root_identity,
                                   expected_quarantine_identity);
  } catch (...) {
    return ENOMEM;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_xingzhichen_landrop_MainActivity_captureManagedFileDirectoryIdentityNative(
    JNIEnv* env, jobject /* activity */, jstring root_value) {
  try {
    std::string root;
    if (!appendUtf8(env, root_value, &root)) {
      throwIoException(env);
      return nullptr;
    }

    std::string root_identity;
    const int error_number =
        captureManagedFileDirectoryIdentity(root, &root_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }
    return env->NewStringUTF(root_identity.c_str());
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_xingzhichen_landrop_MainActivity_captureManagedFileLeafIdentityNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring leaf_value,
    jstring expected_root_identity_value) {
  try {
    std::string root;
    std::string leaf;
    std::string expected_root_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity)) {
      throwIoException(env);
      return nullptr;
    }

    std::string leaf_identity;
    const int error_number = captureManagedFileLeafIdentity(
        root, leaf, expected_root_identity, &leaf_identity);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }
    return env->NewStringUTF(leaf_identity.c_str());
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_xingzhichen_landrop_MainActivity_readManagedFileChunkNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring leaf_value,
    jstring expected_root_identity_value, jstring expected_leaf_identity_value,
    jlong offset_value, jint max_bytes, jlongArray metadata_value) {
  try {
    std::string root;
    std::string leaf;
    std::string expected_root_identity;
    std::string expected_leaf_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity) ||
        !appendUtf8(env, expected_leaf_identity_value, &expected_leaf_identity) ||
        metadata_value == nullptr || env->GetArrayLength(metadata_value) < 2) {
      throwIoException(env);
      return nullptr;
    }

    std::vector<uint8_t> bytes;
    int64_t file_length = 0;
    int64_t modified_time_micros = 0;
    const int error_number = readManagedFileChunk(
        root, leaf, expected_root_identity, expected_leaf_identity,
        static_cast<int64_t>(offset_value), max_bytes, &bytes, &file_length,
        &modified_time_micros);
    if (error_number != 0) {
      throwIoException(env);
      return nullptr;
    }

    jbyteArray result = env->NewByteArray(static_cast<jsize>(bytes.size()));
    if (result == nullptr) return nullptr;
    if (!bytes.empty()) {
      env->SetByteArrayRegion(result, 0, static_cast<jsize>(bytes.size()),
                              reinterpret_cast<const jbyte*>(bytes.data()));
      if (env->ExceptionCheck()) return nullptr;
    }
    const jlong metadata[] = {static_cast<jlong>(file_length),
                              static_cast<jlong>(modified_time_micros)};
    env->SetLongArrayRegion(metadata_value, 0, 2, metadata);
    if (env->ExceptionCheck()) return nullptr;
    return result;
  } catch (...) {
    throwIoException(env);
    return nullptr;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_xingzhichen_landrop_MainActivity_unlinkManagedFileNative(
    JNIEnv* env, jobject /* activity */, jstring root_value, jstring leaf_value,
    jstring expected_root_identity_value, jstring expected_leaf_identity_value) {
  try {
    std::string root;
    std::string leaf;
    std::string expected_root_identity;
    std::string expected_leaf_identity;
    if (!appendUtf8(env, root_value, &root) ||
        !appendUtf8(env, leaf_value, &leaf) ||
        !appendUtf8(env, expected_root_identity_value, &expected_root_identity) ||
        !appendUtf8(env, expected_leaf_identity_value, &expected_leaf_identity)) {
      return EINVAL;
    }
    return unlinkManagedFile(root, leaf, expected_root_identity, expected_leaf_identity);
  } catch (...) {
    return ENOMEM;
  }
}
