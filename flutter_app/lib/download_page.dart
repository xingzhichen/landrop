/// A self-contained, same-origin download page. The server should return this
/// document as text/html; charset=utf-8 and serve files at `GET /file/{uuid}`.
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
/// CSP permits only inline CSS/JS; no network resources are fetched by the page.
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
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
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
  html.write('''</section><p class="footer">仅从此设备的本地服务下载 · 无需安装其他应用</p></main>
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
