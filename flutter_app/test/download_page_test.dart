import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/download_page.dart';
import 'package:path/path.dart' as p;

void main() {
  test('renders a responsive local-only download page', () {
    final html = renderDownloadPage('旅行相册', [
      const DownloadItem(
        id: '15bd1547-cae0-4b5e-9662-2f24b2ef6e89',
        name: '照片.jpg',
        size: 2048,
      ),
    ]);
    expect(html, contains('旅行相册'));
    expect(html, contains('href="/file/15bd1547-cae0-4b5e-9662-2f24b2ef6e89"'));
    expect(html, contains('2 KB'));
    expect(html, contains('prefers-reduced-motion'));
    expect(html, contains(':root.theme-dark'));
    expect(html, contains('LanDrop'));
    expect(html, isNot(contains('SHARE SPACE')));
    expect(html, contains('grid-template-columns:minmax(0,1fr) 340px'));
    expect(html, contains('@media(max-width:760px)'));
    expect(html, contains('--primary:#1F2DE6'));
    expect(html, contains('请连接同一 Wi-Fi'));
    expect(html, contains('data-enter'));
    expect(html, contains('href="#top"'));
    expect(html, contains('id="file-list" role="list" aria-label="可下载文件"'));
    expect(
        html,
        contains(
            'id="file-list-announcement" class="sr-only" role="status" aria-live="polite" aria-atomic="true"'));
    expect(html,
        contains('id="zip-cancel" type="button" aria-label="取消本页 ZIP 下载任务"'));
    expect(html, contains('已完成或被拒绝的任务会被忽略。'));
    expect(html, contains('class="file-card kind-'));
    expect(
        html,
        contains(
            'role="listitem" data-file-id="15bd1547-cae0-4b5e-9662-2f24b2ef6e89"'));
    expect(html, contains('@keyframes rise'));
    expect(html, contains('[data-enter]{animation:rise 260ms'));
    expect(html, contains('@media(hover:hover) and (pointer:fine)'));
    expect(RegExp(r'\.action:hover\{').allMatches(html), hasLength(1));
    expect(html, contains('id="theme-toggle"'));
    expect(html, contains('href="/file/15bd1547-cae0-4b5e-9662-2f24b2ef6e89"'));
    expect(html, isNot(contains('download="照片.jpg"')));
  });

  test('renders accessible multi-file upload controls and automatic save help',
      () {
    final html = renderDownloadPage('双向传输', []);
    expect(html, contains('暂无可下载的文件'));
    expect(html, contains('id="file-empty" role="listitem"'));
    expect(html, contains('上传至电脑'));
    expect(html, contains('type="file" multiple'));
    expect(html, contains('id="upload-button" type="button" disabled'));
    expect(
        html, contains('id="upload-panel" aria-labelledby="upload-heading"'));
    expect(
        html,
        isNot(contains(
            'id="upload-panel" aria-labelledby="upload-heading" aria-busy=')));
    expect(html, contains('aria-describedby="upload-help"'));
    expect(
        html,
        contains(
            'id="upload-recovery-warning" role="status" aria-live="polite" hidden'));
    expect(html, contains('如果浏览器允许'));
    expect(html, contains('aria-label="上传文件及进度"'));
    expect(html, contains('单文件最大 1 GiB（1,073,741,824 字节）'));
    expect(html, contains('未完成上传预留 4 GiB'));
    expect(html, contains('自动保存到电脑的接收目录'));
    expect(html, contains('无需在电脑上逐个确认'));
    expect(html, contains('按顺序逐个上传'));
    expect(html, contains('aria-live="polite"'));
  });

  test('media previews have per-file accessible names and live feedback', () {
    final html = renderDownloadPage('媒体预览', [
      const DownloadItem(
        id: '15bd1547-cae0-4b5e-9662-2f24b2ef6e89',
        name: '毕业照.jpg',
        size: 100,
      ),
      const DownloadItem(
        id: '25bd1547-cae0-4b5e-9662-2f24b2ef6e89',
        name: '行程 <重要> "精选".mp4',
        size: 200,
      ),
    ]);
    expect(html, contains('aria-label="预览 毕业照.jpg"'));
    expect(html, contains('aria-label="预览 行程 &lt;重要&gt; &quot;精选&quot;.mp4"'));
    expect(
        html,
        contains(
            'id="preview-status" class="preview-status" role="status" aria-live="polite" aria-atomic="true"'));
    expect(html, contains('id="preview-media" aria-busy="false"'));
    expect(html, contains('#preview-status:empty{margin:0;min-height:0}'));
  });

  test('permits only same-origin connections and keeps the rest of CSP strict',
      () {
    final html = renderDownloadPage('安全传输', []);
    expect(
      html,
      contains(
        "default-src 'none'; style-src 'unsafe-inline'; "
        "script-src 'unsafe-inline'; img-src 'self'; media-src 'self'; font-src 'none'; "
        "connect-src 'self'; object-src 'none'; base-uri 'none'; "
        "form-action 'none'",
      ),
    );
    expect(html, isNot(contains('innerHTML')));
    expect(html, isNot(contains('FormData')));
    expect(html, isNot(contains('setInterval')));
  });

  test('server values never change the static upload JavaScript', () {
    final clean = renderDownloadPage('普通标题', []);
    final malicious =
        renderDownloadPage('</script><img src=x onerror=evil()>', [
      const DownloadItem(
        id: '15bd1547-cae0-4b5e-9662-2f24b2ef6e89',
        name: '</script><script>evil()</script>\u2028\u2029.txt',
        size: 1,
      ),
    ]);
    expect(_script(malicious), _script(clean));
    expect(malicious, contains('&lt;/script&gt;'));
    expect(malicious, isNot(contains('<img src=x')));
  });

  // Exercise the actual emitted JS without adding a browser or npm dependency.
  // Flutter-only environments still run all rendering/security tests above.
  test(
    'session upload JavaScript exercises actual DOM fetch and raw chunk XHR',
    () {
      final tempDirectory =
          Directory.systemTemp.createTempSync('landrop-download-js-');
      try {
        final pageScript = File(p.join(tempDirectory.path, 'page.js'));
        pageScript.writeAsStringSync(_script(renderDownloadPage('测试', [])));
        final result = Process.runSync(
          'node',
          ['test/web/download_page_behavior.cjs'],
          environment: {'LANDROP_PAGE_SCRIPT_FILE': pageScript.path},
        );
        expect(result.exitCode, 0,
            reason: '${result.stdout}\n${result.stderr}');
        expect(result.stdout, contains('upload behavior checks passed'));
      } finally {
        tempDirectory.deleteSync(recursive: true);
      }
    },
    skip: _hasNode ? false : 'Node.js unavailable; rendering tests still run',
  );

  test('ZIP selection, safe media whitelist and escaped relative paths', () {
    final html = renderDownloadPage('媒体', [
      for (final ext in [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'avif',
        'bmp',
        'mp4',
        'webm',
        'mov',
        'mp3',
        'wav',
        'ogg',
        'm4a',
        'aac',
        'flac',
        'svg',
        'html'
      ])
        DownloadItem(
            id: '15bd1547-cae0-4b5e-9662-2f24b2ef6e89',
            name: 'a.$ext',
            size: 1,
            relativePath: '目录/<img>.$ext'),
    ]);
    expect(html, contains('id="zip-download" href="/download.zip"'));
    expect(html,
        isNot(contains('id="zip-download" href="/download.zip" download')));
    expect(html, contains('id="select-all"'));
    expect(html, contains('目录/&lt;img&gt;'));
    expect(RegExp('class="action preview-button"').allMatches(html).length, 16);
    expect(html, isNot(contains('data-kind="image" data-name="a.svg"')));
    expect(html, isNot(contains('data-kind="image" data-name="a.html"')));
    expect(
        html,
        contains(
            '<dialog id="preview-dialog" aria-labelledby="preview-title"'));
    expect(html, contains('重新选择原文件续传'));
    expect(html, isNot(contains('https://')));
    expect(html, isNot(contains('http://')));
  });

  test('escapes markup and rejects invalid file identifiers', () {
    final html = renderDownloadPage('<script>alert(1)</script>', [
      const DownloadItem(
        id: '15bd1547-cae0-4b5e-9662-2f24b2ef6e89',
        name: '" onmouseover="evil() <a>.txt',
        size: 0,
      ),
      const DownloadItem(id: '../../etc/passwd', name: 'bad', size: 10),
    ]);
    expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(html, isNot(contains('<script>alert(1)</script>')));
    expect(html, contains('&quot; onmouseover=&quot;evil() &lt;a&gt;.txt'));
    expect(html, isNot(contains('../../etc/passwd')));
    expect(html, contains('<strong id="file-count">1</strong> 个文件'));
  });
}

String _script(String html) =>
    RegExp(r'<script>([\s\S]*?)</script>').firstMatch(html)!.group(1)!;

bool get _hasNode {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
