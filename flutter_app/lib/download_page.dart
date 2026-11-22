/// A self-contained, same-origin file transfer page. Serve as UTF-8 HTML.
/// Downloads: GET /file/{uuid}, optional ?inline=1 for safe media; GET
/// /download.zip with optional comma-separated UUID ids query.
/// Uploads: POST /uploads?name=&size=&fingerprint= returns 201 {id,offset,size};
/// GET /uploads/{id} returns 200 status, PATCH ?offset=N accepts <=4 MiB raw
/// octets and returns 200 status (409 requires status reconciliation).
/// POST /uploads/{id}/complete returns 201 {name,size} only after full save;
/// DELETE /uploads/{id} returns 204 after cancelling and clearing partial data.
/// Enforce the 1 GiB limit server-side too. Legacy POST /upload may coexist.
class DownloadItem {
  final String id;
  final String name;
  final int size;
  final String? relativePath;

  const DownloadItem({
    required this.id,
    required this.name,
    required this.size,
    this.relativePath,
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
    'bmp',
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
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self'; media-src 'self'; font-src 'none'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'">
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
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}

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
.file-name{display:block;font-size:16px;font-weight:500;line-height:1.5;overflow-wrap:anywhere;cursor:pointer}
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
.upload-recovery-warning{color:var(--error);font-weight:600}
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
[data-enter]{animation:rise 260ms cubic-bezier(.22,1,.36,1) both}
@keyframes rise{from{opacity:.5;transform:translateY(12px)}
to{opacity:1;transform:translateY(0)}
}

@media(hover:hover) and (pointer:fine){.theme-toggle:hover{background:var(--soft);color:var(--primary);transform:translateY(-1px)}
.file-card:hover{background:var(--bg);transform:translateY(-2px)}
.file-card:hover .download-arrow{background:var(--primary);border-color:var(--primary);color:#fff}
.upload-button:hover:not(:disabled){background:var(--primary-hover);transform:translateY(-1px)}
.upload-picker::file-selector-button:hover{background:var(--soft)}
.upload-details summary:hover{color:var(--primary)}
.action:hover{color:var(--primary);background:var(--soft)}
}
.theme-toggle:active,.upload-button:active:not(:disabled){transform:translateY(1px) scale(.985)}
.file-card:active{background:var(--soft)}

:root.theme-dark{color-scheme:dark;--bg:#14171F;--surface:#1D222D;--text:#F1F3F8;--muted:#B1B9C9;--line:#354054;--primary:#A7B5FF;--primary-hover:#C0CAFF;--soft:#29334C;--focus:#A7B5FF;--error:#FFA89F}
:root.theme-dark .theme-toggle .moon{display:none}
:root.theme-dark .theme-toggle .sun{display:block}
:root.theme-dark .upload-button:not(:disabled){color:#14171F}
@media(hover:hover) and (pointer:fine){:root.theme-dark .file-card:hover .download-arrow{color:#14171F}}

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


[hidden]{display:none!important}
body,.topbar,.download-panel,.upload-panel{transition:background-color 180ms var(--ease),color 180ms var(--ease),border-color 180ms var(--ease)}
.selection-bar{display:flex;align-items:center;gap:16px;flex-wrap:wrap;padding:14px 24px;border-bottom:1px solid var(--line);background:var(--bg);transition:background 160ms var(--ease)}
.selection-bar label{display:flex;align-items:center;gap:8px;font-size:14px;min-height:44px}
.selection-bar [hidden]{display:none!important}
.selection-bar.has-selection{background:var(--soft)}
#selection-count{font-size:13px;color:var(--muted)}
#zip-download{margin-left:auto}
input[type=checkbox]{appearance:none;-webkit-appearance:none;display:inline-grid;place-items:center;box-sizing:content-box;width:20px;height:20px;padding:12px;margin:-12px;flex:none;border:0;background:transparent;cursor:pointer;transition:transform 120ms var(--ease)}
input[type=checkbox]::before{content:'';display:block;box-sizing:border-box;width:20px;height:20px;border:1px solid var(--muted);border-radius:4px;background:var(--surface);text-align:center;font-size:15px;font-weight:700;line-height:18px;color:var(--surface);transition:background 120ms var(--ease),border-color 120ms var(--ease)}
input[type=checkbox]:checked::before{content:'✓';background:var(--primary);border-color:var(--primary)}
input[type=checkbox]:active{transform:scale(.9)}
.action{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--primary);font-size:13px;transition:background 150ms var(--ease),transform 150ms var(--ease)}
.action:active,.download-arrow:active{transform:scale(.97)}
.file-actions{display:flex;gap:8px;flex:none}
.file-path{display:block;overflow-wrap:anywhere;color:var(--muted);font-size:12px;margin-top:2px}
.file-card:has(.file-select:checked){background:var(--soft)}
.upload-item{animation:rise 220ms var(--ease) both;transition:background 150ms var(--ease)}
.upload-actions{display:flex;gap:8px;margin-top:10px}
.upload-progress::-webkit-progress-value{transition:width 120ms linear}
dialog{width:min(800px,calc(100% - 32px));max-height:90dvh;padding:24px;border:1px solid var(--line);border-radius:12px;background:var(--surface);color:var(--text);overflow:auto;opacity:0;transform:translateY(8px) scale(.99);transition:opacity 160ms var(--ease),transform 160ms var(--ease)}
dialog[open].visible{opacity:1;transform:none}
dialog::backdrop{background:rgba(10,16,30,.65)}
.preview-header{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:16px}
.preview-header h2{font-size:16px;overflow-wrap:anywhere;min-width:0}
#preview-status{margin:12px 0 0;min-height:1.4em;color:var(--muted);font-size:13px;overflow-wrap:anywhere}
#preview-status:empty{margin:0;min-height:0}
#preview-status[data-state="error"]{color:var(--error)}
#preview-media{display:flex;justify-content:center;min-width:0;overflow:hidden}
#preview-media img,#preview-media video{display:block;max-width:100%;max-height:65dvh;object-fit:contain;min-width:0}
#preview-media audio{width:100%;max-width:100%}
@media(max-width:760px){.file-card{flex-wrap:wrap;gap:10px}.file-info{flex-basis:calc(100% - 100px)}.file-actions{margin-left:auto}.download-arrow{width:auto}.selection-bar{padding:12px 16px;gap:10px}dialog{padding:16px}}

@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}
.file-card:hover,.theme-toggle:hover,.upload-button:hover:not(:disabled),.theme-toggle:active,.upload-button:active:not(:disabled),.action:active,.download-arrow:active,input[type=checkbox]:active{transform:none}
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
<section class="hero" data-enter aria-labelledby="page-title"><div class="hero-text"><p class="eyebrow">电脑分享的文件</p><h1 id="page-title">$safeTitle</h1><p class="hero-copy">下载到当前设备，也可向此传输上传文件。</p></div><div class="stats" aria-label="分享文件统计"><div class="stat"><strong id="file-count">$count</strong> 个文件</div><div class="stat">总计 <strong id="file-total">${_formatSize(totalBytes)}</strong></div></div></section>
<div class="workspace">
<section class="download-panel" aria-labelledby="download-heading"><div class="section-heading"><h2 id="download-heading" tabindex="-1">下载文件</h2><span>无需安装 App</span></div>
<div class="selection-bar"><label><input id="select-all" type="checkbox" aria-label="全选文件"> 全选</label><span id="selection-count" role="status" aria-live="polite">已选 0 个</span><button class="action" id="zip-cancel" type="button" aria-label="取消本页 ZIP 下载任务" title="取消本页发起的 ZIP 下载；已完成或被拒绝的任务会被忽略。" hidden>取消 ZIP 任务</button><a class="action" id="zip-download" href="/download.zip">下载全部 ZIP</a></div>
<div id="file-list-announcement" class="sr-only" role="status" aria-live="polite" aria-atomic="true"></div>
<div class="file-list" id="file-list" role="list" aria-label="可下载文件">
''');
  if (available.isEmpty) {
    html.write(
        '''<div class="empty" id="file-empty" role="listitem"><span class="empty-mark" aria-hidden="true">FILE</span><p>暂无可下载的文件</p><p>请在电脑上添加要分享的文件。</p></div>\n''');
  }
  for (var i = 0; i < available.length; i++) {
    final file = available[i];
    final type = _fileType(file.name);
    final safeName = _escapeHtml(file.name);
    final safeId =
        file.id.toLowerCase(); // Already UUID-validated, safe in a URL.
    final size = _formatSize(file.size);
    final path = file.relativePath;
    final pathHtml = path == null || path.isEmpty
        ? ''
        : '<span class="file-path">${_escapeHtml(path)}</span>';
    final dot = file.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : file.name.substring(dot + 1).toLowerCase();
    final previewKind =
        ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp'].contains(ext)
            ? 'image'
            : ['mp4', 'webm', 'mov'].contains(ext)
                ? 'video'
                : ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'].contains(ext)
                    ? 'audio'
                    : null;
    final previewHtml = previewKind == null
        ? ''
        : '<button class="action preview-button" type="button" data-id="$safeId" data-kind="$previewKind" data-name="$safeName" aria-label="预览 $safeName">预览</button>';
    html.write(
      '''<div class="file-card kind-${type.kind}" role="listitem" data-file-id="$safeId" data-name="$safeName" data-size="${file.size < 0 ? 0 : file.size}" data-path="${_escapeHtml(path ?? '')}" data-preview-kind="${previewKind ?? ''}"><input id="select-$safeId" class="file-select" type="checkbox" value="$safeId" aria-label="选择 $safeName">
<span class="file-icon" aria-hidden="true">${type.icon}</span><span class="file-info"><label class="file-name" for="select-$safeId">$safeName</label>$pathHtml<span class="file-meta"><span class="file-kind">${type.label}</span><span>$size</span></span></span><div class="file-actions">$previewHtml<a class="download-arrow" href="/file/$safeId" aria-label="下载 $safeName">下载</a></div></div>\n''',
    );
  }
  html.write(
      '''</div><p class="download-note">文件保存位置由当前浏览器的下载设置决定。</p></section>
<aside aria-label="上传文件与连接提示">
<section class="upload-panel" id="upload-panel" aria-labelledby="upload-heading">
<p class="upload-direction"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 7 12 3l4 4M12 3v12M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/></svg>当前设备 → 电脑</p>
<h2 id="upload-heading">上传至电脑</h2><p class="upload-intro">选择文件，发送到这台电脑的接收目录。</p>
<div class="upload-controls"><div><label class="picker-label" for="upload-files">选择上传文件</label><input class="upload-picker" id="upload-files" type="file" multiple aria-label="选择上传到电脑的文件" aria-describedby="upload-help"><p class="upload-limit" id="upload-limit">支持多选 · 单文件最大 1 GiB</p></div><button class="upload-button" id="upload-button" type="button" disabled>上传到电脑</button></div>
<p class="upload-summary" id="upload-summary" role="status" aria-live="polite">选择文件后，点击上传到电脑。</p>
<p class="upload-recovery-warning" id="upload-recovery-warning" role="status" aria-live="polite" hidden></p>
<ul class="upload-list" id="upload-list" aria-label="上传文件及进度"></ul>
<details class="upload-details"><summary>上传限制与保存说明</summary><p class="upload-help" id="upload-help">可多选文件，按顺序逐个上传，单文件最大 1 GiB（1,073,741,824 字节）。电脑最多为未完成上传预留 4 GiB（按文件声明大小计算）；额度已满时，请先完成或取消其他未完成上传后重试。上传成功后文件会自动保存到电脑的接收目录，无需在电脑上逐个确认；请以每个文件的成功或失败反馈为准。网络中断可点击「继续上传」。刷新或重新打开页面后，需重新选择原文件续传。如果浏览器允许，会在当前标签页本机保存最多 64 个文件指纹与续传编号（不含文件内容），成功或取消后会清除；刷新后仍需重新选择文件。上传文件归属于当前传输。</p></details>
<noscript><p class="upload-help">上传功能需要启用 JavaScript；文件下载仍可直接使用。</p></noscript>
</section><p class="network-note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0M8.5 16a5.5 5.5 0 0 1 7 0"/><circle cx="12" cy="20" r="1" fill="currentColor" stroke="none"/></svg><span><strong>请连接同一 Wi-Fi</strong><br>传输时请保持电脑上的 LanDrop 和本页面打开。</span></p></aside>
</div><footer class="footer"><span>LanDrop · 局域网文件传输</span><span>文件通过此电脑的本地服务传输</span></footer></main>
<dialog id="preview-dialog" aria-labelledby="preview-title"><div class="preview-header"><h2 id="preview-title">文件预览</h2><button class="action" id="preview-close" type="button" autofocus aria-label="关闭预览">关闭</button></div><div id="preview-media" aria-busy="false"></div><p id="preview-status" class="preview-status" role="status" aria-live="polite" aria-atomic="true"></p><p class="upload-help">媒体格式支持取决于浏览器；无法播放时请下载文件。</p></dialog>
<div class="toast" id="download-toast" role="status" aria-live="polite"></div>
<script>
(function () {
  'use strict';
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');
  var toast = document.getElementById('download-toast');
  var timer;
  var systemTheme = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  var manualTheme = false, dark = !!(systemTheme && systemTheme.matches);
  function applyTheme() {
    root.classList.toggle('theme-dark', dark);
    root.classList.toggle('theme-light', !dark);
    toggle.setAttribute('aria-pressed', String(dark));
    toggle.setAttribute('aria-label', dark ? '切换浅色模式' : '切换深色模式');
  }
  applyTheme();
  function followTheme(event) { if (!manualTheme) { dark = event.matches; applyTheme(); } }
  if (systemTheme) {
    if (systemTheme.addEventListener) systemTheme.addEventListener('change', followTheme);
    else if (systemTheme.addListener) systemTheme.addListener(followTheme);
  }
  toggle.addEventListener('click', function () {
    manualTheme = true; dark = !dark; applyTheme();
  });
  function notify(message) {
    toast.textContent = message;
    toast.classList.add('show');
    window.clearTimeout(timer);
    timer = window.setTimeout(function () { toast.classList.remove('show'); }, 2600);
  }
  var checks = Array.from(document.querySelectorAll('.file-select'));
  var all = document.getElementById('select-all');
  var zip = document.getElementById('zip-download');
  var zipCancel = document.getElementById('zip-cancel');
  var zipBaseHref = '/download.zip';
  var zipCancelTokens = Object.create(null);
  // Direct attachment downloads expose no completion callback; bound stale IDs.
  var maxRememberedZipTokens = 32;
  function newZipToken() {
    try {
      var crypto = window.crypto;
      if (!crypto) return null;
      if (typeof crypto.randomUUID === 'function') return crypto.randomUUID().toLowerCase();
      if (typeof crypto.getRandomValues !== 'function') return null;
      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      bytes[6] = bytes[6] & 15 | 64;
      bytes[8] = bytes[8] & 63 | 128;
      var hex = Array.from(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
      return hex.slice(0,8) + '-' + hex.slice(8,12) + '-' + hex.slice(12,16) + '-' + hex.slice(16,20) + '-' + hex.slice(20);
    } catch (_) { return null; }
  }
  function selection() {
    var selected = checks.filter(function (c) { return c.checked; });
    all.disabled = checks.length === 0;
    zip.hidden = checks.length === 0;
    all.checked = checks.length > 0 && selected.length === checks.length;
    all.indeterminate = selected.length > 0 && !all.checked;
    var counter = document.getElementById('selection-count');
    var counterText = '已选 ' + selected.length + ' 个';
    if (counter.textContent !== counterText) {
      counter.textContent = counterText;
      if (counter.animate && !(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches)) {
        counter.animate([{transform:'translateY(2px)',opacity:.5},{transform:'none',opacity:1}],{duration:160,easing:'ease-out'});
      }
    }
    all.parentElement.parentElement.classList.toggle('has-selection', selected.length > 0);
    zipBaseHref = '/download.zip' + (selected.length ? '?ids=' + selected.map(function (c) { return c.value; }).join(',') : '');
    zip.href = zipBaseHref;
    zip.textContent = selected.length ? '打包下载所选' : '下载全部 ZIP';
  }
  all.disabled = checks.length === 0;
  zip.hidden = checks.length === 0;
  all.addEventListener('change', function () { checks.forEach(function (c) { c.checked = all.checked; }); selection(); });
  checks.forEach(function (c) { c.addEventListener('change', selection); });
  document.querySelectorAll('.download-arrow, #zip-download').forEach(function (link) {
    link.addEventListener('click', function (event) {
      var zipLimitReached = false;
      if (link === zip) {
        var primaryClick = !event || event.button === undefined ||
          (event.button === 0 && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey);
        if (primaryClick && window.location && typeof window.location.assign === 'function') {
          var targetHref = zipBaseHref;
          var pendingCount = Object.keys(zipCancelTokens).length;
          var token = newZipToken();
          if (token && uuid(token) && pendingCount < maxRememberedZipTokens) {
            zipCancelTokens[token] = true;
            zipCancel.hidden = false;
            targetHref += (targetHref.indexOf('?') >= 0 ? '&' : '?') + 'job=' + token;
          } else if (pendingCount >= maxRememberedZipTokens) {
            zipLimitReached = true;
          }
          if (event && typeof event.preventDefault === 'function') event.preventDefault();
          window.location.assign(targetHref);
        }
      }
      notify(zipLimitReached
        ? '待取消 ZIP 任务较多，本次下载仍会继续，但无法通过此页取消。'
        : '已请求下载，请查看浏览器下载列表。');
    });
  });
  function cancelZipToken(token) {
    var url = '/download.zip/cancel?job=' + encodeURIComponent(token);
    var sent = false;
    try {
      sent = !!(window.navigator && typeof window.navigator.sendBeacon === 'function' &&
        window.navigator.sendBeacon(url));
    } catch (_) {}
    if (!sent) {
      try {
        var pending = fetch(url, {method:'POST', keepalive:true});
        if (pending && typeof pending.catch === 'function') pending.catch(function () {});
      } catch (_) {}
    }
  }
  zipCancel.addEventListener('click', function () {
    var tokens = Object.keys(zipCancelTokens);
    tokens.forEach(cancelZipToken);
    zipCancelTokens = Object.create(null);
    zipCancel.hidden = true;
    zip.href = zipBaseHref;
    if (tokens.length) notify('已请求取消本页 ZIP 下载；已完成的任务会被忽略。');
  });
  function uuid(value) {
    if (typeof value !== 'string') return false;
    var parts = value.split('-');
    return parts.length === 5 && parts.every(function (part, i) {
      return part.length === [8,4,4,4,12][i] && Array.from(part.toLowerCase()).every(function (c) { return '0123456789abcdef'.includes(c); });
    });
  }
  var dialog = document.getElementById('preview-dialog');
  var mediaBox = document.getElementById('preview-media');
  var previewStatus = document.getElementById('preview-status');
  var opener, media, previewId, activePreviewKind, closing = false, closeTimer;
  function setPreviewStatus(message, state) {
    previewStatus.textContent = message;
    if (state) previewStatus.setAttribute('data-state', state);
    else previewStatus.removeAttribute('data-state');
  }
  function stopMedia() {
    previewId = null;
    activePreviewKind = null;
    mediaBox.setAttribute('aria-busy', 'false');
    setPreviewStatus('');
    if (!media) { mediaBox.textContent = ''; return; }
    if (media.pause) media.pause();
    media.removeAttribute('src');
    if (media.load) media.load();
    mediaBox.textContent = '';
    media = null;
  }
  function closePreview() {
    if (!dialog.open || closing) return;
    closing = true;
    stopMedia();
    dialog.classList.remove('visible');
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    closeTimer = window.setTimeout(function () { dialog.close(); closing = false; if (opener && opener.isConnected !== false) opener.focus(); }, reduced ? 0 : 160);
  }
  document.getElementById('preview-close').addEventListener('click', closePreview);
  dialog.addEventListener('cancel', function (event) { event.preventDefault(); closePreview(); });
  dialog.addEventListener('close', function () { stopMedia(); if (opener && opener.isConnected !== false) opener.focus(); });
  function bindPreview(button) {
    button.addEventListener('click', function () {
      var kind = button.getAttribute('data-kind'), id = button.getAttribute('data-id');
      if (!uuid(id) || !['image', 'video', 'audio'].includes(kind) || closing) return;
      opener = button;
      stopMedia();
      previewId = id;
      activePreviewKind = kind;
      var name = button.getAttribute('data-name') || '';
      document.getElementById('preview-title').textContent = name;
      var currentMedia = document.createElement(kind === 'image' ? 'img' : kind);
      media = currentMedia;
      if (kind === 'image') currentMedia.alt = name;
      else { currentMedia.controls = true; currentMedia.preload = 'metadata'; }
      function updatePreviewStatus(message, state) {
        if (media !== currentMedia || previewId !== id || !dialog.open) return;
        setPreviewStatus(message, state);
        mediaBox.setAttribute('aria-busy', state === 'loading' ? 'true' : 'false');
      }
      currentMedia.addEventListener(kind === 'image' ? 'load' : kind === 'video' ? 'loadeddata' : 'loadedmetadata', function () {
        updatePreviewStatus('', null);
      });
      currentMedia.addEventListener('error', function () {
        updatePreviewStatus('预览失败，请下载文件。', 'error');
      });
      mediaBox.appendChild(currentMedia);
      mediaBox.setAttribute('aria-busy', 'true');
      dialog.showModal();
      setPreviewStatus('预览加载中…', 'loading');
      window.requestAnimationFrame(function () { dialog.classList.add('visible'); });
      document.getElementById('preview-close').focus();
      currentMedia.src = '/file/' + id + '?inline=1';
    });
  }
  document.querySelectorAll('.preview-button').forEach(bindPreview);
  // Keep each UUID's row and controls alive; polling never touches upload DOM.
  var fileList = document.getElementById('file-list'), records = new Map();
  function category(name) {
    var ext = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
    var types = [
      ['image','图片','IMG',['jpg','jpeg','png','gif','webp','heic','svg','avif','bmp']],
      ['video','视频','VID',['mp4','mov','m4v','avi','mkv','webm']],
      ['audio','音频','AUD',['mp3','m4a','aac','wav','flac','ogg']],
      ['archive','压缩包','ZIP',['zip','rar','7z','tar','gz','bz2']],
      ['document','文档','DOC',['pdf','doc','docx','txt','md','rtf','pages']],
      ['sheet','表格','XLS',['xls','xlsx','csv','numbers']]
    ];
    return types.find(function (t) { return t[3].includes(ext); }) || ['other','文件','FILE'];
  }
  function safePreview(name, kind) {
    var extensions = {image:['jpg','jpeg','png','gif','webp','avif','bmp'],video:['mp4','webm','mov'],audio:['mp3','wav','ogg','m4a','aac','flac']};
    return typeof kind === 'string' && Object.prototype.hasOwnProperty.call(extensions, kind) && name.includes('.') && extensions[kind].includes(name.split('.').pop().toLowerCase()) ? kind : null;
  }
  function sizeLabel(bytes) {
    var units = ['B','KB','MB','GB','TB','PB','EB'], n = bytes, i = 0;
    while (n >= 1024 && i < units.length-1) { n /= 1024; i++; }
    return (i ? String(Number(n.toFixed(n >= 100 ? 0 : 1))) : String(n)) + ' ' + units[i];
  }
  function element(tag, className, parent) {
    var node = document.createElement(tag); node.className = className;
    if (parent) parent.appendChild(node);
    return node;
  }
  function record(row, data) {
    return {row:row, data:data, check:row.querySelector('.file-select'), icon:row.querySelector('.file-icon'),
      name:row.querySelector('.file-name'), path:row.querySelector('.file-path'), info:row.querySelector('.file-info'),
      kind:row.querySelector('.file-kind'), size:row.querySelector('.file-meta').lastElementChild,
      actions:row.querySelector('.file-actions'), preview:row.querySelector('.preview-button'), download:row.querySelector('.download-arrow')};
  }
  document.querySelectorAll('.file-card').forEach(function (row) {
    var data = {id:row.getAttribute('data-file-id'), name:row.getAttribute('data-name'), size:Number(row.getAttribute('data-size')),
      relativePath:row.getAttribute('data-path') || '', previewKind:row.getAttribute('data-preview-kind') || null};
    records.set(data.id, record(row, data));
  });
  function createRecord(data) {
    var row = element('div','file-card'); row.setAttribute('role','listitem');
    var check = element('input','file-select',row); check.type = 'checkbox'; check.value = data.id; check.id = 'select-' + data.id;
    check.addEventListener('change',selection);
    element('span','file-icon',row).setAttribute('aria-hidden','true');
    var info = element('span','file-info',row), name = element('label','file-name',info); name.setAttribute('for',check.id);
    var meta = element('span','file-meta',info); element('span','file-kind',meta); element('span','file-size',meta);
    var actions = element('div','file-actions',row), link = element('a','download-arrow',actions);
    link.href = '/file/' + data.id; link.textContent = '下载';
    link.addEventListener('click',function () { notify('已请求下载，请查看浏览器下载列表。'); });
    return record(row, null);
  }
  function patch(r, data) {
    if (JSON.stringify(r.data) === JSON.stringify(data)) return;
    var type = category(data.name);
    r.row.className = 'file-card kind-' + type[0];
    r.check.setAttribute('aria-label','选择 ' + data.name);
    r.icon.textContent = type[2]; r.name.textContent = data.name; r.kind.textContent = type[1]; r.size.textContent = sizeLabel(data.size);
    if (data.relativePath) {
      if (!r.path) { r.path = element('span','file-path'); r.info.insertBefore(r.path,r.kind.parentElement); }
      r.path.textContent = data.relativePath;
    } else if (r.path) { r.path.remove(); r.path = null; }
    r.download.setAttribute('download',data.name); r.download.setAttribute('aria-label','下载 ' + data.name);
    if (data.previewKind) {
      if (!r.preview) { r.preview = element('button','action preview-button'); r.preview.type = 'button'; r.preview.textContent = '预览'; r.actions.insertBefore(r.preview,r.download); bindPreview(r.preview); }
      r.preview.setAttribute('data-id',data.id); r.preview.setAttribute('data-kind',data.previewKind); r.preview.setAttribute('data-name',data.name); r.preview.setAttribute('aria-label','预览 ' + data.name);
    } else if (r.preview) { r.preview.remove(); r.preview = null; }
    if (previewId === data.id) {
      if (!data.previewKind || data.previewKind !== activePreviewKind) closePreview();
      else {
        document.getElementById('preview-title').textContent = data.name;
        if (media && typeof media.alt === 'string') media.alt = data.name;
      }
    }
    r.data = data;
  }
  var lastManifest = JSON.stringify([document.getElementById('page-title').textContent,Array.from(records.values()).map(function (r) { return r.data; })]);
  function hasClass(node, name) {
    return !!node && String(node.className || '').split(/\\s+/).includes(name);
  }
  function fileRows() {
    return Array.from(fileList.children).filter(function (node) { return hasClass(node,'file-card'); });
  }
  function containsNode(parent, node) {
    while (node) { if (node === parent) return true; node = node.parentElement; }
    return false;
  }
  function focusControlInRow(row, preferredSelector) {
    if (!row) return null;
    var preferred = preferredSelector ? row.querySelector(preferredSelector) : null;
    if (preferred && !preferred.disabled && preferred.focus) return preferred;
    for (var selector of ['.file-select','.preview-button','.download-arrow']) {
      var candidate = row.querySelector(selector);
      if (candidate && !candidate.disabled && candidate.focus) return candidate;
    }
    return null;
  }
  function reconcile(manifest) {
    if (!manifest || typeof manifest.title !== 'string' || !Array.isArray(manifest.files)) throw new Error('Invalid manifest');
    var seen = new Set(), files = manifest.files.map(function (f) {
      if (!f || !uuid(f.id) || typeof f.name !== 'string' || !Number.isSafeInteger(f.size) || f.size < 0) throw new Error('Invalid file');
      var id = f.id.toLowerCase(); if (seen.has(id)) throw new Error('Duplicate file'); seen.add(id);
      return {id:id,name:f.name,size:f.size,relativePath:typeof f.relativePath === 'string' ? f.relativePath : '',previewKind:safePreview(f.name,f.previewKind)};
    });
    var signature = JSON.stringify([manifest.title,files]);
    if (signature === lastManifest) return;
    var previousIds = new Set(records.keys());
    var nextIds = new Set(files.map(function (file) { return file.id; }));
    var addedCount = files.reduce(function (count, file) {
      return count + (previousIds.has(file.id) ? 0 : 1);
    }, 0);
    var removedCount = Array.from(previousIds).reduce(function (count, id) {
      return count + (nextIds.has(id) ? 0 : 1);
    }, 0);
    var focused = document.activeElement;
    var previousRows = fileRows();
    var focusedRowIndex = previousRows.findIndex(function (row) { return containsNode(row,focused); });
    var focusedRow = focusedRowIndex >= 0 ? previousRows[focusedRowIndex] : null;
    var focusedControlSelector = hasClass(focused,'file-select') ? '.file-select'
      : hasClass(focused,'preview-button') ? '.preview-button'
      : hasClass(focused,'download-arrow') ? '.download-arrow' : null;
    if (previewId && !seen.has(previewId)) closePreview();
    records.forEach(function (r,id) { if (!seen.has(id)) { r.row.remove(); records.delete(id); } });
    files.forEach(function (data,index) {
      var r = records.get(data.id);
      if (!r) { r = createRecord(data); records.set(data.id,r); }
      patch(r,data);
      if (fileList.children[index] !== r.row) fileList.insertBefore(r.row,fileList.children[index] || null);
    });
    var empty = document.getElementById('file-empty');
    if (!files.length && !empty) {
      empty = element('div','empty',fileList); empty.id = 'file-empty'; empty.setAttribute('role','listitem');
      element('p','',empty).textContent = '暂无可下载的文件';
      element('p','',empty).textContent = '请在电脑上添加要分享的文件。';
    } else if (files.length && empty) empty.remove();
    checks = files.map(function (data) { return records.get(data.id).check; });
    document.getElementById('file-count').textContent = String(files.length);
    document.getElementById('file-total').textContent = sizeLabel(files.reduce(function (sum,f) { return sum + f.size; },0));
    var title = document.getElementById('page-title');
    if (title.textContent !== manifest.title) { title.textContent = manifest.title; document.title = manifest.title + ' · LanDrop 文件传输'; }
    selection();
    if (addedCount || removedCount) {
      var announcement = [];
      if (addedCount) announcement.push('新增 ' + addedCount + ' 个文件');
      if (removedCount) announcement.push('移除 ' + removedCount + ' 个文件');
      announcement.push('当前共 ' + files.length + ' 个文件。');
      document.getElementById('file-list-announcement').textContent = announcement.join('，');
    }
    if (focused && focused.isConnected && document.activeElement !== focused && focused.focus) {
      focused.focus({preventScroll:true});
    } else if (focusedRow && !focused.isConnected) {
      var currentRows = fileRows();
      var currentIndex = currentRows.indexOf(focusedRow);
      var targetRow = currentIndex >= 0 ? focusedRow
        : currentRows.length ? currentRows[Math.min(focusedRowIndex,currentRows.length-1)] : null;
      var target = focusControlInRow(targetRow,focusedControlSelector);
      if (target) target.focus({preventScroll:true});
      else if (!currentRows.length) {
        var heading = document.getElementById('download-heading');
        if (heading && heading.focus) heading.focus({preventScroll:true});
      }
    }
    lastManifest = signature;
  }
  var pollTimer, manifestRequest;
  function scheduleManifest() {
    window.clearTimeout(pollTimer);
    if (document.visibilityState !== 'hidden') pollTimer = window.setTimeout(refreshManifest,2000);
  }
  function interruptManifest(request) {
    if (!request) return;
    request.cancelled = true;
    window.clearTimeout(request.timeout);
    request.interrupt();
    if (request.controller) request.controller.abort();
  }
  async function refreshManifest() {
    if (document.visibilityState === 'hidden' || manifestRequest) return;
    // Each request owns its timeout/finally. An old body/abort arriving late
    // cannot update the DOM or clear the next visible generation's timers.
    var request = {controller:window.AbortController ? new window.AbortController() : null};
    manifestRequest = request;
    var interrupted = new Promise(function (resolve) { request.interrupt = resolve; });
    request.timeout = window.setTimeout(function () { interruptManifest(request); },8000);
    try {
      var options = {credentials:'same-origin',cache:'no-store'};
      if (request.controller) options.signal = request.controller.signal;
      var data = await Promise.race([fetch('/manifest',options).then(function (response) {
        if (response.status !== 200) throw new Error('Manifest unavailable');
        return response.json();
      }),interrupted]);
      if (manifestRequest === request && !request.cancelled) reconcile(data);
    } catch (_) { /* Retain the last working list; transient failures stay quiet. */ }
    finally {
      window.clearTimeout(request.timeout);
      if (manifestRequest === request) { manifestRequest = null; scheduleManifest(); }
    }
  }
  if (document.addEventListener) document.addEventListener('visibilitychange',function () {
    window.clearTimeout(pollTimer);
    var previous = manifestRequest; manifestRequest = null;
    interruptManifest(previous);
    if (document.visibilityState !== 'hidden') refreshManifest();
  });
  scheduleManifest();
  // Pure local SHA-256: works on HTTP LAN origins without crypto.subtle.
  function sha256(bytes) {
    var primes = [], constants = [], initial = [];
    for (var n = 2; primes.length < 64; n++) {
      if (primes.some(function (p) { return n % p === 0; })) continue;
      primes.push(n);
      constants.push((Math.pow(n, 1/3) % 1 * 4294967296) | 0);
      if (initial.length < 8) initial.push((Math.sqrt(n) % 1 * 4294967296) | 0);
    }
    var length = bytes.length;
    var padded = new Uint8Array(Math.ceil((length + 9) / 64) * 64);
    padded.set(bytes); padded[length] = 128;
    var view = new DataView(padded.buffer);
    view.setUint32(padded.length - 4, length * 8);
    var h = initial, w = new Int32Array(64);
    function r(x, n) { return (x >>> n) | (x << (32-n)); }
    for (var offset = 0; offset < padded.length; offset += 64) {
      for (var i = 0; i < 64; i++) {
        if (i < 16) w[i] = view.getInt32(offset + i*4);
        else {
          var x = w[i-15], y = w[i-2];
          w[i] = (w[i-16] + (r(x,7)^r(x,18)^(x>>>3)) + w[i-7] + (r(y,17)^r(y,19)^(y>>>10))) | 0;
        }
      }
      var v = h.slice();
      for (var j = 0; j < 64; j++) {
        var t1 = (v[7] + (r(v[4],6)^r(v[4],11)^r(v[4],25)) + ((v[4]&v[5])^(~v[4]&v[6])) + constants[j] + w[j]) | 0;
        var t2 = ((r(v[0],2)^r(v[0],13)^r(v[0],22)) + ((v[0]&v[1])^(v[0]&v[2])^(v[1]&v[2]))) | 0;
        v = [(t1+t2)|0,v[0],v[1],v[2],(v[3]+t1)|0,v[4],v[5],v[6]];
      }
      h = h.map(function (x, i) { return (x+v[i])|0; });
    }
    return h.map(function (x) { return (x>>>0).toString(16).padStart(8,'0'); }).join('');
  }
  function readBytes(blob) {
    if (blob.arrayBuffer) return blob.arrayBuffer();
    return new Promise(function (resolve, reject) {
      var reader = new FileReader(); reader.onload = function () { resolve(reader.result); };
      reader.onerror = function () { reject(new Error('无法读取本地文件')); }; reader.readAsArrayBuffer(blob);
    });
  }
  async function fingerprint(file, entry) {
    // Hash every byte: sampling only the head/tail can resume into a different file.
    // Per-chunk digests keep peak memory bounded; yielding lets the page repaint.
    var chunkSize = 4 * 1024 * 1024, chunks = [];
    for (var offset = 0; offset < file.size; offset += chunkSize) {
      if (entry.cancelled) return null;
      var end = Math.min(file.size,offset + chunkSize);
      var bytes = await readBytes(file.slice(offset,end));
      if (entry.cancelled) return null;
      chunks.push(sha256(new Uint8Array(bytes)));
      if (entry.cancelled) return null;
      if (end < file.size) await new Promise(function (resolve) { window.setTimeout(resolve,0); });
    }
    if (entry.cancelled) return null;
    var identity = new TextEncoder().encode(JSON.stringify([file.name,file.size,file.lastModified,chunks]));
    return sha256(identity);
  }
  var maxUploadBytes = 1024 * 1024 * 1024, chunkBytes = 4 * 1024 * 1024;
  var controlTimeoutMs = 120000;
  var picker = document.getElementById('upload-files');
  var uploadButton = document.getElementById('upload-button');
  var uploadList = document.getElementById('upload-list');
  var summary = document.getElementById('upload-summary');
  var totalProgress = document.createElement('progress');
  totalProgress.className = 'upload-progress'; totalProgress.max = 100; totalProgress.value = 0;
  totalProgress.setAttribute('aria-label', '所有文件总上传进度');
  summary.parentElement.insertBefore(totalProgress, summary);
  var entries = [], busy = false;
  function updateTotal() {
    var total = 0, sent = 0;
    entries.forEach(function (e) { if (e.file.size <= maxUploadBytes) { total += e.file.size; sent += e.sent || 0; } });
    totalProgress.value = total ? Math.min(100, sent/total*100) : 0;
  }
  function state(entry, value, message, announce) {
    var changed = entry.state !== value;
    entry.state = value; entry.row.setAttribute('data-state', value); entry.status.textContent = message;
    if (entry.announcement && (changed || announce)) {
      entry.announcement.textContent = entry.file.name + '：' + message;
      if (value === 'uploading') {
        entry.lastAnnouncementAt = performance.now();
        entry.lastAnnouncedPercent = entry.progress.value;
      } else {
        entry.lastAnnouncementAt = undefined;
        entry.lastAnnouncedPercent = undefined;
      }
    }
    entry.cancel.hidden = ['success','cancelled','error'].includes(value);
  }
  function refreshButton() {
    var ready = entries.some(function (e) { return !e.cancelled && ['pending','paused'].includes(e.state); });
    uploadButton.disabled = busy || !ready;
    uploadButton.textContent = busy ? '上传中…' : entries.some(function (e) { return !e.cancelled && e.state === 'paused'; }) ? '继续上传' : '上传到电脑';
  }
  async function control(method, url, expected) {
    var controller = typeof window.AbortController === 'function' ? new window.AbortController() : null;
    var init = {method:method, credentials:'same-origin', cache:'no-store'};
    if (controller) init.signal = controller.signal;
    var timer;
    var operation = (async function () {
      var response = await fetch(url, init);
      if (response.status !== expected) {
        var message = 'HTTP ' + response.status;
        try { var error = await response.json(); if (error && typeof error.error === 'string') message = error.error; } catch (_) {}
        var failure = new Error(message + '，未确认保存'); failure.status = response.status; throw failure;
      }
      return expected === 204 ? null : response.json();
    }());
    var timeout = new Promise(function (_, reject) {
      timer = window.setTimeout(function () {
        var failure = new Error('电脑响应超时，未确认保存'); failure.timeout = true;
        reject(failure);
        if (controller) controller.abort();
      }, controlTimeoutMs);
    });
    try { return await Promise.race([operation,timeout]); }
    finally { if (timer !== undefined) window.clearTimeout(timer); }
  }
  var uploadSessionStorageKey = 'landrop.uploadSessions.v1';
  var maxRememberedUploadSessions = 64;
  var uploadSessionStorageAvailable = true;
  function reportUploadStorageFailure() {
    if (!uploadSessionStorageAvailable) return;
    uploadSessionStorageAvailable = false;
    var warning = document.getElementById('upload-recovery-warning');
    if (warning) {
      warning.hidden = false;
      warning.textContent = '浏览器无法可靠访问本标签页的续传记录。若上传期间或完成后响应丢失，刷新页面后可能无法自动续传或确认；请先检查电脑接收目录，再重新选择文件。';
    }
  }
  try {
    var storageProbe = window.sessionStorage;
    var probeKey = uploadSessionStorageKey + '.probe';
    storageProbe.setItem(probeKey,'1');
    storageProbe.removeItem(probeKey);
  } catch (_) { reportUploadStorageFailure(); }
  function rememberedUploadSessions() {
    var raw;
    try { raw = window.sessionStorage.getItem(uploadSessionStorageKey); }
    catch (_) { reportUploadStorageFailure(); return []; }
    if (typeof raw !== 'string' || raw.length > 16384) return [];
    var records;
    try { records = JSON.parse(raw); } catch (_) { return []; }
    if (!Array.isArray(records)) return [];
    return records.filter(function (record) {
      return record && typeof record.fingerprint === 'string' && /^[0-9a-f]{64}\$/.test(record.fingerprint) && uuid(record.id);
    }).slice(-maxRememberedUploadSessions);
  }
  function findRememberedUploadSession(fingerprint) {
    var records = rememberedUploadSessions();
    for (var i = records.length - 1; i >= 0; i--) {
      if (records[i].fingerprint === fingerprint) return records[i].id;
    }
    return null;
  }
  function rememberUploadSession(fingerprint, id) {
    if (typeof fingerprint !== 'string' || !/^[0-9a-f]{64}\$/.test(fingerprint) || !uuid(id)) return;
    try {
      var records = rememberedUploadSessions().filter(function (record) { return record.fingerprint !== fingerprint; });
      records.push({fingerprint:fingerprint,id:id});
      if (records.length > maxRememberedUploadSessions) records = records.slice(-maxRememberedUploadSessions);
      window.sessionStorage.setItem(uploadSessionStorageKey,JSON.stringify(records));
    } catch (_) { reportUploadStorageFailure(); }
  }
  function forgetRememberedUploadSession(fingerprint, id) {
    if (typeof fingerprint !== 'string' || !id) return;
    try {
      var records = rememberedUploadSessions().filter(function (record) { return record.fingerprint !== fingerprint || record.id !== id; });
      if (records.length) window.sessionStorage.setItem(uploadSessionStorageKey,JSON.stringify(records));
      else window.sessionStorage.removeItem(uploadSessionStorageKey);
    } catch (_) { reportUploadStorageFailure(); }
  }
  function validate(entry, data) {
    if (!data || !uuid(data.id) || (entry.id && data.id !== entry.id) || data.size !== entry.file.size ||
        !Number.isSafeInteger(data.offset) || data.offset < entry.offset || data.offset > data.size) throw new Error('电脑返回的续传信息无效，未确认保存');
    entry.id = data.id; entry.offset = data.offset; entry.sent = data.offset;
    rememberUploadSession(entry.fingerprint, entry.id);
    entry.progress.value = data.size ? data.offset / data.size * 100 : 0;
    entry.progress.setAttribute('aria-label',entry.file.name+' 上传进度');
    updateTotal();
  }
  async function removeSession(entry) {
    if (!entry.id) return;
    if (!entry.deleting) entry.deleting = control('DELETE','/uploads/'+entry.id+'?cancel=1',204).catch(function (error) { entry.deleting = null; if (error.status === 409) throw error; throw new Error('取消未确认，临时文件尚未确认清理。恢复接收目录后重试，必要时在电脑端检查恢复提示'); });
    await entry.deleting;
  }
  async function cancel(entry) {
    if (entry.state === 'success' || entry.completing) return;
    entry.cancelled = true;
    if (entry.xhr) entry.xhr.abort();
    state(entry,'cancelling','正在取消并清理临时文件…');
    try {
      if (entry.creating) {
        try { await entry.creating; }
        catch (_) {
          // A lost create response may still have created a server session.
          // Reconcile using the same local fingerprint before deleting it.
          if (!entry.fingerprint) throw new Error('取消未确认，请检查连接后再次取消');
          validate(entry,await control('POST',createUrl(entry),201));
        }
      }
      await removeSession(entry);
      forgetRememberedUploadSession(entry.fingerprint,entry.id);
      state(entry,'cancelled','上传已取消，临时文件已清理。');
    } catch (error) {
      if (error.status === 409) {
        entry.progress.value = 100; entry.sent = entry.file.size; updateTotal();
        forgetRememberedUploadSession(entry.fingerprint,entry.id);
        state(entry,'success','电脑已确认文件保存，无法取消。');
      } else { state(entry,'paused',error.message); entry.cancel.hidden = false; }
    }
    refreshButton();
  }
  picker.addEventListener('change', function () {
    if (busy) return;
    entries = []; uploadList.textContent = ''; totalProgress.value = 0;
    Array.from(picker.files || []).forEach(function (file) {
      var row = document.createElement('li'); row.className = 'upload-item';
      var name = document.createElement('span'); name.className = 'upload-name'; name.textContent = file.name;
      var status = document.createElement('span'); status.className = 'upload-status'; status.setAttribute('aria-hidden','true');
      var announcement = document.createElement('span'); announcement.className = 'sr-only upload-announcement'; announcement.setAttribute('role','status'); announcement.setAttribute('aria-live','polite'); announcement.setAttribute('aria-atomic','true');
      var progress = document.createElement('progress'); progress.className = 'upload-progress'; progress.max = 100; progress.value = 0;
      progress.setAttribute('aria-label',file.name+' 上传进度');
      var actions = document.createElement('div'); actions.className = 'upload-actions';
      var cancelButton = document.createElement('button'); cancelButton.type = 'button'; cancelButton.className = 'action'; cancelButton.textContent = '取消'; cancelButton.setAttribute('aria-label','取消上传 '+file.name);
      var entry = {file:file,row:row,status:status,announcement:announcement,progress:progress,cancel:cancelButton,offset:0,sent:0};
      cancelButton.addEventListener('click',function () { return cancel(entry); });
      actions.appendChild(cancelButton); row.appendChild(name); row.appendChild(status); row.appendChild(progress); row.appendChild(actions); row.appendChild(announcement); uploadList.appendChild(row); entries.push(entry);
      state(entry,file.size > maxUploadBytes ? 'error' : 'pending',file.size > maxUploadBytes ? '无法上传：单文件超过 1 GiB 限制。' : '等待上传；重新选择原文件可续传');
    });
    picker.value = '';
    summary.textContent = entries.length ? '已选择 '+entries.length+' 个文件，超限文件不会上传。' : '选择文件后，点击上传到电脑。';
    refreshButton();
  });
  function chunk(entry, start, end) {
    return new Promise(function (resolve,reject) {
      var xhr = new XMLHttpRequest(), finished = false; entry.xhr = xhr;
      function finish(error,data) { if (finished) return; finished = true; entry.xhr = null; if (error) reject(error); else resolve(data); }
      xhr.upload.addEventListener('progress',function (event) {
        if (finished || entry.cancelled || !event.lengthComputable) return;
        var loaded = Math.min(end-start,Math.max(0,event.loaded));
        entry.sent = start+loaded; entry.progress.value = entry.file.size ? entry.sent/entry.file.size*100 : 0;
        var now = performance.now();
        var seconds = Math.max(.001,(now-entry.started)/1000);
        var speed = Math.max(0,(entry.sent-entry.base)/seconds);
        var remain = speed ? Math.ceil((entry.file.size-entry.sent)/speed) : null;
        var announceProgress = entry.lastAnnouncementAt === undefined ||
          entry.progress.value-entry.lastAnnouncedPercent >= 5 ||
          now-entry.lastAnnouncementAt >= 5000;
        state(entry,'uploading','正在上传 '+Math.floor(entry.progress.value)+'% · '+(speed/1024/1024).toFixed(2)+' MiB/s · '+(remain === null ? '估算中' : '剩余约 '+remain+' 秒')+'（等待电脑确认保存）',announceProgress); updateTotal();
      });
      xhr.addEventListener('load',function () {
        if (xhr.status === 409) { finish(null,{conflict:true}); return; }
        if (xhr.status !== 200) {
          var message = 'HTTP ' + xhr.status;
          try { var error = JSON.parse(xhr.responseText); if (error && typeof error.error === 'string') message = error.error; } catch (_) {}
          finish(new Error(message + '，未确认保存')); return;
        }
        try { finish(null,JSON.parse(xhr.responseText)); } catch (_) { finish(new Error('电脑返回的续传信息无效，未确认保存')); }
      });
      ['error','abort','timeout'].forEach(function (type) { xhr.addEventListener(type,function () { finish(new Error(type === 'abort' && entry.cancelled ? '主动取消' : '网络中断或超时，上传已暂停，未确认保存')); }); });
      try { xhr.open('PATCH','/uploads/'+entry.id+'?offset='+start); xhr.setRequestHeader('Content-Type','application/octet-stream'); xhr.timeout = 120000; xhr.send(entry.file.slice(start,end)); }
      catch (_) { finish(new Error('无法发送分块，未确认保存')); }
    });
  }
  function createUrl(entry) {
    return '/uploads?name='+encodeURIComponent(entry.file.name)+'&size='+entry.file.size+'&fingerprint='+entry.fingerprint;
  }
  async function resumeSession(entry, id) {
    entry.id = id;
    try { validate(entry,await control('GET','/uploads/'+id,200)); }
    catch (error) {
      if (error.status !== 404) throw error;
      forgetRememberedUploadSession(entry.fingerprint,id);
      entry.id = null; entry.offset = 0; entry.sent = 0;
      var stale = new Error('恢复记录已失效，文件可能已保存。请先检查电脑接收目录，再重新选择文件。');
      stale.staleSession = true;
      throw stale;
    }
  }
  async function uploadOne(entry) {
    try {
      entry.cancelled = false;
      state(entry,'uploading',entry.id ? '正在检查续传位置…' : '正在校验完整文件内容…');
      if (!entry.id) {
        entry.progress.removeAttribute('value');
        entry.progress.setAttribute('aria-label',entry.file.name+' 文件校验进度');
        entry.creating = (async function () {
          entry.fingerprint = await fingerprint(entry.file,entry);
          if (entry.cancelled) return;
          var rememberedId = findRememberedUploadSession(entry.fingerprint);
          if (rememberedId) {
            await resumeSession(entry,rememberedId);
          } else {
            var data = await control('POST',createUrl(entry),201);
            validate(entry,data);
          }
        }());
        await entry.creating; entry.creating = null;
      } else await resumeSession(entry,entry.id);
      if (entry.cancelled) return;
      entry.started = performance.now(); entry.base = entry.offset;
      var conflicts = 0;
      while (entry.offset < entry.file.size && !entry.cancelled) {
        var start = entry.offset, end = Math.min(start+chunkBytes,entry.file.size);
        var data = await chunk(entry,start,end);
        if (entry.cancelled) return;
        if (data.conflict) {
          validate(entry,await control('GET','/uploads/'+entry.id,200));
          if (++conflicts > 3) throw new Error('分块位置持续冲突，请继续上传重试，未确认保存');
        } else {
          validate(entry,data);
          if (entry.offset !== end) throw new Error('分块保存长度不符，未确认保存');
          conflicts = 0;
        }
      }
      if (entry.cancelled) return;
      state(entry,'uploading','数据已发送，等待电脑确认完整保存，此阶段无法取消…',true);
      entry.completing = true; entry.cancel.disabled = true;
      var saved;
      try { saved = await control('POST','/uploads/'+entry.id+'/complete',201); }
      finally { entry.completing = false; entry.cancel.disabled = ['success','cancelled','error'].includes(entry.state); }
      if (entry.cancelled) return;
      if (!saved || typeof saved.name !== 'string' || !saved.name.length || saved.size !== entry.file.size) throw new Error('电脑返回的保存信息无效，未确认保存');
      entry.progress.value = 100; entry.sent = entry.file.size; updateTotal();
      forgetRememberedUploadSession(entry.fingerprint,entry.id);
      state(entry,'success','上传成功，已自动保存到电脑：'+saved.name);
    } catch (error) {
      if (entry.cancelled) return;
      if (error.staleSession) {
        entry.sent = 0; entry.progress.value = 0; updateTotal();
        state(entry,'error',error.message);
        return;
      }
      entry.sent = entry.offset; entry.progress.value = entry.file.size ? entry.offset/entry.file.size*100 : 0; updateTotal();
      state(entry,'paused','上传暂停，未确认保存：'+error.message+'。检查连接后点击「继续上传」。');
    }
  }
  uploadButton.addEventListener('click',async function () {
    if (busy || uploadButton.disabled) return;
    busy = true; picker.disabled = true; refreshButton();
    for (var index = 0; index < entries.length; index++) {
      var entry = entries[index];
      if (!['pending','paused'].includes(entry.state) || entry.cancelled) continue;
      summary.textContent = '正在处理第 '+(index+1)+' / '+entries.length+' 个文件，请保持页面打开。';
      await uploadOne(entry);
    }
    var succeeded = entries.filter(function (e) { return e.state === 'success'; }).length;
    var paused = entries.filter(function (e) { return e.state === 'paused'; }).length;
    var failed = entries.filter(function (e) { return e.state === 'error'; }).length;
    summary.textContent = '处理完成：成功 '+succeeded+' 个，暂停 '+paused+' 个，失败 '+failed+' 个。'+(paused ? '暂停文件未确认保存，可继续上传。' : '请以每个文件的保存反馈为准。');
    busy = false; picker.disabled = false; refreshButton();
  });
}());
</script>
</body></html>''');
  return html.toString();
}
