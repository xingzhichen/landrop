import 'dart:convert';
import 'dart:io';

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
    expect(html, contains(':root.theme-dark'));
    expect(html, contains('LanDrop'));
    expect(html, isNot(contains('SHARE SPACE')));
    expect(html, contains('grid-template-columns:minmax(0,1fr) 340px'));
    expect(html, contains('@media(max-width:760px)'));
    expect(html, contains('--primary:#1F2DE6'));
    expect(html, contains('请连接同一 Wi-Fi'));
    expect(html, contains('data-enter'));
    expect(html, contains('href="#top"'));
    expect(html, contains('file-card'));
    expect(html, contains('@keyframes rise'));
    expect(html, contains('id="theme-toggle"'));
    expect(html, contains('download="照片.jpg"'));
  });

  test('renders accessible multi-file upload controls and automatic save help',
      () {
    final html = renderDownloadPage('双向传输', []);
    expect(html, contains('暂无可下载的文件'));
    expect(html, contains('上传至电脑'));
    expect(html, contains('type="file" multiple'));
    expect(html, contains('id="upload-button" type="button" disabled'));
    expect(html, contains('aria-describedby="upload-help"'));
    expect(html, contains('aria-label="上传文件及进度"'));
    expect(html, contains('单文件最大 1 GiB（1,073,741,824 字节）'));
    expect(html, contains('自动保存到电脑的接收目录'));
    expect(html, contains('无需在电脑上逐个确认'));
    expect(html, contains('按顺序逐个上传'));
    expect(html, contains('aria-live="polite"'));
  });

  test('permits only same-origin connections and keeps the rest of CSP strict',
      () {
    final html = renderDownloadPage('安全传输', []);
    expect(
      html,
      contains(
        "default-src 'none'; style-src 'unsafe-inline'; "
        "script-src 'unsafe-inline'; img-src 'none'; font-src 'none'; "
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
    'upload JavaScript uses sequential raw XHR and truthful per-file feedback',
    () {
      final result = Process.runSync('node', [
        '-e',
        'const pageScript = ${jsonEncode(_script(renderDownloadPage('测试', [])))};\n'
            '$_uploadBehaviorTests',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('upload behavior checks passed'));
    },
    skip: _hasNode ? false : 'Node.js unavailable; rendering tests still run',
  );

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

String _script(String html) =>
    RegExp(r'<script>([\s\S]*?)</script>').firstMatch(html)!.group(1)!;

bool get _hasNode {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

const _uploadBehaviorTests = r'''
const assert = require('node:assert/strict');
class Element {
  constructor() {
    this.listeners = {};
    this.attributes = {};
    this.children = [];
    this.disabled = false;
    this.hidden = false;
    this.classList = {toggle() {}, add() {}, remove() {}};
    this.textContent = '';
  }
  set innerHTML(_) { throw new Error('Never insert filenames as markup'); }
  addEventListener(type, callback) {
    (this.listeners[type] ||= []).push(callback);
  }
  emit(type, event = {}) {
    return Promise.all((this.listeners[type] || []).map(fn => fn(event)));
  }
  appendChild(node) { this.children.push(node); }
  setAttribute(name, value) { this.attributes[name] = value; }
  removeAttribute(name) { delete this.attributes[name]; }
}
function setup(options = {}) {
  const elements = {};
  for (const id of ['theme-toggle', 'download-toast', 'upload-files',
      'upload-button', 'upload-panel', 'upload-list', 'upload-summary']) {
    elements[id] = new Element();
  }
  elements['upload-button'].disabled = true;
  const requests = [];
  class XHR extends Element {
    constructor() {
      super();
      this.upload = new Element();
      this.headers = {};
      requests.push(this);
    }
    open(method, url) {
      if (options.throwOpen) throw new Error('Cannot open');
      this.method = method;
      this.url = url;
    }
    setRequestHeader(name, value) { this.headers[name] = value; }
    send(body) {
      if (options.throwSend) throw new Error('Cannot send');
      this.body = body;
    }
  }
  const document = {
    documentElement: new Element(),
    getElementById: id => elements[id],
    createElement: () => new Element(),
    querySelectorAll: () => []
  };
  const window = {matchMedia: () => ({matches: false})};
  new Function('document', 'window', 'XMLHttpRequest', pageScript)(document, window, XHR);
  return {
    elements, requests,
    picker: elements['upload-files'], button: elements['upload-button'],
    panel: elements['upload-panel'], summary: elements['upload-summary'],
    rows: elements['upload-list'].children,
    async choose(files) {
      elements['upload-files'].files = files;
      await elements['upload-files'].emit('change');
    }
  };
}
const state = row => row.attributes['data-state'];
const status = row => row.children[1].textContent;
const progress = row => row.children[2];
async function response(xhr, statusCode, body) {
  xhr.status = statusCode;
  xhr.responseText = typeof body === 'string' ? body : JSON.stringify(body);
  await xhr.emit('load');
}
async function checks() {
  const app = setup();
  const first = {name: '</script><img src=x> 空格 &?#%.txt', size: 123};
  const second = {name: 'max.bin', size: 1073741824};
  await app.choose([first, second]);
  assert.equal(app.rows[0].children[0].textContent, first.name);
  assert.equal(app.requests.length, 0, 'choosing must not upload automatically');
  const done = app.button.emit('click');
  assert.equal(app.requests.length, 1, 'only one request at a time');
  assert.equal(app.picker.disabled, true);
  assert.equal(app.button.disabled, true);
  assert.equal(app.panel.attributes['aria-busy'], 'true');
  await app.button.emit('click');
  assert.equal(app.requests.length, 1, 'double clicks must not start another queue');
  const xhr = app.requests[0];
  assert.equal(xhr.method, 'POST');
  assert.equal(xhr.url, '/upload?name=' + encodeURIComponent(first.name));
  assert.deepEqual(xhr.headers, {'Content-Type': 'application/octet-stream'});
  assert.equal(xhr.body, first, 'send original File, not multipart or JSON');
  await xhr.upload.emit('progress', {lengthComputable: true, loaded: 37, total: 100});
  assert.equal(progress(app.rows[0]).value, 37);
  assert.match(status(app.rows[0]), /37%/);
  await xhr.upload.emit('progress', {lengthComputable: false});
  assert.match(status(app.rows[0]), /正在上传/);
  await xhr.upload.emit('progress', {lengthComputable: true, loaded: 100, total: 100});
  assert.equal(progress(app.rows[0]).value, 100);
  assert.equal(state(app.rows[0]), 'uploading', 'sent does not mean saved');
  assert.match(status(app.rows[0]), /等待电脑确认/);
  assert.equal(app.requests.length, 1);
  const savedName = '<img onerror=evil()>.txt';
  await response(xhr, 201, {name: savedName, size: first.size});
  assert.equal(state(app.rows[0]), 'success');
  assert.ok(status(app.rows[0]).endsWith(savedName), 'server filename is text only');
  assert.equal(app.requests.length, 2);
  assert.equal(app.requests[1].body, second, 'exact 1 GiB limit is accepted');
  await response(app.requests[1], 201, {name: second.name, size: second.size});
  await done;
  assert.equal(state(app.rows[1]), 'success');
  assert.match(app.summary.textContent, /成功 2 个，失败 0 个/);
  assert.equal(app.picker.disabled, false);
  assert.equal(app.picker.value, '', 'allow reselecting the same file');
  assert.equal(app.button.disabled, true, 'must reselect before retrying');
  assert.equal(app.panel.attributes['aria-busy'], 'false');

  const oversized = setup();
  await oversized.choose([{name: 'too-big.bin', size: 1073741825}]);
  assert.equal(oversized.button.disabled, true);
  assert.equal(state(oversized.rows[0]), 'error');
  assert.match(status(oversized.rows[0]), /超过 1 GiB/);
  await oversized.button.emit('click');
  assert.equal(oversized.requests.length, 0);

  const mixed = setup();
  await mixed.choose([
    {name: 'oversized', size: 1073741825},
    {name: 'network-error', size: 2},
    {name: 'empty', size: 0}
  ]);
  const mixedDone = mixed.button.emit('click');
  assert.equal(mixed.requests.length, 1);
  assert.equal(mixed.requests[0].body.name, 'network-error');
  await mixed.requests[0].emit('error');
  assert.equal(state(mixed.rows[1]), 'error');
  assert.equal(mixed.requests.length, 2, 'continue after a failed file');
  await response(mixed.requests[1], 201, {name: 'empty', size: 0});
  await mixedDone;
  assert.match(mixed.summary.textContent, /成功 1 个，失败 2 个/);
  assert.match(mixed.summary.textContent, /失败文件未确认保存/);

  const failures = [
    {code: 200, body: {name: 'x', size: 1}},
    {code: 413, body: '<html>too big</html>'},
    {code: 500, body: {}},
    {code: 201, body: 'not json'},
    {code: 201, body: null},
    {code: 201, body: {name: 'x', size: 0}},
    {code: 201, body: {name: 'x', size: '1'}},
    {code: 201, body: {name: 123, size: 1}},
    {code: 201, body: {name: '', size: 1}},
    {event: 'error'}, {event: 'abort'}, {event: 'timeout'},
    {throwOpen: true}, {throwSend: true}
  ];
  for (const failure of failures) {
    const failedApp = setup(failure);
    await failedApp.choose([{name: 'x', size: 1}]);
    const finished = failedApp.button.emit('click');
    const request = failedApp.requests[0];
    if (failure.event) await request.emit(failure.event);
    else if (failure.code) await response(request, failure.code, failure.body);
    await finished;
    assert.equal(state(failedApp.rows[0]), 'error', JSON.stringify(failure));
    assert.ok(!status(failedApp.rows[0]).includes('上传成功'));
    assert.match(status(failedApp.rows[0]), /未确认保存/);
    assert.equal(progress(failedApp.rows[0]).hidden, true);
    assert.match(failedApp.summary.textContent, /成功 0 个，失败 1 个/);
    assert.equal(failedApp.picker.disabled, false);
    // A late progress/load event must never overwrite a terminal failure.
    await request.upload.emit('progress', {lengthComputable: true, loaded: 1, total: 1});
    await response(request, 201, {name: 'x', size: 1});
    assert.equal(state(failedApp.rows[0]), 'error');
  }
  const empty = setup();
  await empty.choose([]);
  assert.equal(empty.button.disabled, true);
  await empty.button.emit('click');
  assert.equal(empty.requests.length, 0);
  console.log('upload behavior checks passed');
}
checks().catch(error => { console.error(error); process.exitCode = 1; });
''';
