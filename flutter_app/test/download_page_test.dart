import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/download_page.dart';

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
    expect(html, contains('prefers-color-scheme:dark'));
    expect(html, contains('file-card'));
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
    expect(html, contains('<strong>1</strong> 个文件'));
  });
}
