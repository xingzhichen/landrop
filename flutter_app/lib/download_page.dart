/// A self-contained, same-origin file transfer page. The server should return
/// this document as text/html; charset=utf-8 and serve GET /file/{uuid}.
/// Upload contract: `POST /upload?name=encodeURIComponent(file.name)` with a raw
/// File body and Content-Type: application/octet-stream (not multipart). Enforce
/// the 1 GiB per-file limit server-side too; return 201 JSON {name, size} only
/// after saving the complete file on the computer, or a non-201 failure status.
class DownloadItem {
  final String id;
  final String name;
  final int size;

  const DownloadItem({
    required this.id,
    required this.name,
    required this.size,
  });
}

// Only canonical UUIDs can become URL path segments. Invalid items are omitted
// rather than displayed with a broken or potentially unsafe download link.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String _escapeHtml(String value) {
  // Escape even attribute delimiters; dynamic strings are never put in JS/CSS.
  return value.replaceAllMapped(RegExp(r'[&<>"\x27\x00-\x1f\x7f]'), (match) {
    switch (match.group(0)!) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      case "'":
        return '&#39;';
      default:
        return '&#${match.group(0)!.codeUnitAt(0)};';
    }
  });
}

String _formatSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  final number =
      value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '${number.endsWith('.0') ? number.substring(0, number.length - 2) : number} ${units[unit]}';
}

({String label, String kind, String icon}) _fileType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if ([
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'svg',
    'avif',
  ].contains(ext)) {
    return (label: '图片', kind: 'image', icon: _imageIcon);
  }
  if (['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm'].contains(ext)) {
    return (label: '视频', kind: 'video', icon: _videoIcon);
  }
  if (['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg'].contains(ext)) {
    return (label: '音频', kind: 'audio', icon: _audioIcon);
  }
  if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(ext)) {
    return (label: '压缩包', kind: 'archive', icon: _archiveIcon);
  }
  if (['pdf', 'doc', 'docx', 'txt', 'md', 'rtf', 'pages'].contains(ext)) {
    return (label: '文档', kind: 'document', icon: _documentIcon);
  }
  if (['xls', 'xlsx', 'csv', 'numbers'].contains(ext)) {
    return (label: '表格', kind: 'sheet', icon: _sheetIcon);
  }
  return (label: '文件', kind: 'other', icon: _fileIcon);
}

const _imageIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 16-5.5-5.5L5 21"/></svg>';
const _videoIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="m10 8 6 4-6 4V8Z"/></svg>';
const _audioIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
const _archiveIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M4 8h16M12 3v10m-2 0h4v3h-4z"/></svg>';
const _documentIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM13 2v7h7M8 14h8M8 18h6"/></svg>';
const _sheetIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M9 9v12M9 15h12"/></svg>';
const _fileIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM13 2v7h7"/></svg>';

