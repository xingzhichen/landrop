import Darwin
import Flutter
import Foundation
import UIKit

private func secureFsError(_ message: String, code: Int32 = EINVAL) -> NSError {
  NSError(
    domain: NSPOSIXErrorDomain,
    code: Int(code),
    userInfo: [NSLocalizedDescriptionKey: message])
}

private func secureFsPosixError(_ operation: String, code: Int32) -> NSError {
  secureFsError("\(operation): \(String(cString: strerror(code)))", code: code)
}

private func secureFsDirectoryIdentity(_ fd: Int32) throws -> String {
  var directoryStat = stat()
  guard fstat(fd, &directoryStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect directory identity", code: code)
  }
  return "dev=\(directoryStat.st_dev);ino=\(directoryStat.st_ino)"
}

private func isSecureFsIdentity(_ value: String) -> Bool {
  value.range(of: #"^dev=[0-9]+;ino=[0-9]+$"#, options: .regularExpression) != nil
}

private func isSecureFsControl(_ value: String) -> Bool {
  value.unicodeScalars.contains { scalar in
    scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
  }
}

private func isSecureFsUuidComponent(_ value: String) -> Bool {
  value.range(
    of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
    options: .regularExpression) != nil
}

private func isSecureFsDateComponent(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
  for index in bytes.indices where index != 4 && index != 7 {
    guard bytes[index] >= 48 && bytes[index] <= 57 else { return false }
  }
  func number(_ range: Range<Int>) -> Int {
    range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
  }
  let year = number(0..<4)
  let month = number(5..<7)
  let day = number(8..<10)
  guard year > 0, (1...12).contains(month) else { return false }
  let daysPerMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  var maximumDay = daysPerMonth[month - 1]
  let isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  if month == 2 && isLeapYear { maximumDay += 1 }
  return day >= 1 && day <= maximumDay
}

private func isSecureFsUuidPartLeaf(_ value: String) -> Bool {
  value.range(
    of: #"^\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.part$"#,
    options: .regularExpression) != nil
}

private func isSecureFsSafeLeaf(_ value: String) -> Bool {
  !value.isEmpty && value != "." && value != ".."
    && !value.contains("\u{0000}") && !value.contains("/")
    && !value.unicodeScalars.contains(where: { $0.value == 0x5c })
    && !isSecureFsControl(value)
}

private func secureFsEntryIdentity(_ entryStat: stat) -> String {
  "dev=\(entryStat.st_dev);ino=\(entryStat.st_ino)"
}

private func secureOpenReceiveQuarantine(rootFD: Int32) throws -> Int32 {
  var rootStat = stat()
  guard fstat(rootFD, &rootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive root", code: code)
  }

  let directoryName = ".landrop-quarantine"
  let createResult = directoryName.withCString { mkdirat(rootFD, $0, mode_t(0o700)) }
  if createResult != 0 {
    let code = errno
    if code != EEXIST { throw secureFsPosixError("create receive quarantine", code: code) }
  }
  let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  let quarantineFD = directoryName.withCString { openat(rootFD, $0, flags) }
  guard quarantineFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive quarantine", code: code)
  }
  do {
    var quarantineStat = stat()
    guard fstat(quarantineFD, &quarantineStat) == 0 else {
      let code = errno
      throw secureFsPosixError("inspect receive quarantine", code: code)
    }
    guard (quarantineStat.st_mode & S_IFMT) == S_IFDIR,
          quarantineStat.st_uid == geteuid(), quarantineStat.st_dev == rootStat.st_dev else {
      throw secureFsError("The receive quarantine is not a private directory on the root volume.")
    }
    guard fchmod(quarantineFD, mode_t(0o700)) == 0 else {
      let code = errno
      throw secureFsPosixError("secure receive quarantine permissions", code: code)
    }
    guard fstat(quarantineFD, &quarantineStat) == 0 else {
      let code = errno
      throw secureFsPosixError("verify receive quarantine permissions", code: code)
    }
    guard (quarantineStat.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
      throw secureFsError("The receive quarantine permissions are not private.")
    }
    guard fsync(rootFD) == 0 else {
      let code = errno
      throw secureFsPosixError("sync receive root", code: code)
    }
  } catch {
    _ = close(quarantineFD)
    throw error
  }
  return quarantineFD
}

/// When the dated parent has disappeared, only an identity-matched quarantine may be removed.
private func secureRemoveMatchedQuarantineWithoutParent(
  quarantineFD: Int32,
  quarantineLeaf: String,
  expectedLeafIdentity: String
) throws {
  let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  let entryFD = quarantineLeaf.withCString { openat(quarantineFD, $0, flags) }
  if entryFD < 0 {
    let code = errno
    if code == ENOENT { return }
    throw secureFsPosixError("open quarantined receive entry", code: code)
  }
  defer { _ = close(entryFD) }

  var entryStat = stat()
  guard fstat(entryFD, &entryStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect quarantined receive entry", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular quarantined receive entry is allowed.")
  }
  guard secureFsEntryIdentity(entryStat) == expectedLeafIdentity else {
    throw secureFsError("The quarantined receive entry identity changed; it was preserved.")
  }
  let unlinkResult = quarantineLeaf.withCString { unlinkat(quarantineFD, $0, 0) }
  if unlinkResult != 0 {
    let code = errno
    if code != ENOENT { throw secureFsPosixError("remove quarantined receive entry", code: code) }
  }
  guard fsync(quarantineFD) == 0 else {
    let code = errno
    throw secureFsPosixError("sync receive quarantine", code: code)
  }
}

private func secureReceiveSessionName(for sourceLeaf: String, sessionId: String) throws -> String {
  guard isSecureFsUuidComponent(sessionId), isSecureFsSafeLeaf(sourceLeaf) else {
    throw secureFsError("A valid quarantine session UUID and safe source leaf are required.")
  }
  if isSecureFsUuidPartLeaf(sourceLeaf) {
    let sourceId = String(sourceLeaf.dropFirst().dropLast(5))
    guard sourceId.caseInsensitiveCompare(sessionId) == .orderedSame else {
      throw secureFsError("The source UUID does not match the quarantine session UUID.")
    }
  }
  return sessionId
}

