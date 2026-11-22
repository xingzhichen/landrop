import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows receive creation and resume enforce owner-only DACLs', () {
    final nativeFileSystem =
        File('windows/runner/secure_fs.cpp').readAsStringSync();
    final createHelper =
        File('windows/runner/private_receive_entry.cpp').readAsStringSync();
    final securityHelper =
        File('windows/runner/private_receive_security.cpp').readAsStringSync();
    final nativeTest =
        File('windows/runner/secure_fs_acl_test.cpp').readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    final workflow =
        File('../.github/workflows/build-desktop.yml').readAsStringSync();
    final creationStart =
        nativeFileSystem.indexOf('SecureFsResult CreateReceiveEntry(');
    final creationEnd = nativeFileSystem.indexOf(
        'SecureFsResult CaptureReceiveEntryIdentity(', creationStart);

    expect(creationStart, isNonNegative);
    expect(creationEnd, greaterThan(creationStart));
    final creation = nativeFileSystem.substring(creationStart, creationEnd);
    expect(creation, contains('IsReceiveEntryLeaf(leaf)'));
    expect(creation, contains('CreateReceiveEntryRelative('));
    expect(creation, contains('rollback_created_handle(handle_failure)'));
    expect(creation, contains('FileDispositionInfo'));
    final captureStart =
        nativeFileSystem.indexOf('SecureFsResult CaptureReceiveEntryIdentity(');
    final captureEnd = nativeFileSystem.indexOf(
        'SecureFsResult UnlinkReceiveEntry(', captureStart);
    expect(captureStart, isNonNegative);
    expect(captureEnd, greaterThan(captureStart));
    final capture = nativeFileSystem.substring(captureStart, captureEnd);
    final expectedIdentityCheck =
        capture.indexOf('opened_identity != expected_leaf_identity');
    final repairOffset =
        capture.indexOf('EnsurePrivateReceiveFileDacl(file.get())');
    expect(expectedIdentityCheck, isNonNegative);
    expect(repairOffset, greaterThan(expectedIdentityCheck));
    expect(capture, contains('nNumberOfLinks != 1'));
    expect(capture, contains('READ_CONTROL | WRITE_DAC'));

    final publishStart =
        nativeFileSystem.indexOf('SecureFsResult PublishReceiveEntry(');
    final publishEnd = nativeFileSystem.indexOf(
        'SecureFsResult UnlinkReceiveEntry(', publishStart);
    expect(publishStart, isNonNegative);
    expect(publishEnd, greaterThan(publishStart));
    final publish = nativeFileSystem.substring(publishStart, publishEnd);
    expect(publish,
        contains('IsValidReceiveEntryMove(source_leaf, destination_leaf)'));
    expect(nativeFileSystem, contains('source_is_part == destination_is_part'));
    expect(publish, contains('source_identity != expected_leaf_identity'));
    expect(publish, contains('ReplaceIfExists = FALSE'));
    expect(publish, contains('RootDirectory = directory_handles.back().get()'));
    expect(publish, contains('SetFileInformationByHandle('));
    expect(publish,
        contains('ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS'));
    expect(nativeFileSystem, contains('kDirectoryAccess | FILE_ADD_FILE'));
    expect(nativeFileSystem, contains('kReceiveTargetDirectoryAccess'));
    expect(nativeFileSystem, contains('kPinnedShare | FILE_SHARE_WRITE'));
    expect(nativeFileSystem, contains('kReceiveTargetDirectoryShare'));

    expect(createHelper, contains('InitializePrivateReceiveSecurity'));
    expect(
      createHelper,
      contains('attributes.SecurityDescriptor = &private_security.descriptor'),
    );
    expect(securityHelper, contains('AddAccessAllowedAceEx'));
    expect(securityHelper, contains('SetSecurityDescriptorOwner'));
    expect(securityHelper, contains('SetSecurityDescriptorDacl'));
    expect(securityHelper, contains('SE_DACL_PROTECTED'));
    expect(
      securityHelper,
      contains('FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE'),
    );
    expect(securityHelper, contains('EnsurePrivateReceiveFileDacl'));
    expect(securityHelper, contains('SetSecurityInfo(file, SE_FILE_OBJECT'));
    expect(securityHelper, contains('PROTECTED_DACL_SECURITY_INFORMATION'));
    expect(securityHelper, contains('IsPrivateReceiveDacl'));
    expect(nativeTest, contains('CreatePrivateReceiveEntryRelative'));
    expect(nativeTest, contains('TestLegacyPartialRepair'));
    expect(nativeTest, contains('legacy partial with inherited DACL'));
    expect(nativeTest, contains('without WRITE_DAC'));
    expect(nativeTest,
        contains('DACL repair changed the legacy partial file identity'));
    expect(nativeTest, contains('Control file did not inherit'));
    expect(nativeTest, contains('Private file inherited the Everyone ACE'));
    expect(nativeTest, contains('world_is_inherited'));
    expect(nativeTest, contains('owner_ace_is_inherited'));
    expect(nativeTest, contains('FILE_EXECUTE'));
    expect(nativeTest, contains('SE_DACL_PROTECTED'));
    expect(nativeTest,
        contains('FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_TRAVERSE'));
    expect(nativeTest, contains('FILE_SHARE_READ | FILE_SHARE_WRITE'));
    expect(nativeTest, contains('::SetSecurityInfo(\n      legacy.get()'));
    expect(cmake, contains('private_receive_entry.cpp'));
    expect(cmake, contains('private_receive_security.cpp'));
    expect(cmake, contains('secure_fs_acl_test EXCLUDE_FROM_ALL'));
    expect(cmake, contains('"advapi32.lib"'));
    expect(workflow, contains('--target secure_fs_acl_test'));
    expect(workflow, contains('secure_fs_acl_test/secure_fs_acl_test.exe'));
  });
}
