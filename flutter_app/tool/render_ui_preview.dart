// Generates static examples of the actual server-rendered page for visual QA.
// Fixture names and sizes below are only used by this developer tool.
import 'dart:io';
import 'package:landrop/download_page.dart';

void main(List<String> args) {
  final output = Directory(args.isEmpty ? '../.tmp/ui-preview' : args.first)
    ..createSync(recursive: true);
  const files = [
    DownloadItem(
        id: '00000000-0000-4000-8000-000000000001',
        name: '周末旅行照片.zip',
        size: 148478361),
    DownloadItem(
        id: '00000000-0000-4000-8000-000000000002',
        name: '海边的日落.jpg',
        size: 5242880),
    DownloadItem(
        id: '00000000-0000-4000-8000-000000000003',
        name: '行程与预订信息.pdf',
        size: 854016),
    DownloadItem(
        id: '00000000-0000-4000-8000-000000000004',
        name: '旅行短片.mp4',
        size: 68478622),
  ];
  final examples = {
    'index.html': renderDownloadPage('周末旅行', files),
    'empty.html': renderDownloadPage('临时传输', const []),
    'stress.html': renderDownloadPage('一个很长的传输页面名称与文件标题用于验证窄屏排版不会溢出', [
      const DownloadItem(
          id: '00000000-0000-4000-8000-000000000001',
          name:
              'long-unbroken-file-name-abcdefghijklmnopqrstuvwxyz-0123456789.zip',
          size: 0),
      ...files,
    ]),
  };
  for (final entry in examples.entries) {
    File('${output.path}/${entry.key}').writeAsStringSync(entry.value);
  }
  stdout.writeln(
      'Rendered ${examples.length} transfer page examples to ${output.path}');
}