private func secureReceiveDirectoryIsEmpty(_ directoryFD: Int32) throws -> Bool {
  let duplicateFD = openat(
    directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard duplicateFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive directory for enumeration", code: code)
  }
  guard let directory = fdopendir(duplicateFD) else {
    let code = errno
    _ = close(duplicateFD)
    throw secureFsPosixError("read receive directory", code: code)
  }
  var empty = true
  errno = 0
  while let entry = readdir(directory) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
      namePointer.withMemoryRebound(
        to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
          String(cString: $0)
        }
    }
    if name != "." && name != ".." {
      empty = false
      break
    }
  }
  let readError = empty ? errno : 0
  let closeResult = closedir(directory)
  if readError != 0 {
    throw secureFsPosixError("read receive directory", code: readError)
  }
  if empty && closeResult != 0 {
    let code = errno
    throw secureFsPosixError("close receive directory", code: code)
  }
  return empty
}

private func secureReceiveSourceMatches(
  parentFD: Int32, leaf: String, expectedLeafIdentity: String
) throws -> Bool {
  var sourceStat = stat()
  let result = leaf.withCString {
    fstatat(parentFD, $0, &sourceStat, AT_SYMLINK_NOFOLLOW)
  }
  if result != 0 {
    let code = errno
    if code == ENOENT { return false }
    throw secureFsPosixError("inspect receive source", code: code)
  }
  guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular receive source can be prepared for quarantine.")
  }
  guard secureFsEntryIdentity(sourceStat) == expectedLeafIdentity else {
    throw secureFsError("The receive source identity changed before quarantine preparation.")
  }
  return true
}

private func secureOpenPinnedReceiveSessionQuarantine(
  rootFD: Int32, sessionName: String, expectedQuarantineIdentity: String
) throws -> Int32 {
  guard isSecureFsIdentity(expectedQuarantineIdentity), isSecureFsUuidComponent(sessionName) else {
    throw secureFsError("A valid pinned quarantine identity and session UUID are required.")
  }
  var rootStat = stat()
  guard fstat(rootFD, &rootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive root", code: code)
  }
  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  let quarantineRootName = ".landrop-quarantine"
  let quarantineRootFD = quarantineRootName.withCString {
    openat(rootFD, $0, directoryFlags)
  }
  guard quarantineRootFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open pinned receive quarantine root", code: code)
  }
  defer { _ = close(quarantineRootFD) }

  var quarantineRootStat = stat()
  guard fstat(quarantineRootFD, &quarantineRootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect pinned receive quarantine root", code: code)
  }
  guard (quarantineRootStat.st_mode & S_IFMT) == S_IFDIR,
        quarantineRootStat.st_uid == geteuid(), quarantineRootStat.st_dev == rootStat.st_dev,
        (quarantineRootStat.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
    throw secureFsError("The pinned receive quarantine root is not private and valid.")
  }

  let sessionFD = sessionName.withCString { openat(quarantineRootFD, $0, directoryFlags) }
  guard sessionFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open pinned receive quarantine session", code: code)
  }
  do {
    var sessionStat = stat()
    guard fstat(sessionFD, &sessionStat) == 0 else {
      let code = errno
      throw secureFsPosixError("inspect pinned receive quarantine session", code: code)
    }
    guard (sessionStat.st_mode & S_IFMT) == S_IFDIR,
          sessionStat.st_uid == geteuid(), sessionStat.st_dev == rootStat.st_dev,
          (sessionStat.st_mode & mode_t(0o7777)) == mode_t(0o700),
          secureFsEntryIdentity(sessionStat) == expectedQuarantineIdentity else {
      throw secureFsError("The pinned receive quarantine identity or permissions changed.")
    }
  } catch {
    _ = close(sessionFD)
    throw error
  }
  return sessionFD
}

private func securePrepareReceiveQuarantine(
  root: String,
  relativeParent: String,
  leaf: String,
  quarantineSessionId: String,
  quarantineLeaf: String,
  expectedRootIdentity: String,
  expectedParentIdentity: String?,
  expectedLeafIdentity: String
) throws -> String {
  guard isSecureFsSafeLeaf(leaf), isSecureFsIdentity(expectedLeafIdentity),
        quarantineLeaf == ".\(quarantineSessionId).quarantine",
        isSecureFsSafeLeaf(quarantineLeaf) else {
    throw secureFsError("A safe source leaf, quarantine session UUID, quarantine leaf, and valid leaf identity are required.")
  }
  let sessionName = try secureReceiveSessionName(for: leaf, sessionId: quarantineSessionId)
  let parentFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: relativeParent,
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: expectedParentIdentity)
  defer { _ = close(parentFD) }
  guard try secureReceiveSourceMatches(
    parentFD: parentFD, leaf: leaf, expectedLeafIdentity: expectedLeafIdentity) else {
    throw secureFsError("Cannot prepare quarantine because the receive source is missing.", code: ENOENT)
  }

  let rootFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: "",
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: nil)
  defer { _ = close(rootFD) }
  let quarantineRootFD = try secureOpenReceiveQuarantine(rootFD: rootFD)
  defer { _ = close(quarantineRootFD) }
  var rootStat = stat()
  guard fstat(rootFD, &rootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive root", code: code)
  }
  let createResult = sessionName.withCString {
    mkdirat(quarantineRootFD, $0, mode_t(0o700))
  }
  if createResult != 0 {
    let code = errno
    if code != EEXIST { throw secureFsPosixError("create receive quarantine session", code: code) }
  }
  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  let sessionFD = sessionName.withCString { openat(quarantineRootFD, $0, directoryFlags) }
  guard sessionFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive quarantine session", code: code)
  }
  do {
    var sessionStat = stat()
    guard fstat(sessionFD, &sessionStat) == 0 else {
      let code = errno
      throw secureFsPosixError("inspect receive quarantine session", code: code)
    }
    guard (sessionStat.st_mode & S_IFMT) == S_IFDIR,
          sessionStat.st_uid == geteuid(), sessionStat.st_dev == rootStat.st_dev else {
      throw secureFsError("The receive quarantine session is not a private directory on the root volume.")
    }
    guard try secureReceiveDirectoryIsEmpty(sessionFD) else {
      throw secureFsError("The receive quarantine session directory is not empty.")
    }
    guard fchmod(sessionFD, mode_t(0o700)) == 0 else {
      let code = errno
      throw secureFsPosixError("secure receive quarantine session permissions", code: code)
    }
    guard fstat(sessionFD, &sessionStat) == 0 else {
      let code = errno
      throw secureFsPosixError("verify receive quarantine session", code: code)
    }
    guard (sessionStat.st_mode & mode_t(0o7777)) == mode_t(0o700),
          try secureReceiveDirectoryIsEmpty(sessionFD) else {
      throw secureFsError("The receive quarantine session is not empty and private.")
    }
    guard try secureReceiveSourceMatches(
      parentFD: parentFD, leaf: leaf, expectedLeafIdentity: expectedLeafIdentity) else {
      throw secureFsError("The receive source disappeared during quarantine preparation.", code: ENOENT)
    }
    guard fsync(sessionFD) == 0 else {
      let code = errno
      throw secureFsPosixError("sync receive quarantine session", code: code)
    }
    guard fsync(quarantineRootFD) == 0 else {
      let code = errno
      throw secureFsPosixError("sync receive quarantine root", code: code)
    }
    guard fsync(rootFD) == 0 else {
      let code = errno
      throw secureFsPosixError("sync receive root", code: code)
    }
    let identity = secureFsEntryIdentity(sessionStat)
    _ = close(sessionFD)
    return identity
  } catch {
    _ = close(sessionFD)
    throw error
  }
}

