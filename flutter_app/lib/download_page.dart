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

// Plain file-category labels, not imitations of third-party product logos.
const _imageIcon = 'IMG';
const _videoIcon = 'VID';
const _audioIcon = 'AUD';
const _archiveIcon = 'ZIP';
const _documentIcon = 'DOC';
const _sheetIcon = 'XLS';
const _fileIcon = 'FILE';

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
<html lang="zh-CN" data-type="software" data-radius="soft" data-motion="on">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="page-type" content="software">
<meta name="site-kind" content="software">
<meta name="theme-color" content="#EEF0F3">
<meta name="description" content="通过 LanDrop 在同一 Wi-Fi 下下载电脑分享的文件，或将文件上传至电脑。">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>$safeTitle · LanDrop 文件传输</title>
<style>
:root{color-scheme:light;--bg:#EEF0F3;--surface:#fff;--text:#0B0C0E;--muted:#626975;--line:#DDE1E7;--primary:#1F2DE6;--primary-hover:#1823B9;--soft:#E8EBFF;--focus:#1F2DE6;--error:#AB3D37;--ease:cubic-bezier(.2,.8,.2,1)}

*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;scroll-behavior:auto}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--text);font-family:"Geist",-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;font-size:16px;line-height:1.6}
button,input{font:inherit}
button,a,input{-webkit-tap-highlight-color:transparent}
a{color:inherit;text-decoration:none}
button{cursor:pointer}
a:focus-visible,button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--focus);outline-offset:4px}
svg{display:block;width:20px;height:20px;flex:none}
p,h1,h2{margin:0}
button:disabled{cursor:not-allowed}

.wrap{width:min(1200px,calc(100% - 64px));margin-inline:auto}
.topbar{border-bottom:1px solid var(--line);background:var(--surface)}
.topbar-inner{position:relative;min-height:80px;display:flex;align-items:center;justify-content:space-between;gap:24px}
.brand{font-size:24px;font-weight:650;letter-spacing:-1px;line-height:1}
.brand span{color:var(--primary)}
.brand-context{margin-right:auto;padding-left:24px;border-left:1px solid var(--line);font-size:13px;color:var(--muted)}
.theme-toggle{display:flex;align-items:center;justify-content:center;width:44px;height:44px;flex:none;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--muted);transition:transform 150ms var(--ease),background 150ms var(--ease),color 150ms var(--ease)}
.theme-toggle .sun{display:none}
.skip-link{position:absolute;left:0;top:8px;z-index:10;padding:12px 16px;background:var(--text);color:var(--surface);border-radius:8px;transform:translateY(-150%)}
.skip-link:focus{transform:none}

