import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Apple receive files clear inherited ACLs before publication', () {
    final appleSources = [
      File('macos/Runner/MainFlutterWindow.swift').readAsStringSync(),
      File('ios/Runner/AppDelegate.swift').readAsStringSync(),
    ];
    final receiveFileSource =
        File('lib/secure_receive_file.dart').readAsStringSync();
    expect(receiveFileSource,
        contains("'expectedLeafIdentity': expectedLeafIdentity"));
    expect(receiveFileSource, contains('identity != expectedLeafIdentity'));
    for (final source in appleSources) {
      final createStart =
          source.indexOf('private func secureCreateReceiveEntry(');
      final createEnd = source.indexOf(
          'private func secureCaptureReceiveEntryIdentity(', createStart);
      expect(createStart, isNonNegative);
      expect(createEnd, greaterThan(createStart));
      final creation = source.substring(createStart, createEnd);
      expect(creation, contains('isSecureFsUuidPartLeaf(leaf)'));
      expect(creation, contains('mkdirat(parentFD'));
      final stageAclOffset =
          creation.indexOf('secureClearExtendedAcl(stagingFD');
      final stagedOpenOffset =
          creation.indexOf('let entryFD = stagingLeaf.withCString');
      final entryAclOffset = creation.indexOf('secureClearExtendedAcl(entryFD');
      final publishOffset = creation.indexOf('renameatx_np');
      expect(stageAclOffset, isNonNegative);
      expect(stagedOpenOffset, greaterThan(stageAclOffset));
      expect(entryAclOffset, greaterThan(stagedOpenOffset));
      expect(publishOffset, greaterThan(entryAclOffset));
      expect(creation, contains('entryStat.st_nlink == 1'));
      expect(creation, contains('entryStat.st_uid == geteuid()'));
      expect(creation, contains('mode_t(0o600)'));
      final publicationCommit = creation.indexOf('entryPublished = true');
      final returnPinnedIdentity = creation.indexOf('return entryIdentity');
      expect(returnPinnedIdentity, greaterThan(publicationCommit));
      expect(creation, contains('identity-pinned capture verifies'));

      final captureStart =
          source.indexOf('private func secureCaptureReceiveEntryIdentity(');
      final captureEnd = source.indexOf(
          'private func secureUnlinkReceiveEntry(', captureStart);
      expect(captureStart, isNonNegative);
      expect(captureEnd, greaterThan(captureStart));
      final capture = source.substring(captureStart, captureEnd);
      expect(capture, contains('entryStat.st_uid == geteuid()'));
      expect(capture, contains('entryStat.st_nlink == 1'));
      final identityPrecheckOffset =
          capture.indexOf('entryIdentity == expectedLeafIdentity');
      final chmodOffset = capture.indexOf('fchmod(entryFD, mode_t(0o600))');
      expect(identityPrecheckOffset, isNonNegative);
      expect(chmodOffset, greaterThan(identityPrecheckOffset));
      expect(capture, contains('fchmod(entryFD, mode_t(0o600))'));
      final aclCheckOffset = capture.indexOf('secureHasExtendedAcl(entryFD');
      final aclClearOffset = capture.indexOf('secureClearExtendedAcl(entryFD');
      final pathCheckOffset = capture.indexOf('fstatat(parentFD');
      expect(aclCheckOffset, isNonNegative);
      expect(aclClearOffset, greaterThan(aclCheckOffset));
      expect(pathCheckOffset, greaterThan(aclClearOffset));
      expect(capture, contains('securedStat.st_mode & mode_t(0o7777)'));
      expect(source, contains('acl_get_fd_np(fd, ACL_TYPE_EXTENDED)'));

      expect(source, contains('secureClearExtendedAcl(quarantineFD'));
      expect(source, contains('secureClearExtendedAcl(sessionFD'));
      expect(creation, contains('UInt32(RENAME_EXCL)'));
      expect(source, contains('acl_init(0)'));
      expect(
          source, contains('acl_set_fd_np(fd, emptyAcl, ACL_TYPE_EXTENDED)'));

      final publishStart =
          source.indexOf('private func securePublishReceiveEntry(');
      final publishEnd = source.indexOf(
          'private func secureCreateReceiveEntry(', publishStart);
      expect(publishStart, isNonNegative);
      expect(publishEnd, greaterThan(publishStart));
      final publish = source.substring(publishStart, publishEnd);
      expect(publish, contains('isSecureFsUuidPartLeaf(leaf)'));
      expect(publish, contains('isSecureFsUuidPartLeaf(destinationLeaf)'));
      expect(publish, contains('sourceIsPartial != destinationIsPartial'));
      expect(publish, contains('isSecureFsSafeLeaf(destinationLeaf)'));
      expect(
          publish,
          contains(
              'secureFsEntryIdentity(openedStat) == expectedLeafIdentity'));
      expect(publish, contains('secureRenameReceiveNoReplace('));
      expect(publish, contains('if code == EEXIST { return false }'));
      expect(source, contains('call.method == "publishReceiveEntry"'));
    }
  });

  for (final configuration in ['Release', 'DebugProfile']) {
    test('$configuration declares file picker read permission', () {
      final plist =
          File('macos/Runner/$configuration.entitlements').readAsStringSync();
      expect(
        RegExp(r'<key>com\.apple\.security\.files\.user-selected\.read-only</key>\s*<true\s*/>')
            .hasMatch(plist),
        isTrue,
        reason:
            'file_picker_darwin checks user-selected entitlements even without App Sandbox',
      );
    });
  }

  test('CI packages with explicit entitlements and verifies the signed app',
      () {
    final workflow =
        File('../.github/workflows/build-desktop.yml').readAsStringSync();
    final script = File('tool/package_macos.sh').readAsStringSync();
    expect(workflow, contains('bash tool/package_macos.sh'));
    expect(
      workflow,
      contains(r'''      - name: Sign and package macOS application
        if: matrix.target == 'macos'
        env:
          TMPDIR: ${{ runner.temp }}
        run: bash tool/package_macos.sh'''),
    );
    expect(script, contains('--entitlements "\$ENTITLEMENTS"'));
    expect(script, contains('codesign -d --entitlements :-'));
    expect(
        script, contains('com.apple.security.files.user-selected.read-only'));
    expect(script, contains('codesign --verify --deep --strict'));
    expect(
      script,
      contains('codesign --verify --deep --strict "\$PACKAGED_APP"'),
    );
    expect(
      script,
      contains('ditto -x -k "\$PACKAGE_OUTPUT" "\$VERIFY_DIR"'),
    );
    expect(
      script,
      contains('temporary directory root must be outside the app bundle'),
    );
    expect(script,
        contains('ZIP extraction lost the user-selected file read permission'));
  });
}