private func secureSyncReceiveDirectories(_ firstFD: Int32, _ secondFD: Int32) throws {
  guard fsync(firstFD) == 0 else {
    let code = errno
    throw secureFsPosixError("sync receive directory", code: code)
  }
  guard fsync(secondFD) == 0 else {
    let code = errno
    throw secureFsPosixError("sync receive directory", code: code)
  }
}

private func secureRenameReceiveNoReplace(
  fromFD: Int32, fromLeaf: String, toFD: Int32, toLeaf: String
) -> Int32 {
  fromLeaf.withCString { source in
    toLeaf.withCString { destination in
      renameatx_np(fromFD, source, toFD, destination, UInt32(RENAME_EXCL))
    }
  }
}

/// Returns true after deleting an identity-matched quarantined file; false if absent.
/// A mismatched object is restored only with an exclusive no-replace rename, then rejected.
private func secureRecoverReceiveQuarantine(
  quarantineFD: Int32,
  parentFD: Int32,
  quarantineLeaf: String,
  sourceLeaf: String,
  expectedLeafIdentity: String
) throws -> Bool {
  let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  let entryFD = quarantineLeaf.withCString { openat(quarantineFD, $0, flags) }
  if entryFD < 0 {
    let code = errno
    if code == ENOENT { return false }
    throw secureFsPosixError("open quarantined receive entry", code: code)
  }
  defer { _ = close(entryFD) }
  var entryStat = stat()
  guard fstat(entryFD, &entryStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect quarantined receive entry", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular quarantined receive entry is allowed.")
  }
  // POSIX directory ownership and identity checks do not isolate against a hostile same-uid process.
  if secureFsEntryIdentity(entryStat) == expectedLeafIdentity {
    let unlinkResult = quarantineLeaf.withCString { unlinkat(quarantineFD, $0, 0) }
    if unlinkResult != 0 {
      let code = errno
      if code != ENOENT { throw secureFsPosixError("remove quarantined receive entry", code: code) }
    }
    guard fsync(quarantineFD) == 0 else {
      let code = errno
      throw secureFsPosixError("sync receive quarantine", code: code)
    }
    return true
  }

  let restoreResult = secureRenameReceiveNoReplace(
    fromFD: quarantineFD, fromLeaf: quarantineLeaf, toFD: parentFD, toLeaf: sourceLeaf)
  if restoreResult == 0 {
    try secureSyncReceiveDirectories(quarantineFD, parentFD)
    throw secureFsError("The quarantined receive entry identity changed and was restored.")
  }
  let code = errno
  if code == EEXIST {
    throw secureFsError("The receive source is occupied; the mismatched quarantine was preserved.", code: code)
  }
  throw secureFsPosixError("restore mismatched quarantined receive entry", code: code)
}

/// Opens the validated root or relative parent and checks both supplied directory identities.
private func secureOpenValidatedReceiveParent(
  root: String,
  relativeParent: String,
  expectedRootIdentity: String,
  expectedParentIdentity: String?
) throws -> Int32 {
  guard root.hasPrefix("/"), !root.contains("//"), !root.hasSuffix("/"),
        !root.contains("\u{0000}") else {
    throw secureFsError("The root must be an absolute canonical POSIX path.")
  }
  let rootComponents = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  guard rootComponents.allSatisfy({ $0 != "." && $0 != ".." && !isSecureFsControl($0) }),
        let pageId = rootComponents.last, isSecureFsUuidComponent(pageId) else {
    throw secureFsError("The root must end in a page UUID and contain no unsafe components.")
  }
  if !relativeParent.isEmpty && !isSecureFsDateComponent(relativeParent) {
    throw secureFsError("The relative parent must be empty or a real YYYY-MM-DD date.")
  }
  guard isSecureFsIdentity(expectedRootIdentity) else {
    throw secureFsError("A valid expected root identity is required.")
  }
  if relativeParent.isEmpty {
    guard expectedParentIdentity == nil else {
      throw secureFsError("A parent identity must be null when relativeParent is empty.")
    }
  } else {
    guard let expectedParentIdentity, isSecureFsIdentity(expectedParentIdentity) else {
      throw secureFsError("A valid expected parent identity is required.")
    }
  }

  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  var rootFD = open("/", directoryFlags)
  guard rootFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open root", code: code)
  }
  defer { if rootFD >= 0 { _ = close(rootFD) } }

  for component in rootComponents {
    let nextFD = component.withCString { openat(rootFD, $0, directoryFlags) }
    guard nextFD >= 0 else {
      let code = errno
      throw secureFsPosixError("open root component", code: code)
    }
    let previousFD = rootFD
    rootFD = nextFD
    _ = close(previousFD)
  }
  guard try secureFsDirectoryIdentity(rootFD) == expectedRootIdentity else {
    throw secureFsError("The root directory identity changed.")
  }

  guard !relativeParent.isEmpty else {
    let validatedRootFD = rootFD
    rootFD = -1
    return validatedRootFD
  }
  let parentFD = relativeParent.withCString { openat(rootFD, $0, directoryFlags) }
  guard parentFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open relative parent", code: code)
  }
  do {
    guard let expectedParentIdentity,
          try secureFsDirectoryIdentity(parentFD) == expectedParentIdentity else {
      throw secureFsError("The parent directory identity changed.")
    }
  } catch {
    _ = close(parentFD)
    throw error
  }
  return parentFD
}