/// Renders a complete offline-capable mobile web page, without CDN assets.
///
/// `id` must be a canonical UUID; records with invalid IDs are not rendered.
/// Set the response Content-Type to `text/html; charset=utf-8`. The embedded
/// CSP permits inline CSS/JS and same-origin upload connections only; no CDN
/// assets are fetched. All server-provided values stay outside the static JS.
String renderDownloadPage(String title, List<DownloadItem> files) {
  final available =
      files.where((item) => _uuidPattern.hasMatch(item.id)).toList();
  final totalBytes = available.fold<int>(
    0,
    (sum, item) => sum + (item.size < 0 ? 0 : item.size),
  );
  final safeTitle = _escapeHtml(title);
  final count = available.length;
  final html = StringBuffer();
  html.write('''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>$safeTitle · 文件下载</title>
<style>
:root{color-scheme:light;--bg:#f6f8fd;--surface:#fff;--text:#182139;--muted:#727c92;--line:#e9edf5;--shadow:0 18px 45px rgba(49,61,112,.07);--pill:#eff3ff;--pill-text:#5767a0;--focus:#665cef}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%;scroll-behavior:smooth}body{margin:0;min-height:100vh;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;line-height:1.45}button,a{-webkit-tap-highlight-color:transparent}button{font:inherit}a{color:inherit;text-decoration:none}a:focus-visible,button:focus-visible{outline:3px solid var(--focus);outline-offset:3px}
.page{width:min(100%,620px);margin:auto;padding:20px 20px max(44px,env(safe-area-inset-bottom))}.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px;gap:12px}.brand{display:flex;align-items:center;gap:9px;font-size:13px;font-weight:800;letter-spacing:.06em}.brand-mark{display:grid;place-items:center;width:29px;height:29px;border-radius:10px;color:#fff;background:linear-gradient(145deg,#7a62f3,#48b6e8);box-shadow:0 5px 13px rgba(103,103,227,.23)}.brand-mark svg{width:18px;height:18px}.theme-toggle{border:1px solid var(--line);background:var(--surface);color:var(--text);border-radius:13px;width:40px;height:40px;display:grid;place-items:center;cursor:pointer;box-shadow:var(--shadow);transition:transform .2s}.theme-toggle:hover{transform:rotate(-12deg)}.theme-toggle svg{width:19px;height:19px}.theme-toggle .moon{display:block}.theme-toggle .sun{display:none}
.hero{position:relative;overflow:hidden;border-radius:28px;padding:31px 28px 27px;color:#fff;background:linear-gradient(125deg,#735af1 0%,#6478e8 49%,#42bed0 100%);box-shadow:0 19px 45px rgba(89,104,222,.24);isolation:isolate}.hero:before,.hero:after{content:"";position:absolute;border:1px solid rgba(255,255,255,.24);border-radius:50%;pointer-events:none;z-index:-1}.hero:before{width:280px;height:280px;right:-109px;top:-149px;box-shadow:0 0 0 44px rgba(255,255,255,.055),0 0 0 90px rgba(255,255,255,.035)}.hero:after{width:165px;height:165px;right:-95px;bottom:-110px}.eyebrow{font-size:11px;font-weight:800;letter-spacing:.17em;color:rgba(255,255,255,.77);text-transform:uppercase}.hero h1{font-size:clamp(27px,7vw,39px);line-height:1.2;letter-spacing:-.04em;margin:12px 0 10px;overflow-wrap:anywhere}.hero-copy{font-size:14px;color:rgba(255,255,255,.85);margin:0 0 25px}.stats{display:flex;gap:9px;flex-wrap:wrap}.stat{display:flex;align-items:center;gap:8px;padding:9px 13px;border:1px solid rgba(255,255,255,.25);border-radius:12px;background:rgba(255,255,255,.14);font-size:12px;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px)}.stat strong{font-size:14px;color:#fff}.stat svg{width:15px;height:15px;opacity:.85}
.section-heading{display:flex;justify-content:space-between;align-items:baseline;gap:12px;margin:33px 2px 15px}.section-heading h2{font-size:19px;letter-spacing:-.035em;margin:0}.section-heading span{font-size:12px;color:var(--muted)}.file-list{display:grid;gap:11px}.file-card{display:flex;align-items:center;gap:14px;min-width:0;padding:16px;background:var(--surface);border:1px solid var(--line);border-radius:19px;box-shadow:var(--shadow);transition:transform .22s ease,box-shadow .22s ease,border-color .22s ease;animation:rise .48s both;animation-delay:calc(min(var(--i),8)*55ms)}.file-card:hover{transform:translateY(-2px);border-color:#bfc9fb;box-shadow:0 19px 38px rgba(63,77,136,.12)}.file-card:active{transform:scale(.985)}.file-icon{display:grid;flex:none;place-items:center;width:51px;height:51px;border-radius:15px;color:#7261eb;background:#f1efff}.file-icon svg{width:25px;height:25px}.kind-image .file-icon{color:#d36592;background:#fff0f6}.kind-video .file-icon{color:#9b67e6;background:#f5efff}.kind-audio .file-icon{color:#e2a342;background:#fff7e8}.kind-archive .file-icon{color:#e4775f;background:#fff1ed}.kind-document .file-icon{color:#6284e9;background:#eef3ff}.kind-sheet .file-icon{color:#40a888;background:#e9f9f2}.file-info{min-width:0;flex:1}.file-name{display:block;font-size:14px;font-weight:700;overflow-wrap:anywhere;line-height:1.4}.file-meta{display:flex;align-items:center;gap:8px;margin-top:5px;font-size:11px;color:var(--muted)}.file-kind{padding:2px 7px;border-radius:5px;background:var(--pill);color:var(--pill-text);font-weight:600}.download-arrow{flex:none;display:grid;place-items:center;width:35px;height:35px;border-radius:11px;color:#675de6;background:#f1f0ff;transition:background .2s,color .2s}.download-arrow svg{width:17px;height:17px}.file-card:hover .download-arrow{background:#695eea;color:#fff}
.empty{padding:37px 20px;text-align:center;border:1px dashed var(--line);border-radius:19px;background:var(--surface);color:var(--muted);font-size:14px}.empty svg{display:block;width:36px;height:36px;margin:0 auto 12px;color:#9089b1}.footer{margin:28px 0 0;text-align:center;font-size:11px;line-height:1.7;color:var(--muted)}.toast{position:fixed;bottom:max(25px,env(safe-area-inset-bottom));left:50%;width:max-content;max-width:calc(100% - 40px);transform:translate(-50%,20px);opacity:0;pointer-events:none;z-index:5;background:#202944;color:#fff;padding:11px 18px;border-radius:13px;box-shadow:0 14px 35px rgba(16,23,52,.25);font-size:13px;transition:opacity .22s,transform .22s}.toast.show{opacity:1;transform:translate(-50%,0)}@keyframes rise{from{opacity:0;transform:translateY(13px)}to{opacity:1;transform:translateY(0)}}
@media (min-width:700px){.page{padding-top:35px}.hero{padding:39px 37px 35px}.file-card{padding:19px}}@media (prefers-color-scheme:dark){:root:not(.theme-light){color-scheme:dark;--bg:#101421;--surface:#1c2232;--text:#f2f4fc;--muted:#a3adc3;--line:#303a50;--shadow:0 15px 35px rgba(0,0,0,.15);--pill:#303858;--pill-text:#c6d2ff}}:root.theme-dark{color-scheme:dark;--bg:#101421;--surface:#1c2232;--text:#f2f4fc;--muted:#a3adc3;--line:#303a50;--shadow:0 15px 35px rgba(0,0,0,.15);--pill:#303858;--pill-text:#c6d2ff}:root.theme-dark .theme-toggle .moon{display:none}:root.theme-dark .theme-toggle .sun{display:block}@media (prefers-color-scheme:dark){:root:not(.theme-light) .theme-toggle .moon{display:none}:root:not(.theme-light) .theme-toggle .sun{display:block}}:root.theme-light .theme-toggle .moon{display:block}:root.theme-light .theme-toggle .sun{display:none}
@media (prefers-color-scheme:dark){:root:not(.theme-light) .file-icon{background:#303154}:root:not(.theme-light) .download-arrow{background:#31365b;color:#b7b0ff}}:root.theme-dark .file-icon{background:#303154}:root.theme-dark .download-arrow{background:#31365b;color:#b7b0ff}
.upload-panel{padding:22px;background:var(--surface);border:1px solid var(--line);border-radius:22px;box-shadow:var(--shadow);animation:rise .48s both}.upload-help{font-size:13px;color:var(--muted);margin:0 0 16px;line-height:1.7}.upload-controls{display:flex;flex-wrap:wrap;gap:12px;align-items:center}.upload-picker{flex:1;min-width:0;width:100%;color:var(--text);font:inherit;font-size:13px}.upload-picker::file-selector-button,.upload-button{padding:10px 14px;border:0;border-radius:11px;font:inherit;font-weight:700;cursor:pointer}.upload-picker::file-selector-button{margin-right:10px;background:var(--pill);color:var(--pill-text)}.upload-button{background:#695eea;color:#fff;transition:transform .2s,opacity .2s}.upload-button:hover:not(:disabled){transform:translateY(-2px)}.upload-button:disabled{opacity:.5;cursor:not-allowed}.upload-picker:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.upload-summary{color:var(--muted);font-size:12px;margin:14px 0 0}.upload-list{list-style:none;padding:0;margin:0}.upload-item{padding-top:15px;margin-top:15px;border-top:1px solid var(--line);min-width:0}.upload-name{display:block;overflow-wrap:anywhere;font-size:14px;font-weight:700}.upload-status{display:block;font-size:12px;color:var(--muted);margin-top:5px;overflow-wrap:anywhere}.upload-item[data-state="success"] .upload-status{color:#258365}.upload-item[data-state="error"] .upload-status{color:#ce505d}.upload-progress{display:block;width:100%;height:7px;margin-top:9px;accent-color:#8173f5}.upload-progress[hidden]{display:none}@media (prefers-color-scheme:dark){:root:not(.theme-light) .upload-item[data-state="success"] .upload-status{color:#78dcbc}:root:not(.theme-light) .upload-item[data-state="error"] .upload-status{color:#ff969f}}:root.theme-dark .upload-item[data-state="success"] .upload-status{color:#78dcbc}:root.theme-dark .upload-item[data-state="error"] .upload-status{color:#ff969f}
@media (prefers-reduced-motion:reduce){*,*:before,*:after{animation-duration:.01ms!important;animation-delay:0ms!important;transition-duration:.01ms!important;scroll-behavior:auto!important}}
</style>
</head>
<body>
<main class="page">
<div class="topbar"><div class="brand"><span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m-4-4 4 4 4-4M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg></span> SHARE SPACE</div><button class="theme-toggle" id="theme-toggle" type="button" aria-label="切换深色模式" aria-pressed="false"><svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.5 14.4A9 9 0 0 1 9.6 3.5 9 9 0 1 0 20.5 14.4Z"/></svg><svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg></button></div>
<section class="hero" aria-labelledby="page-title"><div class="eyebrow">YOUR FILES ARE READY</div><h1 id="page-title">$safeTitle</h1><p class="hero-copy">文件已准备就绪，轻点下方卡片即可保存到设备。</p><div class="stats"><div class="stat"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8"/></svg><strong>$count</strong> 个文件</div><div class="stat"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>总计 <strong>${_formatSize(totalBytes)}</strong></div></div></section>
<div class="section-heading"><h2>文件列表</h2><span>轻点文件下载</span></div>
<section class="file-list" aria-label="可下载文件">
''');
  if (available.isEmpty) {
    html.write('''<div class="empty">$_fileIcon暂无可下载的文件</div>\n''');
  }
  for (var i = 0; i < available.length; i++) {
    final file = available[i];
    final type = _fileType(file.name);
    final safeName = _escapeHtml(file.name);
    final safeId =
        file.id.toLowerCase(); // Already UUID-validated, safe in a URL.
    final size = _formatSize(file.size);
    html.write(
      '''<a class="file-card kind-${type.kind}" style="--i:$i" href="/file/$safeId" download="$safeName" aria-label="下载 $safeName">
<span class="file-icon">${type.icon}</span><span class="file-info"><span class="file-name">$safeName</span><span class="file-meta"><span class="file-kind">${type.label}</span><span>$size</span></span></span><span class="download-arrow" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m-4-4 4 4 4-4M4 19h16"/></svg></span></a>\n''',
    );
  }
  html.write('''</section>
<div class="section-heading"><h2 id="upload-heading">上传至电脑</h2><span>手机 → 电脑</span></div>
<section class="upload-panel" id="upload-panel" aria-labelledby="upload-heading" aria-busy="false">
<p class="upload-help" id="upload-help">可多选文件，按顺序逐个上传，单文件最大 1 GiB（1,073,741,824 字节）。上传成功后文件会自动保存到电脑的接收目录，无需在电脑上逐个确认；请以每个文件的成功或失败反馈为准。请保持页面打开，勿在传输时刷新。</p>
<div class="upload-controls"><input class="upload-picker" id="upload-files" type="file" multiple aria-label="选择上传到电脑的文件" aria-describedby="upload-help"><button class="upload-button" id="upload-button" type="button" disabled>上传到电脑</button></div>
<p class="upload-summary" id="upload-summary" role="status" aria-live="polite">选择文件后，点击上传到电脑。</p>
<ul class="upload-list" id="upload-list" aria-label="上传文件及进度"></ul>
<noscript><p class="upload-help">上传功能需要启用 JavaScript；文件下载仍可直接使用。</p></noscript>
</section><p class="footer">文件通过此电脑的本地服务传输 · 无需安装其他应用</p></main>
<div class="toast" id="download-toast" role="status" aria-live="polite"></div>
<script>
(function () {
  'use strict';
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');
  var toast = document.getElementById('download-toast');
  var timer;
  var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  toggle.setAttribute('aria-pressed', String(!!dark));
  toggle.setAttribute('aria-label', dark ? '切换浅色模式' : '切换深色模式');
  toggle.addEventListener('click', function () {
    dark = !dark;
    root.classList.toggle('theme-dark', dark);
    root.classList.toggle('theme-light', !dark);
    toggle.setAttribute('aria-pressed', String(dark));
    toggle.setAttribute('aria-label', dark ? '切换浅色模式' : '切换深色模式');
  });
  var maxUploadBytes = 1024 * 1024 * 1024;
  var picker = document.getElementById('upload-files');
  var uploadButton = document.getElementById('upload-button');
  var uploadPanel = document.getElementById('upload-panel');
  var uploadList = document.getElementById('upload-list');
  var summary = document.getElementById('upload-summary');
  var entries = [];
  var busy = false;

  function setState(entry, state, message) {
    entry.row.setAttribute('data-state', state);
    entry.status.textContent = message;
  }

  picker.addEventListener('change', function () {
    if (busy) return;
    entries = [];
    uploadList.textContent = '';
    var files = Array.from(picker.files || []);
    files.forEach(function (file) {
      var row = document.createElement('li');
      row.className = 'upload-item';
      var name = document.createElement('span');
      name.className = 'upload-name';
      name.textContent = file.name;
      var status = document.createElement('span');
      status.className = 'upload-status';
      status.setAttribute('aria-live', 'polite');
      var progress = document.createElement('progress');
      progress.className = 'upload-progress';
      progress.max = 100;
      progress.value = 0;
      progress.hidden = true;
      progress.setAttribute('aria-label', file.name + ' 上传进度');
      row.appendChild(name);
      row.appendChild(status);
      row.appendChild(progress);
      uploadList.appendChild(row);
      var entry = {file: file, row: row, status: status, progress: progress};
      entries.push(entry);
      if (file.size > maxUploadBytes) {
        setState(entry, 'error', '无法上传：单文件超过 1 GiB 限制。');
      } else {
        setState(entry, 'pending', '等待上传');
      }
    });
    uploadButton.disabled = !entries.some(function (entry) { return entry.file.size <= maxUploadBytes; });
    summary.textContent = files.length ? '已选择 ' + files.length + ' 个文件，超限文件不会上传。' : '选择文件后，点击上传到电脑。';
  });

  function uploadOne(entry) {
    return new Promise(function (resolve) {
      var file = entry.file;
      var xhr = new XMLHttpRequest();
      var finished = false;
      entry.progress.hidden = false;
      entry.progress.removeAttribute('value');
      setState(entry, 'uploading', '正在连接电脑…');
      function finish(success, message) {
        if (finished) return;
        finished = true;
        if (success) entry.progress.value = 100;
        else entry.progress.hidden = true;
        setState(entry, success ? 'success' : 'error', message);
        resolve(success);
      }
      xhr.upload.addEventListener('progress', function (event) {
        if (finished) return;
        if (event.lengthComputable && event.total > 0) {
          var percent = Math.min(100, Math.max(0, Math.floor(event.loaded / event.total * 100)));
          entry.progress.value = percent;
          setState(entry, 'uploading', percent === 100 ? '已发送 100%，等待电脑确认保存…' : '正在上传 ' + percent + '%');
        } else {
          entry.progress.removeAttribute('value');
          setState(entry, 'uploading', '正在上传…');
        }
      });
      xhr.addEventListener('load', function () {
        if (xhr.status !== 201) {
          finish(false, '上传失败（HTTP ' + xhr.status + '），未确认保存，请重新选择文件重试。');
          return;
        }
        try {
          var saved = JSON.parse(xhr.responseText);
          if (!saved || typeof saved.name !== 'string' || !saved.name.length ||
              typeof saved.size !== 'number' || saved.size !== file.size) {
            throw new Error('Invalid upload response');
          }
          finish(true, '上传成功，已自动保存到电脑：' + saved.name);
        } catch (_) {
          finish(false, '电脑返回的保存信息无效，未确认保存，请检查电脑后重试。');
        }
      });
      xhr.addEventListener('error', function () {
        finish(false, '上传失败：网络连接中断，未确认保存，请检查连接后重试。');
      });
      xhr.addEventListener('abort', function () {
        finish(false, '上传已取消，未确认保存。');
      });
      xhr.addEventListener('timeout', function () {
        finish(false, '上传超时，未确认保存，请检查电脑后重试。');
      });
      try {
        xhr.open('POST', '/upload?name=' + encodeURIComponent(file.name));
        xhr.setRequestHeader('Content-Type', 'application/octet-stream');
        xhr.send(file);
      } catch (_) {
        finish(false, '无法开始上传，未确认保存，请检查连接后重试。');
      }
    });
  }

  uploadButton.addEventListener('click', async function () {
    if (busy || uploadButton.disabled) return;
    busy = true;
    picker.disabled = true;
    uploadButton.disabled = true;
    uploadButton.textContent = '上传中…';
    uploadPanel.setAttribute('aria-busy', 'true');
    var succeeded = 0;
    var failed = 0;
    for (var index = 0; index < entries.length; index++) {
      var entry = entries[index];
      summary.textContent = '正在处理第 ' + (index + 1) + ' / ' + entries.length + ' 个文件，请保持页面打开。';
      if (entry.file.size > maxUploadBytes) {
        failed++;
        continue;
      }
      if (await uploadOne(entry)) succeeded++;
      else failed++;
    }
    summary.textContent = '处理完成：成功 ' + succeeded + ' 个，失败 ' + failed + ' 个。' + (failed ? '失败文件未确认保存，可重新选择后重试。' : '文件已自动保存到电脑。');
    busy = false;
    picker.disabled = false;
    picker.value = '';
    uploadButton.textContent = '上传到电脑';
    uploadPanel.setAttribute('aria-busy', 'false');
  });

  var cards = document.querySelectorAll('.file-card');
  for (var i = 0; i < cards.length; i++) {
    cards[i].addEventListener('click', function () {
      toast.textContent = '正在准备下载…';
      toast.classList.add('show');
      window.clearTimeout(timer);
      timer = window.setTimeout(function () { toast.classList.remove('show'); }, 2600);
    });
  }
}());
</script>
</body></html>''');
  return html.toString();
}
