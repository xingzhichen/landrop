import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android resumed receive partials verify identity before mode repair',
      () {
    final nativeSource =
        File('android/app/src/main/cpp/secure_fs_jni.cpp').readAsStringSync();
    final kotlinSource = File(
            'android/app/src/main/kotlin/com/xingzhichen/landrop/MainActivity.kt')
        .readAsStringSync();
    final createStart = nativeSource.indexOf('int createReceiveEntry(');
    final createEnd =
        nativeSource.indexOf('int captureReceiveEntryIdentity(', createStart);
    expect(createStart, isNonNegative);
    expect(createEnd, greaterThan(createStart));
    final create = nativeSource.substring(createStart, createEnd);
    expect(create, contains('!isUuidPartLeaf(leaf)'));
    expect(create, contains('ensureReceiveEntryStagingDirectory'));
    expect(create, contains('O_WRONLY | O_CREAT | O_EXCL'));
    expect(create, contains('ScopedUnlinkAt remove_staged_entry'));
    final modeRepair = create.indexOf('::fchmod(entry_fd.get(), 0600)');
    final identityPublish = create.indexOf(
        '*leaf_identity = formatFileIdentity(entry_stat.st_dev, entry_stat.st_ino)');
    final atomicPublish = create.indexOf(
        'renameNoReplace(staging_directory.get(), staging_leaf.c_str()');
    final releaseStage = create.indexOf('remove_staged_entry.release()');
    expect(modeRepair, isNonNegative);
    expect(identityPublish, greaterThan(modeRepair));
    expect(atomicPublish, greaterThan(identityPublish));
    expect(releaseStage, greaterThan(atomicPublish));
    expect(nativeSource, contains('staging_stat.st_mode & 07777) != 0700'));
    expect(
        nativeSource, contains('kStagingDirectory[] = ".landrop-staging-v1"'));
    expect(nativeSource,
        contains('else if ((staging_stat.st_mode & 07777) != 0700)'));

    final captureStart =
        nativeSource.indexOf('int captureReceiveEntryIdentity(');
    final captureEnd =
        nativeSource.indexOf('int renameNoReplace(', captureStart);
    expect(captureStart, isNonNegative);
    expect(captureEnd, greaterThan(captureStart));
    final capture = nativeSource.substring(captureStart, captureEnd);
    final identityCheck =
        capture.indexOf('opened_identity != expected_leaf_identity');
    final chmod = capture.indexOf('::fchmod(entry_fd.get(), 0600)');
    final postStat = capture.indexOf('::fstat(entry_fd.get(), &secured_stat)');
    final linkedStat = capture.indexOf('::fstatat(directories.target_fd()');
    expect(identityCheck, isNonNegative);
    expect(chmod, greaterThan(identityCheck));
    expect(postStat, greaterThan(chmod));
    expect(linkedStat, greaterThan(postStat));
    expect(capture, contains('entry_stat.st_uid != ::geteuid()'));
    expect(capture, contains('entry_stat.st_nlink != 1'));
    expect(capture, contains('(secured_stat.st_mode & 07777) != 0600'));

    expect(nativeSource, contains('expected_leaf_identity_value'));
    expect(kotlinSource, contains('expectedLeafIdentity: String'));
    expect(kotlinSource, contains('expectedLeafIdentity!!'));
    expect(kotlinSource, contains('method == "captureReceiveEntryIdentity"'));

    final controllerSource =
        File('lib/landrop_controller.dart').readAsStringSync();
    final rawCreate = controllerSource.indexOf(
        'final createdIdentity = await SecureReceiveFile.createReceiveEntry(');
    final rawCapture =
        controllerSource.indexOf('final currentLeafIdentity', rawCreate);
    final firstWrite = controllerSource.indexOf(
        'await output.writeFrom(input.current)', rawCapture);
    expect(rawCreate, isNonNegative);
    expect(rawCapture, greaterThan(rawCreate));
    expect(firstWrite, greaterThan(rawCapture));
  });

  test('Android raw receive publication pins source and never replaces target',
      () {
    final nativeSource =
        File('android/app/src/main/cpp/secure_fs_jni.cpp').readAsStringSync();
    final kotlinSource = File(
            'android/app/src/main/kotlin/com/xingzhichen/landrop/MainActivity.kt')
        .readAsStringSync();
    final publishStart = nativeSource.indexOf('int publishReceiveEntry(');
    final publishEnd =
        nativeSource.indexOf('int captureReceiveEntryIdentity(', publishStart);
    expect(publishStart, isNonNegative);
    expect(publishEnd, greaterThan(publishStart));
    final publish = nativeSource.substring(publishStart, publishEnd);
    expect(publish, contains('isUuidPartLeaf(leaf)'));
    expect(publish, contains('isUuidPartLeaf(destination_leaf)'));
    expect(publish, contains('source_is_part == destination_is_part'));
    expect(publish, contains('isSafeLeaf(destination_leaf)'));
    expect(publish, contains('identityMatchesStat(expected_leaf_identity'));
    final sourcePathCheck =
        publish.indexOf('::fstatat(directories.target_fd(), leaf.c_str()');
    final noReplaceMove = publish.indexOf('return renameNoReplace(');
    expect(sourcePathCheck, isNonNegative);
    expect(noReplaceMove, greaterThan(sourcePathCheck));
    expect(publish, contains('destination_leaf.c_str()'));
    expect(kotlinSource, contains('"publishReceiveEntry" ->'));
    expect(kotlinSource, contains('android.system.OsConstants.EEXIST'));
    expect(kotlinSource, contains('result.success(false)'));

    final controllerSource =
        File('lib/landrop_controller.dart').readAsStringSync();
    expect(
        controllerSource, contains('SecureReceiveFile.publishReceiveEntry('));
    expect(controllerSource,
        isNot(contains('temporary.rename(destination.path)')));
  });
}