private func secureCreateReceiveEntry(
  root: String,
  relativeParent: String,
  leaf: String,
  expectedRootIdentity: String,
  expectedParentIdentity: String?
) throws -> String {
  guard isSecureFsUuidPartLeaf(leaf) || isSecureFsSafeLeaf(leaf) else {
    throw secureFsError("The receive entry must be a .UUID.part leaf or a safe basename.")
  }
  let parentFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: relativeParent,
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: expectedParentIdentity)
  defer { _ = close(parentFD) }

  let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
  let entryFD = leaf.withCString { openat(parentFD, $0, flags, mode_t(0o600)) }
  guard entryFD >= 0 else {
    let code = errno
    throw secureFsPosixError("create receive entry", code: code)
  }
  defer { _ = close(entryFD) }
  var entryStat = stat()
  guard fstat(entryFD, &entryStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect created receive entry", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("The created receive entry is not a regular file.")
  }
  return secureFsEntryIdentity(entryStat)
}

private func secureCaptureReceiveEntryIdentity(
  root: String,
  relativeParent: String,
  leaf: String,
  expectedRootIdentity: String,
  expectedParentIdentity: String?
) throws -> String {
  guard isSecureFsUuidPartLeaf(leaf) else {
    throw secureFsError("The receive entry must be a .UUID.part leaf.")
  }
  let parentFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: relativeParent,
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: expectedParentIdentity)
  defer { _ = close(parentFD) }

  let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  let entryFD = leaf.withCString { openat(parentFD, $0, flags) }
  guard entryFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive entry", code: code)
  }
  defer { _ = close(entryFD) }
  var entryStat = stat()
  guard fstat(entryFD, &entryStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive entry", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular receive entry has an identity.")
  }
  return secureFsEntryIdentity(entryStat)
}

private func secureUnlinkReceiveEntry(
  root: String,
  relativeParent: String,
  leaf: String,
  expectedRootIdentity: String,
  expectedParentIdentity: String?,
  expectedLeafIdentity: String,
  quarantineLeaf: String?,
  quarantineSessionId: String?,
  expectedQuarantineIdentity: String?
) throws {
  guard isSecureFsSafeLeaf(leaf) else {
    throw secureFsError("The leaf must be a safe single filename component.")
  }
  guard isSecureFsIdentity(expectedLeafIdentity) else {
    throw secureFsError("A valid expected leaf identity is required.")
  }
  guard (quarantineLeaf == nil) == (expectedQuarantineIdentity == nil) else {
    throw secureFsError("quarantineLeaf and expectedQuarantineIdentity must be provided together.")
  }
  if let expectedQuarantineIdentity, !isSecureFsIdentity(expectedQuarantineIdentity) {
    throw secureFsError("A valid expected quarantine identity is required.")
  }
  let resolvedQuarantineSessionId: String?
  if let quarantineLeaf {
    let sessionId = quarantineSessionId ?? (isSecureFsUuidPartLeaf(leaf)
      ? String(leaf.dropFirst().dropLast(5)) : nil)
    guard let sessionId,
          quarantineLeaf == ".\(sessionId).quarantine",
          isSecureFsSafeLeaf(quarantineLeaf) else {
      throw secureFsError("A valid quarantine session UUID and matching quarantine leaf are required.")
    }
    _ = try secureReceiveSessionName(for: leaf, sessionId: sessionId)
    resolvedQuarantineSessionId = sessionId
  } else {
    guard quarantineSessionId == nil else {
      throw secureFsError("quarantineSessionId requires quarantineLeaf and expectedQuarantineIdentity.")
    }
    resolvedQuarantineSessionId = nil
  }

  let parentFD: Int32
  do {
    parentFD = try secureOpenValidatedReceiveParent(
      root: root,
      relativeParent: relativeParent,
      expectedRootIdentity: expectedRootIdentity,
      expectedParentIdentity: expectedParentIdentity)
  } catch {
    let posixError = error as NSError
    guard let quarantineLeaf, let expectedQuarantineIdentity, !relativeParent.isEmpty,
          posixError.domain == NSPOSIXErrorDomain, posixError.code == Int(ENOENT) else {
      throw error
    }
    let rootFD = try secureOpenValidatedReceiveParent(
      root: root,
      relativeParent: "",
      expectedRootIdentity: expectedRootIdentity,
      expectedParentIdentity: nil)
    defer { _ = close(rootFD) }
    guard let resolvedQuarantineSessionId else {
      throw secureFsError("A valid quarantine session UUID is required.")
    }
    let sessionName = try secureReceiveSessionName(for: leaf, sessionId: resolvedQuarantineSessionId)
    let quarantineFD = try secureOpenPinnedReceiveSessionQuarantine(
      rootFD: rootFD,
      sessionName: sessionName,
      expectedQuarantineIdentity: expectedQuarantineIdentity)
    defer { _ = close(quarantineFD) }
    try secureRemoveMatchedQuarantineWithoutParent(
      quarantineFD: quarantineFD,
      quarantineLeaf: quarantineLeaf,
      expectedLeafIdentity: expectedLeafIdentity)
    return
  }
  defer { _ = close(parentFD) }

  guard let quarantineLeaf else {
    var entryStat = stat()
    let statResult = leaf.withCString {
      fstatat(parentFD, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
    }
    if statResult != 0 {
      let code = errno
      if code == ENOENT { return }
      throw secureFsPosixError("inspect leaf", code: code)
    }
    guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
      throw secureFsError("Only a regular file can be removed.")
    }
    guard secureFsEntryIdentity(entryStat) == expectedLeafIdentity else {
      throw secureFsError("The receive entry identity changed.")
    }
    // The fstatat identity check and unlinkat are not atomic; this preserves the legacy POSIX path.
    let unlinkResult = leaf.withCString { unlinkat(parentFD, $0, 0) }
    if unlinkResult != 0 {
      let code = errno
      if code == ENOENT { return }
      throw secureFsPosixError("unlink leaf", code: code)
    }
    return
  }

  guard let expectedQuarantineIdentity else {
    throw secureFsError("A pinned quarantine identity is required.")
  }
  let rootFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: "",
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: nil)
  defer { _ = close(rootFD) }
  guard let resolvedQuarantineSessionId else {
    throw secureFsError("A valid quarantine session UUID is required.")
  }
  let sessionName = try secureReceiveSessionName(for: leaf, sessionId: resolvedQuarantineSessionId)
  let quarantineFD = try secureOpenPinnedReceiveSessionQuarantine(
    rootFD: rootFD,
    sessionName: sessionName,
    expectedQuarantineIdentity: expectedQuarantineIdentity)
  defer { _ = close(quarantineFD) }

  if try secureRecoverReceiveQuarantine(
    quarantineFD: quarantineFD,
    parentFD: parentFD,
    quarantineLeaf: quarantineLeaf,
    sourceLeaf: leaf,
    expectedLeafIdentity: expectedLeafIdentity) {
    return
  }

  let moveResult = secureRenameReceiveNoReplace(
    fromFD: parentFD, fromLeaf: leaf, toFD: quarantineFD, toLeaf: quarantineLeaf)
  if moveResult != 0 {
    let code = errno
    if code == EEXIST {
      if try secureRecoverReceiveQuarantine(
        quarantineFD: quarantineFD,
        parentFD: parentFD,
        quarantineLeaf: quarantineLeaf,
        sourceLeaf: leaf,
        expectedLeafIdentity: expectedLeafIdentity) {
        return
      }
      throw secureFsPosixError("quarantine destination changed", code: code)
    }
    if code == ENOENT {
      if try secureRecoverReceiveQuarantine(
        quarantineFD: quarantineFD,
        parentFD: parentFD,
        quarantineLeaf: quarantineLeaf,
        sourceLeaf: leaf,
        expectedLeafIdentity: expectedLeafIdentity) {
        return
      }
      var sourceStat = stat()
      let sourceResult = leaf.withCString {
        fstatat(parentFD, $0, &sourceStat, AT_SYMLINK_NOFOLLOW)
      }
      if sourceResult != 0 && errno == ENOENT { return }
    }
    // In particular, EXDEV and unsupported renameatx_np fail closed; never fall back to rename().
    throw secureFsPosixError("atomically quarantine receive entry", code: code)
  }

  try secureSyncReceiveDirectories(parentFD, quarantineFD)
  guard try secureRecoverReceiveQuarantine(
    quarantineFD: quarantineFD,
    parentFD: parentFD,
    quarantineLeaf: quarantineLeaf,
    sourceLeaf: leaf,
    expectedLeafIdentity: expectedLeafIdentity) else {
    throw secureFsPosixError("reopen quarantined receive entry", code: ENOENT)
  }
}