.page{padding-top:48px;padding-bottom:max(32px,env(safe-area-inset-bottom))}
.hero{display:flex;align-items:flex-end;justify-content:space-between;gap:32px;margin-bottom:32px}
.hero-text{min-width:0}
.eyebrow{font-size:13px;color:var(--primary);font-weight:500;margin-bottom:8px}
.hero h1{font-size:clamp(30px,3.4vw,44px);font-weight:550;line-height:1.22;letter-spacing:-1.5px;overflow-wrap:anywhere;max-width:760px}
.hero-copy{font-size:16px;color:var(--muted);margin-top:12px}
.stats{flex:none;color:var(--muted);font-size:13px;text-align:right;padding-bottom:4px}
.stat strong{color:var(--text);font-size:16px;font-weight:550}
.stat+.stat{margin-top:4px}
.workspace{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:24px;align-items:start}
.download-panel,.upload-panel{min-width:0;border:1px solid var(--line);border-radius:12px;background:var(--surface)}
.section-heading{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:24px;border-bottom:1px solid var(--line)}
.section-heading h2,.upload-panel h2{font-size:18px;font-weight:550;line-height:1.45;letter-spacing:-.4px}
.section-heading span{font-size:13px;color:var(--muted)}
.file-list{padding:8px 16px}
.file-card{display:flex;align-items:center;gap:16px;padding:16px 8px;min-width:0;border-bottom:1px solid var(--line);border-radius:8px;transition:transform 180ms var(--ease),background 150ms var(--ease)}
.file-card:last-child{border-bottom-color:transparent}
.file-icon{display:grid;place-items:center;flex:none;width:48px;height:52px;border-radius:8px;background:#EFF2F3;color:#56616B;font-size:13px;letter-spacing:.3px;font-weight:650}
.kind-image .file-icon{background:#FBEFED;color:#A34D3F}
.kind-video .file-icon{background:#EDF2FC;color:#4569A6}
.kind-audio .file-icon{background:#F9F1DF;color:#8B671F}
.kind-archive .file-icon{background:#F8EDDF;color:#936021}
.kind-document .file-icon{background:#ECF2F9;color:#426990}
.kind-sheet .file-icon{background:#E9F4ED;color:#35724D}
.file-info{min-width:0;flex:1}
.file-name{display:block;font-size:16px;font-weight:500;line-height:1.5;overflow-wrap:anywhere}
.file-meta{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:4px;font-size:13px;color:var(--muted)}
.file-kind::after{content:"·";padding-left:8px}
.download-arrow{display:flex;align-items:center;justify-content:center;gap:8px;flex:none;min-width:44px;min-height:44px;padding:8px 12px;border:1px solid var(--line);border-radius:8px;color:var(--primary);font-size:13px;font-weight:500;transition:background 150ms var(--ease),color 150ms var(--ease),border-color 150ms var(--ease)}
.download-arrow svg{width:16px;height:16px}
.empty{padding:48px 24px;color:var(--muted);text-align:center;font-size:16px}
.empty-mark{display:grid;place-items:center;width:56px;height:56px;border-radius:12px;background:var(--soft);color:var(--primary);margin:0 auto 16px;font-size:13px;font-weight:550}
.empty p+p{font-size:13px;margin-top:8px}
.download-note{border-top:1px solid var(--line);padding:16px 24px;font-size:13px;color:var(--muted)}

.upload-panel{padding:24px}
.upload-direction{display:flex;align-items:center;gap:8px;color:var(--primary);font-size:13px;margin-bottom:12px}
.upload-intro{font-size:14px;color:var(--muted);margin:8px 0 24px;line-height:1.7}
.upload-controls{display:flex;flex-direction:column;gap:16px}
.picker-label{font-size:14px;font-weight:500;display:block;margin-bottom:8px}
.upload-picker{width:100%;min-width:0;min-height:48px;color:var(--muted);font-size:13px;border:1px solid var(--line);border-radius:8px;padding:8px;background:var(--bg)}
.upload-picker::file-selector-button{min-height:32px;padding:4px 12px;margin-right:8px;border:0;border-radius:4px;background:var(--surface);color:var(--text);font:inherit;font-weight:500;cursor:pointer;transition:background 150ms var(--ease)}
.upload-button{display:flex;justify-content:center;align-items:center;width:100%;min-height:48px;border:1px solid transparent;border-radius:8px;padding:12px 16px;background:var(--primary);color:#fff;font-size:14px;font-weight:500;transition:transform 150ms var(--ease),background 150ms var(--ease)}
.upload-button:disabled{background:var(--soft);color:var(--muted);border-color:var(--line)}
.upload-summary{color:var(--muted);font-size:13px;margin-top:16px;overflow-wrap:anywhere}
.upload-details{border-top:1px solid var(--line);margin-top:24px;padding-top:16px}
.upload-details summary{font-size:13px;color:var(--muted);cursor:pointer;min-height:44px;display:list-item;align-content:center;list-style-position:inside}
.upload-help{font-size:13px;color:var(--muted);line-height:1.8;margin-top:8px;overflow-wrap:anywhere}
.upload-limit{font-size:13px;color:var(--muted);margin-top:8px}
.upload-list{list-style:none;padding:0;margin:0}
.upload-item{padding:16px 0;border-bottom:1px solid var(--line);min-width:0}
.upload-item:last-child{border-bottom:0;padding-bottom:0}
.upload-name{display:block;overflow-wrap:anywhere;font-size:14px;font-weight:500}
.upload-status{display:block;font-size:13px;color:var(--muted);margin-top:4px;overflow-wrap:anywhere}
.upload-item[data-state="success"] .upload-status{color:var(--primary)}
.upload-item[data-state="error"] .upload-status{color:var(--error)}
.upload-item[data-state="uploading"] .upload-status{color:var(--primary)}
.upload-progress{display:block;width:100%;height:6px;border:0;border-radius:4px;overflow:hidden;margin-top:12px;accent-color:var(--primary);background:var(--soft)}
.upload-progress::-webkit-progress-bar{background:var(--soft);border-radius:4px}
.upload-progress::-webkit-progress-value{background:var(--primary);border-radius:4px}
.upload-progress::-moz-progress-bar{background:var(--primary);border-radius:4px}
.upload-progress[hidden]{display:none}

.network-note{display:flex;align-items:flex-start;gap:12px;margin-top:24px;padding:16px 0;color:var(--muted);font-size:13px}
.network-note svg{width:18px;height:18px;margin-top:2px}
.network-note strong{font-weight:500;color:var(--text)}
.footer{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;border-top:1px solid var(--line);margin-top:32px;padding-top:24px;font-size:13px;color:var(--muted)}
.toast{position:fixed;bottom:max(24px,env(safe-area-inset-bottom));left:50%;width:max-content;max-width:calc(100% - 32px);transform:translate(-50%,12px);opacity:0;pointer-events:none;z-index:5;background:var(--text);color:var(--surface);padding:12px 16px;border-radius:8px;font-size:14px;transition:opacity 150ms var(--ease),transform 150ms var(--ease)}
.toast.show{opacity:1;transform:translate(-50%,0)}
[data-enter]{animation:rise 520ms cubic-bezier(.22,1,.36,1) both}
@keyframes rise{from{opacity:.5;transform:translateY(12px)}
to{opacity:1;transform:translateY(0)}
}

@media(hover:hover) and (pointer:fine){.theme-toggle:hover{background:var(--soft);color:var(--primary);transform:translateY(-1px)}
.file-card:hover{background:var(--bg);transform:translateY(-2px)}
.file-card:hover .download-arrow{background:var(--primary);border-color:var(--primary);color:#fff}
.upload-button:hover:not(:disabled){background:var(--primary-hover);transform:translateY(-1px)}
.upload-picker::file-selector-button:hover{background:var(--soft)}
.upload-details summary:hover{color:var(--primary)}
}
.theme-toggle:active,.upload-button:active:not(:disabled){transform:translateY(1px) scale(.985)}
.file-card:active{background:var(--soft)}

:root.theme-dark{color-scheme:dark;--bg:#14171F;--surface:#1D222D;--text:#F1F3F8;--muted:#B1B9C9;--line:#354054;--primary:#A7B5FF;--primary-hover:#C0CAFF;--soft:#29334C;--focus:#A7B5FF;--error:#FFA89F}
:root.theme-dark .theme-toggle .moon{display:none}
:root.theme-dark .theme-toggle .sun{display:block}
:root.theme-dark .upload-button:not(:disabled){color:#14171F}
:root.theme-dark .file-card:hover .download-arrow{color:#14171F}

@media(max-width:1000px){.workspace{grid-template-columns:minmax(0,1fr) 300px}
.wrap{width:calc(100% - 48px)}
.section-heading,.upload-panel{padding:20px}
.download-arrow{padding:8px}
.download-label{display:none}
.file-list{padding-inline:12px}
.file-card{gap:12px}
}

@media(max-width:760px){.wrap{width:calc(100% - 40px)}
.topbar-inner{min-height:64px;gap:16px}
.brand{font-size:22px}
.brand-context{padding-left:16px;font-size:13px}
.page{padding-top:32px}
.hero{display:block;margin-bottom:24px}
.hero h1{font-size:32px;letter-spacing:-1px}
.hero-copy{font-size:14px}
.stats{display:flex;gap:16px;flex-wrap:wrap;text-align:left;margin-top:16px;padding:0}
.stat+.stat{margin:0}
.workspace{grid-template-columns:minmax(0,1fr);gap:24px}
.section-heading{padding:20px}
.file-card{padding:16px 4px}
.file-list{padding:0 12px}
.file-name{font-size:15px}
.file-icon{width:40px;height:48px;font-size:13px}
.download-arrow{width:44px;height:44px;padding:8px}
.upload-panel{padding:24px}
.upload-intro{margin-bottom:20px}
.network-note{margin-top:20px}
.footer{margin-top:24px;padding-top:20px;gap:8px}
.footer span{display:block;width:100%}
}

@media(max-width:360px){.wrap{width:calc(100% - 32px)}
.brand-context{display:none}
.section-heading{padding:16px}
.section-heading span{font-size:13px}
.upload-panel{padding:20px}
.file-card{gap:8px}
}

@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}
.file-card:hover,.theme-toggle:hover,.upload-button:hover:not(:disabled),.theme-toggle:active,.upload-button:active:not(:disabled){transform:none}
}

</style>
</head>
<body>
<!-- Software / existing LAN transfer utility. The actual file list is the product,
     not a marketing mock. Brief overrides: compact content-led height, no full-screen
     hero, story sections, dealt spectacle, external fonts, kit assets or images.
     Deal: cool-grey-cobalt; Geist / Geist Mono with offline system fallback.
     Collage hero and counter-roll moment waived for direct file-task access.
     One once-only title entrance; no decorative infinite motion.
     Voice: technical-dry, plain Chinese actions; no unverified connection claims. -->
<header class="topbar"><div class="wrap topbar-inner"><a class="skip-link" href="#top">跳转到文件传输</a><div class="brand" aria-label="LanDrop">Lan<span>Drop</span></div><span class="brand-context">局域网文件传输</span><button class="theme-toggle" id="theme-toggle" type="button" aria-label="切换深色模式" aria-pressed="false"><svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.5 14.4A9 9 0 0 1 9.6 3.5 9 9 0 1 0 20.5 14.4Z"/></svg><svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg></button></div></header>
<main class="page wrap" id="top">
<section class="hero" data-enter aria-labelledby="page-title"><div class="hero-text"><p class="eyebrow">电脑分享的文件</p><h1 id="page-title">$safeTitle</h1><p class="hero-copy">下载到当前设备，或把文件上传至电脑。</p></div><div class="stats" aria-label="分享文件统计"><div class="stat"><strong>$count</strong> 个文件</div><div class="stat">总计 <strong>${_formatSize(totalBytes)}</strong></div></div></section>
<div class="workspace">
<section class="download-panel" aria-labelledby="download-heading"><div class="section-heading"><h2 id="download-heading">下载文件</h2><span>点击文件即可下载</span></div>
<div class="file-list" aria-label="可下载文件">
''');
  if (available.isEmpty) {
    html.write(
        '''<div class="empty"><span class="empty-mark" aria-hidden="true">FILE</span><p>暂无可下载的文件</p><p>请在电脑上添加要分享的文件。</p></div>\n''');
  }
  for (var i = 0; i < available.length; i++) {
    final file = available[i];
    final type = _fileType(file.name);
    final safeName = _escapeHtml(file.name);
    final safeId =
        file.id.toLowerCase(); // Already UUID-validated, safe in a URL.
    final size = _formatSize(file.size);
    html.write(
      '''<a class="file-card kind-${type.kind}" href="/file/$safeId" download="$safeName" aria-label="下载 $safeName">
<span class="file-icon" aria-hidden="true">${type.icon}</span><span class="file-info"><span class="file-name">$safeName</span><span class="file-meta"><span class="file-kind">${type.label}</span><span>$size</span></span></span><span class="download-arrow" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m-4-4 4 4 4-4M4 19h16"/></svg><span class="download-label">下载</span></span></a>\n''',
    );
  }
  html.write(
      '''</div><p class="download-note">文件保存位置由当前浏览器的下载设置决定。</p></section>
<aside aria-label="上传文件与连接提示">
<section class="upload-panel" id="upload-panel" aria-labelledby="upload-heading" aria-busy="false">
<p class="upload-direction"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 7 12 3l4 4M12 3v12M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/></svg>当前设备 → 电脑</p>
<h2 id="upload-heading">上传至电脑</h2><p class="upload-intro">选择文件，发送到这台电脑的接收目录。</p>
<div class="upload-controls"><div><label class="picker-label" for="upload-files">选择上传文件</label><input class="upload-picker" id="upload-files" type="file" multiple aria-label="选择上传到电脑的文件" aria-describedby="upload-help"><p class="upload-limit" id="upload-limit">支持多选 · 单文件最大 1 GiB</p></div><button class="upload-button" id="upload-button" type="button" disabled>上传到电脑</button></div>
<p class="upload-summary" id="upload-summary" role="status" aria-live="polite">选择文件后，点击上传到电脑。</p>
<ul class="upload-list" id="upload-list" aria-label="上传文件及进度"></ul>
<details class="upload-details"><summary>上传限制与保存说明</summary><p class="upload-help" id="upload-help">可多选文件，按顺序逐个上传，单文件最大 1 GiB（1,073,741,824 字节）。上传成功后文件会自动保存到电脑的接收目录，无需在电脑上逐个确认；请以每个文件的成功或失败反馈为准。请保持页面打开，勿在传输时刷新。</p></details>
<noscript><p class="upload-help">上传功能需要启用 JavaScript；文件下载仍可直接使用。</p></noscript>
</section><p class="network-note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0M8.5 16a5.5 5.5 0 0 1 7 0"/><circle cx="12" cy="20" r="1" fill="currentColor" stroke="none"/></svg><span><strong>请连接同一 Wi-Fi</strong><br>传输时请保持电脑上的 LanDrop 和本页面打开。</span></p></aside>
</div><footer class="footer"><span>LanDrop · 局域网文件传输</span><span>文件通过此电脑的本地服务传输</span></footer></main>
<div class="toast" id="download-toast" role="status" aria-live="polite"></div>
<script>
(function () {
  'use strict';
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');
  var toast = document.getElementById('download-toast');
  var timer;
  var dark = false;
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
