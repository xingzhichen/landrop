import 'dart:io';

import 'package:flutter/services.dart';

/// Opens folders using the host's file manager; never launches a received file.
class DesktopFileManager {
  const DesktopFileManager();

  static const channel = MethodChannel('landrop/file_manager');

  Future<void> openDirectory(String path) async {
    if (!await Directory(path).exists()) {
      throw const FileManagerException('接收文件夹不存在或已被移动。');
    }
    await _invoke('openDirectory', Directory(path).absolute.path);
  }

  Future<void> revealFile(String path) async {
    if (!await File(path).exists()) {
      throw const FileManagerException('文件不存在或已被移动，无法在文件夹中显示。');
    }
    await _invoke('revealFile', File(path).absolute.path);
  }

  Future<void> _invoke(String method, String path) async {
    try {
      await channel.invokeMethod<void>(method, {'path': path});
    } on MissingPluginException {
      throw const FileManagerException('当前平台暂不支持打开系统文件夹。');
    } on PlatformException catch (error) {
      if (error.code == 'not_found') {
        throw const FileManagerException('文件或文件夹不存在，可能已被移动或删除。');
      }
      throw const FileManagerException('无法打开系统文件夹，请检查文件路径和访问权限后重试。');
    }
  }
}

class FileManagerException implements Exception {
  const FileManagerException(this.message);
  final String message;

  @override
  String toString() => message;
}