private func secureRemoveReceiveQuarantine(
  root: String,
  sessionId: String,
  expectedRootIdentity: String,
  expectedQuarantineIdentity: String
) throws {
  guard isSecureFsUuidComponent(sessionId), isSecureFsIdentity(expectedQuarantineIdentity) else {
    throw secureFsError("A valid session UUID and pinned quarantine identity are required.")
  }

  let rootFD = try secureOpenValidatedReceiveParent(
    root: root,
    relativeParent: "",
    expectedRootIdentity: expectedRootIdentity,
    expectedParentIdentity: nil)
  defer { _ = close(rootFD) }

  var rootStat = stat()
  guard fstat(rootFD, &rootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive root", code: code)
  }

  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  let quarantineRootName = ".landrop-quarantine"
  let quarantineRootFD = quarantineRootName.withCString {
    openat(rootFD, $0, directoryFlags)
  }
  guard quarantineRootFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive quarantine root", code: code)
  }
  defer { _ = close(quarantineRootFD) }

  var quarantineRootStat = stat()
  guard fstat(quarantineRootFD, &quarantineRootStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive quarantine root", code: code)
  }
  guard (quarantineRootStat.st_mode & S_IFMT) == S_IFDIR,
        quarantineRootStat.st_uid == geteuid(), quarantineRootStat.st_dev == rootStat.st_dev,
        (quarantineRootStat.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
    throw secureFsError("The receive quarantine root is not private and valid.")
  }

  let sessionFD = sessionId.withCString { openat(quarantineRootFD, $0, directoryFlags) }
  guard sessionFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open receive quarantine session", code: code)
  }
  defer { _ = close(sessionFD) }

  var sessionStat = stat()
  guard fstat(sessionFD, &sessionStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect receive quarantine session", code: code)
  }
  guard (sessionStat.st_mode & S_IFMT) == S_IFDIR,
        sessionStat.st_uid == geteuid(), sessionStat.st_dev == rootStat.st_dev,
        (sessionStat.st_mode & mode_t(0o7777)) == mode_t(0o700),
        secureFsEntryIdentity(sessionStat) == expectedQuarantineIdentity else {
    throw secureFsError("The receive quarantine session identity or permissions changed.")
  }
  guard try secureReceiveDirectoryIsEmpty(sessionFD) else {
    throw secureFsError("The receive quarantine session is not empty.")
  }

  // Recheck the directory entry against the opened descriptor before unlinking.
  var entryStat = stat()
  let statResult = sessionId.withCString {
    fstatat(quarantineRootFD, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
  }
  guard statResult == 0 else {
    let code = errno
    throw secureFsPosixError("verify receive quarantine session entry", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFDIR,
        entryStat.st_uid == geteuid(), entryStat.st_dev == rootStat.st_dev,
        (entryStat.st_mode & mode_t(0o7777)) == mode_t(0o700),
        secureFsEntryIdentity(entryStat) == expectedQuarantineIdentity,
        try secureReceiveDirectoryIsEmpty(sessionFD) else {
    throw secureFsError("The receive quarantine session changed or is not empty.")
  }

  let unlinkResult = sessionId.withCString {
    unlinkat(quarantineRootFD, $0, AT_REMOVEDIR)
  }
  guard unlinkResult == 0 else {
    let code = errno
    throw secureFsPosixError("remove receive quarantine session", code: code)
  }
  guard fsync(quarantineRootFD) == 0 else {
    let code = errno
    throw secureFsPosixError("sync receive quarantine root", code: code)
  }
}

private func captureSecureFsDirectoryIdentity(
  root: String,
  relativeParent: String
) throws -> (rootIdentity: String, parentIdentity: String?) {
  guard root.hasPrefix("/"), !root.contains("//"), !root.hasSuffix("/"),
        !root.contains("\u{0000}") else {
    throw secureFsError("The root must be an absolute canonical POSIX path.")
  }
  let rootComponents = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  guard rootComponents.allSatisfy({ $0 != "." && $0 != ".." && !isSecureFsControl($0) }),
        let pageId = rootComponents.last, isSecureFsUuidComponent(pageId) else {
    throw secureFsError("The root must end in a page UUID and contain no unsafe components.")
  }
  if !relativeParent.isEmpty && !isSecureFsDateComponent(relativeParent) {
    throw secureFsError("The relative parent must be empty or a real YYYY-MM-DD date.")
  }

  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  var currentFD = open("/", directoryFlags)
  guard currentFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open root", code: code)
  }
  defer { _ = close(currentFD) }
  for component in rootComponents {
    let nextFD = component.withCString { openat(currentFD, $0, directoryFlags) }
    guard nextFD >= 0 else {
      let code = errno
      throw secureFsPosixError("open root component", code: code)
    }
    let previousFD = currentFD
    currentFD = nextFD
    _ = close(previousFD)
  }

  let rootIdentity = try secureFsDirectoryIdentity(currentFD)
  var relativeParentFD: Int32?
  defer {
    if let fd = relativeParentFD { _ = close(fd) }
  }
  if !relativeParent.isEmpty {
    let fd = relativeParent.withCString { openat(currentFD, $0, directoryFlags) }
    guard fd >= 0 else {
      let code = errno
      throw secureFsPosixError("open relative parent", code: code)
    }
    relativeParentFD = fd
  }
  let parentIdentity: String?
  if let fd = relativeParentFD {
    parentIdentity = try secureFsDirectoryIdentity(fd)
  } else {
    parentIdentity = nil
  }
  return (rootIdentity, parentIdentity)
}

private func secureManagedRootComponents(_ root: String) throws -> [String] {
  guard root.hasPrefix("/"), root != "/", !root.contains("//"), !root.hasSuffix("/"),
        !root.contains("\u{0000}") else {
    throw secureFsError("The managed-file root must be an absolute canonical path.")
  }
  let components = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  guard !components.isEmpty &&
        components.allSatisfy({ $0 != "." && $0 != ".." && !isSecureFsControl($0) }) else {
    throw secureFsError("The managed-file root contains an unsafe component.")
  }
  return components
}

private func secureOpenManagedRoot(_ components: [String]) throws -> Int32 {
  let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  var currentFD = open("/", directoryFlags)
  guard currentFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open managed-file root", code: code)
  }
  for component in components {
    let nextFD = component.withCString { openat(currentFD, $0, directoryFlags) }
    guard nextFD >= 0 else {
      let code = errno
      _ = close(currentFD)
      throw secureFsPosixError("open managed-file root component", code: code)
    }
    let previousFD = currentFD
    currentFD = nextFD
    _ = close(previousFD)
  }
  return currentFD
}

private func captureManagedFileDirectoryIdentity(root: String) throws -> String {
  let components = try secureManagedRootComponents(root)
  let rootFD = try secureOpenManagedRoot(components)
  defer { _ = close(rootFD) }
  return try secureFsDirectoryIdentity(rootFD)
}

private func secureOpenValidatedManagedRoot(root: String, expectedRootIdentity: String) throws -> Int32 {
  let components = try secureManagedRootComponents(root)
  guard isSecureFsIdentity(expectedRootIdentity) else {
    throw secureFsError("A valid expected managed-file root identity is required.")
  }
  let rootFD = try secureOpenManagedRoot(components)
  do {
    guard try secureFsDirectoryIdentity(rootFD) == expectedRootIdentity else {
      throw secureFsError("The managed-file root directory identity changed.")
    }
  } catch {
    _ = close(rootFD)
    throw error
  }
  return rootFD
}

private func secureCaptureManagedFileLeafIdentity(
  root: String,
  leaf: String,
  expectedRootIdentity: String
) throws -> String {
  guard leaf.utf8.count == 36, isSecureFsUuidComponent(leaf) else {
    throw secureFsError("The managed-file leaf must be a UUID.")
  }
  let rootFD = try secureOpenValidatedManagedRoot(root: root, expectedRootIdentity: expectedRootIdentity)
  defer { _ = close(rootFD) }

  var entryStat = stat()
  let statResult = leaf.withCString {
    fstatat(rootFD, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
  }
  guard statResult == 0 else {
    let code = errno
    throw secureFsPosixError("inspect managed file", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular managed file has an identity.")
  }

  // Open without following symlinks and verify the opened object still matches the inspected entry.
  let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  let entryFD = leaf.withCString { openat(rootFD, $0, flags) }
  guard entryFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open managed file", code: code)
  }
  defer { _ = close(entryFD) }
  var openedStat = stat()
  guard fstat(entryFD, &openedStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect opened managed file", code: code)
  }
  guard (openedStat.st_mode & S_IFMT) == S_IFREG,
        secureFsEntryIdentity(openedStat) == secureFsEntryIdentity(entryStat) else {
    throw secureFsError("The managed file changed while its identity was captured.")
  }
  return secureFsEntryIdentity(openedStat)
}

private func secureFsModifiedTimeMicros(_ fileStat: stat) throws -> Int64 {
  guard let seconds = Int64(exactly: fileStat.st_mtimespec.tv_sec),
        let nanoseconds = Int64(exactly: fileStat.st_mtimespec.tv_nsec),
        nanoseconds >= 0, nanoseconds < 1_000_000_000 else {
    throw secureFsError("The managed-file modification time is outside the supported range.")
  }
  let (wholeMicros, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
  let (modifiedTimeMicros, addOverflow) = wholeMicros.addingReportingOverflow(nanoseconds / 1_000)
  guard !multiplyOverflow, !addOverflow else {
    throw secureFsError("The managed-file modification time is outside the supported range.")
  }
  return modifiedTimeMicros
}

private func secureReadManagedFileChunk(
  root: String,
  leaf: String,
  expectedRootIdentity: String,
  expectedLeafIdentity: String,
  offset: Int64,
  maxBytes: Int64
) throws -> (bytes: Data, fileLength: Int64, modifiedTimeMicros: Int64) {
  guard leaf.utf8.count == 36, isSecureFsUuidComponent(leaf) else {
    throw secureFsError("The managed-file leaf must be a UUID.")
  }
  guard isSecureFsIdentity(expectedLeafIdentity) else {
    throw secureFsError("A valid expected managed-file leaf identity is required.")
  }
  guard offset >= 0, maxBytes >= 1, maxBytes <= 1_048_576 else {
    throw secureFsError("The chunk offset must be nonnegative and maxBytes must be between 1 and 1 MiB.")
  }
  let (_, rangeOverflow) = offset.addingReportingOverflow(maxBytes)
  guard !rangeOverflow else {
    throw secureFsError("The requested managed-file chunk range overflows Int64.")
  }

  let rootFD = try secureOpenValidatedManagedRoot(
    root: root, expectedRootIdentity: expectedRootIdentity)
  defer { _ = close(rootFD) }

  // O_NOFOLLOW rejects a symlink leaf; O_NONBLOCK prevents a raced-in special file from hanging.
  let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  let fileFD = leaf.withCString { openat(rootFD, $0, flags) }
  guard fileFD >= 0 else {
    let code = errno
    throw secureFsPosixError("open managed file for reading", code: code)
  }
  defer { _ = close(fileFD) }

  var initialStat = stat()
  guard fstat(fileFD, &initialStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect opened managed file", code: code)
  }
  guard (initialStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular managed file can be read.")
  }
  guard secureFsEntryIdentity(initialStat) == expectedLeafIdentity else {
    throw secureFsError("The managed-file leaf identity changed.")
  }
  guard let initialLength = Int64(exactly: initialStat.st_size), initialLength >= 0 else {
    throw secureFsError("The managed-file length is outside the supported range.")
  }

  var buffer = [UInt8](repeating: 0, count: offset < initialLength
    ? Int(min(maxBytes, initialLength - offset)) : 0)
  var totalRead = 0
  if !buffer.isEmpty {
    try buffer.withUnsafeMutableBytes { rawBuffer in
      while totalRead < rawBuffer.count {
        let position = off_t(offset + Int64(totalRead))
        let count = pread(
          fileFD,
          rawBuffer.baseAddress!.advanced(by: totalRead),
          rawBuffer.count - totalRead,
          position)
        if count > 0 {
          totalRead += count
        } else if count == 0 {
          break
        } else {
          let code = errno
          if code == EINTR { continue }
          throw secureFsPosixError("read managed-file chunk", code: code)
        }
      }
    }
  }

  // Report metadata from the same opened descriptor used by pread.
  var finalStat = stat()
  guard fstat(fileFD, &finalStat) == 0 else {
    let code = errno
    throw secureFsPosixError("inspect managed file after reading", code: code)
  }
  guard (finalStat.st_mode & S_IFMT) == S_IFREG,
        secureFsEntryIdentity(finalStat) == expectedLeafIdentity,
        secureFsEntryIdentity(finalStat) == secureFsEntryIdentity(initialStat),
        finalStat.st_size == initialStat.st_size,
        finalStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec,
        finalStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec,
        let fileLength = Int64(exactly: finalStat.st_size), fileLength >= 0 else {
    throw secureFsError("The managed-file identity or metadata changed while it was read.")
  }
  return (
    Data(buffer.prefix(totalRead)),
    fileLength,
    try secureFsModifiedTimeMicros(finalStat))
}

private func secureUnlinkManagedFile(
  root: String,
  leaf: String,
  expectedRootIdentity: String,
  expectedLeafIdentity: String
) throws {
  guard leaf.utf8.count == 36, isSecureFsUuidComponent(leaf) else {
    throw secureFsError("The managed-file leaf must be a UUID.")
  }
  guard isSecureFsIdentity(expectedLeafIdentity) else {
    throw secureFsError("A valid expected managed-file leaf identity is required.")
  }

  let rootFD = try secureOpenValidatedManagedRoot(
    root: root, expectedRootIdentity: expectedRootIdentity)
  defer { _ = close(rootFD) }

  var entryStat = stat()
  let statResult = leaf.withCString {
    fstatat(rootFD, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
  }
  if statResult != 0 {
    let code = errno
    if code == ENOENT { return }
    throw secureFsPosixError("inspect managed file", code: code)
  }
  guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
    throw secureFsError("Only a regular managed file can be removed.")
  }
  guard secureFsEntryIdentity(entryStat) == expectedLeafIdentity else {
    throw secureFsError("The managed-file leaf identity changed.")
  }
  // Final name-based unlinkat remains subject to a same-UID race after this check (POSIX limitation).
  let unlinkResult = leaf.withCString { unlinkat(rootFD, $0, 0) }
  if unlinkResult != 0 {
    let code = errno
    if code == ENOENT { return }
    throw secureFsPosixError("unlink managed file", code: code)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var secureFsChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "landrop/secure_fs",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "readManagedFileChunk" {
        guard let arguments = call.arguments as? [String: Any],
              let root = arguments["root"] as? String,
              let leaf = arguments["leaf"] as? String,
              let expectedRootIdentity = arguments["expectedRootIdentity"] as? String,
              let expectedLeafIdentity = arguments["expectedLeafIdentity"] as? String,
              let offset = arguments["offset"] as? Int64,
              let maxBytes = arguments["maxBytes"] as? Int64,
              offset >= 0, maxBytes >= 1, maxBytes <= 1_048_576 else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected root, UUID leaf, identities, nonnegative Int64 offset, and maxBytes in 1...1048576.",
            details: nil))
          return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            let chunk = try secureReadManagedFileChunk(
              root: root,
              leaf: leaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedLeafIdentity: expectedLeafIdentity,
              offset: offset,
              maxBytes: maxBytes)
            let response: [String: Any] = [
              "bytes": FlutterStandardTypedData(bytes: chunk.bytes),
              "fileLength": chunk.fileLength,
              "modifiedTimeMicros": chunk.modifiedTimeMicros,
            ]
            DispatchQueue.main.async { result(response) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      if call.method == "captureManagedFileDirectoryIdentity" {
        guard let arguments = call.arguments as? [String: Any],
              let root = arguments["root"] as? String else {
          result(FlutterError(
            code: "invalid_arguments", message: "Expected a root string.", details: nil))
          return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            let identity = try captureManagedFileDirectoryIdentity(root: root)
            DispatchQueue.main.async { result(["rootIdentity": identity]) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      if call.method == "captureManagedFileLeafIdentity" {
        guard let arguments = call.arguments as? [String: Any],
              let root = arguments["root"] as? String,
              let leaf = arguments["leaf"] as? String,
              let expectedRootIdentity = arguments["expectedRootIdentity"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected root, UUID leaf, and expectedRootIdentity strings.",
            details: nil))
          return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            let identity = try secureCaptureManagedFileLeafIdentity(
              root: root, leaf: leaf, expectedRootIdentity: expectedRootIdentity)
            DispatchQueue.main.async { result(["leafIdentity": identity]) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      if call.method == "unlinkManagedFile" {
        guard let arguments = call.arguments as? [String: Any],
              let root = arguments["root"] as? String,
              let leaf = arguments["leaf"] as? String,
              let expectedRootIdentity = arguments["expectedRootIdentity"] as? String,
              let expectedLeafIdentity = arguments["expectedLeafIdentity"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected root, leaf, expectedRootIdentity, and expectedLeafIdentity strings.",
            details: nil))
          return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            try secureUnlinkManagedFile(
              root: root,
              leaf: leaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedLeafIdentity: expectedLeafIdentity)
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      if call.method == "removeReceiveQuarantine" {
        guard let arguments = call.arguments as? [String: Any],
              let root = arguments["root"] as? String,
              let sessionId = arguments["sessionId"] as? String,
              let expectedRootIdentity = arguments["expectedRootIdentity"] as? String,
              let expectedQuarantineIdentity = arguments["expectedQuarantineIdentity"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected root, sessionId, expectedRootIdentity, and expectedQuarantineIdentity strings.",
            details: nil))
          return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            try secureRemoveReceiveQuarantine(
              root: root,
              sessionId: sessionId,
              expectedRootIdentity: expectedRootIdentity,
              expectedQuarantineIdentity: expectedQuarantineIdentity)
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      guard call.method == "captureReceiveDirectoryIdentity" ||
            call.method == "createReceiveEntry" ||
            call.method == "captureReceiveEntryIdentity" ||
            call.method == "prepareReceiveQuarantine" ||
            call.method == "unlinkReceiveEntry" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let root = arguments["root"] as? String,
            let relativeParent = arguments["relativeParent"] as? String else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected root and relativeParent strings.",
          details: nil))
        return
      }
      if call.method == "captureReceiveDirectoryIdentity" {
        DispatchQueue.global(qos: .utility).async {
          do {
            let identity = try captureSecureFsDirectoryIdentity(
              root: root, relativeParent: relativeParent)
            var response: [String: Any] = ["rootIdentity": identity.rootIdentity]
            if let parentIdentity = identity.parentIdentity {
              response["parentIdentity"] = parentIdentity
            } else {
              response["parentIdentity"] = NSNull()
            }
            DispatchQueue.main.async { result(response) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "secure_fs_error", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }

      guard let leaf = arguments["leaf"] as? String,
            let expectedRootIdentity = arguments["expectedRootIdentity"] as? String,
            arguments.keys.contains("expectedParentIdentity") else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "Expected leaf and directory identity arguments.",
          details: nil))
        return
      }
      let parentIdentityValue = arguments["expectedParentIdentity"]
      guard parentIdentityValue is NSNull || parentIdentityValue is String else {
        result(FlutterError(
          code: "invalid_arguments", message: "Invalid expectedParentIdentity.", details: nil))
        return
      }
      let expectedParentIdentity = parentIdentityValue as? String
      guard (relativeParent.isEmpty && expectedParentIdentity == nil) ||
            (!relativeParent.isEmpty && expectedParentIdentity != nil) else {
        result(FlutterError(
          code: "invalid_arguments",
          message: "expectedParentIdentity must be null exactly when relativeParent is empty.",
          details: nil))
        return
      }
      let expectedLeafIdentity: String?
      let quarantineLeaf: String?
      let quarantineSessionId: String?
      let expectedQuarantineIdentity: String?
      if call.method == "unlinkReceiveEntry" || call.method == "prepareReceiveQuarantine" {
        guard let identity = arguments["expectedLeafIdentity"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected expectedLeafIdentity string.",
            details: nil))
          return
        }
        expectedLeafIdentity = identity
      } else {
        expectedLeafIdentity = nil
      }
      if call.method == "prepareReceiveQuarantine" {
        guard let sessionId = arguments["quarantineSessionId"] as? String,
              let leafName = arguments["quarantineLeaf"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "Expected quarantineSessionId and quarantineLeaf strings.",
            details: nil))
          return
        }
        quarantineSessionId = sessionId
        quarantineLeaf = leafName
        expectedQuarantineIdentity = nil
      } else if call.method == "unlinkReceiveEntry" {
        let quarantineValue = arguments["quarantineLeaf"]
        let sessionValue = arguments["quarantineSessionId"]
        let identityValue = arguments["expectedQuarantineIdentity"]
        guard (quarantineValue == nil || quarantineValue is NSNull || quarantineValue is String),
              (sessionValue == nil || sessionValue is NSNull || sessionValue is String),
              (identityValue == nil || identityValue is NSNull || identityValue is String) else {
          result(FlutterError(
            code: "invalid_arguments", message: "Invalid quarantine identity arguments.", details: nil))
          return
        }
        quarantineLeaf = quarantineValue as? String
        quarantineSessionId = sessionValue as? String
        expectedQuarantineIdentity = identityValue as? String
        guard (quarantineLeaf == nil) == (expectedQuarantineIdentity == nil) else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "quarantineLeaf and expectedQuarantineIdentity must be provided together.",
            details: nil))
          return
        }
      } else {
        quarantineLeaf = nil
        quarantineSessionId = nil
        expectedQuarantineIdentity = nil
      }
      DispatchQueue.global(qos: .utility).async {
        do {
          switch call.method {
          case "createReceiveEntry":
            let identity = try secureCreateReceiveEntry(
              root: root,
              relativeParent: relativeParent,
              leaf: leaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: expectedParentIdentity)
            DispatchQueue.main.async { result(["leafIdentity": identity]) }
          case "captureReceiveEntryIdentity":
            let identity = try secureCaptureReceiveEntryIdentity(
              root: root,
              relativeParent: relativeParent,
              leaf: leaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: expectedParentIdentity)
            DispatchQueue.main.async { result(["leafIdentity": identity]) }
          case "prepareReceiveQuarantine":
            guard let expectedLeafIdentity, let quarantineSessionId, let quarantineLeaf else {
              throw secureFsError("A valid leaf identity, quarantine session UUID, and quarantine leaf are required.")
            }
            let quarantineIdentity = try securePrepareReceiveQuarantine(
              root: root,
              relativeParent: relativeParent,
              leaf: leaf,
              quarantineSessionId: quarantineSessionId,
              quarantineLeaf: quarantineLeaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: expectedParentIdentity,
              expectedLeafIdentity: expectedLeafIdentity)
            DispatchQueue.main.async { result(["quarantineIdentity": quarantineIdentity]) }
          case "unlinkReceiveEntry":
            guard let expectedLeafIdentity else {
              throw secureFsError("A valid expected leaf identity is required.")
            }
            try secureUnlinkReceiveEntry(
              root: root,
              relativeParent: relativeParent,
              leaf: leaf,
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: expectedParentIdentity,
              expectedLeafIdentity: expectedLeafIdentity,
              quarantineLeaf: quarantineLeaf,
              quarantineSessionId: quarantineSessionId,
              expectedQuarantineIdentity: expectedQuarantineIdentity)
            DispatchQueue.main.async { result(nil) }
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "secure_fs_error", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    secureFsChannel = channel
  }
}
