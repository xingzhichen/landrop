GATE: OPEN 26 (rounds used up)

# LanDrop 1.1.0 UI 验证记录

## 完成与范围

- 实际产品为 `software`：桌面管理工作台 + 自包含局域网传输页面，不是宣传网站。
- 统一视觉使用已抽取的 cool-grey-cobalt；字体参考 Geist / Geist Mono，但离线交付使用系统 sans / monospace；原生使用 Arial 与操作系统中文回退。
- 抽取结果 collage hero、counter-roll moment 不用于实际任务页；未加载 shader、scene、照片或虚构 UI。
- Voice card：事实型技术工具；中文动作、真实文件数/体积/状态、直接说明同一网络与文件大小限制。
- 没有照片、站外素材、虚构客户或假定价格；没有新造品牌、外部表单联系人、.example 联系方式、待补域名/素材或客户资源插槽。局域网地址动态生成，不设置公共 canonical/share 图。

## 功能与原生测试

- `flutter analyze`：No issues found。
- `flutter test`：29 项通过。覆盖真实HTTP下载/range/页面隔离、上传保存/安全拒绝/异常清理、网页脚本实际Node行为、文件选择器错误与重试、桌面五种宽度布局、空状态创建、接收导航和复制实际保存路径。
- 另运行7项原生渲染截图测试，加载本机 Arial Unicode / MaterialIcons：全部通过。截图中的文件是明确的测试夹具，只有开发工具/测试引用，生产界面不注入假数据。
- 上传脚本从 `var maxUploadBytes` 起与上版逐字一致；CSP未放宽，下载链接UUID白名单和文本转义保留。
- macOS 文件选择权限声明和打包签名校验保留。

## 视觉与浏览器检查

- 网页在1440、1024、820、768、390宽度执行完整consistency检查和截图，并逐张查看；320宽度walk：0 FAIL。
- consistency通过项包括：off-viewport、collide、overlap-text、contrast、text-contrast、body-size、focus-visible、reduced-motion、hidden-content、hover-move、hover-spill、forms、a11y-name。
- 单独layout检查已运行；未通过其营销hero/section屏高、标题与列边界规则，没有将结果宣称为PASS。
- copy-lint：0 FAIL / 0 WARN。
- perf：0 FAIL / 2 WARN；两处WARN均是宿主CPU负载高，不能把所测毫秒数当作真实设备性能承诺。报告传输16.1KiB、布局偏移0、无字体/图片下载或WebGL。
- 原生工作台在1440、1024、820、680、390宽度均无RenderFlex溢出，并生成实际Flutter组件树截图；宽度390仅用于缩窗压力测试，不代表需要安装手机App。

## 门禁解释与豁免

三轮门禁后仍有26个条目开放：主要是营销页面的满屏hero、每屏一个章节、视觉素材/场景、CTA布局和章节容器类/列起点要求。没有为通过检查把文件任务推到全屏宣传内容之后，也没有隐藏真实内容或修改检查器。留白/flush条目在实际截图中仍保留为开放发现，不以总通过代替人工判断。

三个逐项豁免如下（均保留实际DOM与交互，不使用伪aria属性）：

1. `menu-toggle`：主题开关不是菜单，正确语义是动态accessible name + aria-pressed，而非aria-expanded。
2. `motion-layer`：单HTML服务页内联完整hover/press/reduced-motion样式；完整检查的hover-move与reduced-motion已通过，不是没有反馈。
3. `hero-enter`：有data-enter及一次性CSS rise动画，无需脚本先隐藏内容；关闭JS和减少动态效果时可读。

consistency保留的WARN：动态页面名不写产品品类；每个文件各有下载操作；卡片内部标题/列与章节网格不相同；按钮禁用态无需hover变化；Geist未下载（离线字体回退是有意的）；静态预览没有真实下载目标（真实HTTP测试覆盖）；skip-link/分享meta/章节间距和高度属于现有工具页适配。copy-lint没有保留的WARN。

## 未检查

- 未在真机手机Safari/Android浏览器或Windows桌面实机复验。
- 原生截图是Flutter渲染测试，不是对发布包的OS原生文件选择器点击录屏。
- 性能结果来自本机CPU渲染浏览器，不代替低端手机实测。

## 最终门禁完整输出

```text
gate: rounds used up; 26 FAIL open (page unchanged since the last run)
  FAIL hero-fill        main#top > div.workspace > section.download-panel "下载文件"  [1440, 390]
       the next section shows on the first screen: it starts at 281px on a 900px screen (the hero ends at 249px)
       fix: let the hero fill the first screen alone (min-height: 100svh, less above it): nothing of the next section on load
  FAIL flush            main#top > section.hero > div.hero-text > p.hero-copy "下载到当前设备，或把文件上传至电脑。"  [1440]
       its last line sits 5px above the rule on top of section.download-panel
       fix: give the section its padding at the edge where the ground changes (the closing call keeps a clear gap above the footer)
  FAIL no-visual        main#top > div.workspace > section.download-panel "下载文件"  [1440, 390]
       no picture, effect or mock in this section; a feature section needs a visual
       fix: give the section a visual: a UI fragment on a ground, real icons, or a photograph that fits
  FAIL cta              main#top > section.hero  [1440, 390]
       the hero has no button (the nav's does not count)
       fix: add the action: a button in the hero, one on every priced item, one in the closing section
  FAIL moment-none      (the page)  [1440]
       a software page (--type) deals no moment: every kind carries one, two on a long page (moments.md)
       fix: deal one (moments.mjs pick --page software) and mount it in its own section
  FAIL hero-screen      main#top > section.hero "电脑分享的文件周末旅行下载到当前设备，或把文件上传至电脑。4 个文件总计 213"  [1440]
       the hero ends at 249px on a 900px screen, 651px above the fold: it ends at the fold, 1px either way (SR-1)
       fix: make the hero exactly one screen (height: 100svh, its content fitted inside), never taller or shorter
  FAIL hero-screen      main#top > div.workspace "下载文件点击文件即可下载 ZIP周末旅行照片.zip压缩包142 MB下载 IM"  [1440]
       619px of the next section shows on the first screen (from 281px on a 900px screen): nothing below the hero shows at load (SR-1)
       fix: end the hero at the fold so nothing of the next section shows at load (hero height: 100svh)
  FAIL section-height   main#top > footer.footer "LanDrop · 局域网文件传输文件通过此电脑的本地服务传输"  [1440]
       the section is 46px tall (0.1 screens), 854px short of one screen (900px): every section after the hero is one screen or two, 2px either way (SR-2)
       fix: set the section to one screen or two (height: calc(var(--h,1) * 100vh), --h 1 or 2) and cut or split its content to fit
  FAIL one-section      h1#page-title "周末旅行"  [1440]
       the screen at scroll 0px (stride 0) shows 120px of section 1 and the heading of section 1 whole and the content of 2 sections, over 24px each beside section 2: a screen shows one section (another may peek 8px, 24px WARN)
       fix: make each section exactly one screen or two, so a screen shows one section and no neighbour peeks
  FAIL one-section      main#top > div.workspace "下载文件点击文件即可下载 ZIP周末旅行照片.zip压缩包142 MB下载 IM"  [1440]
       a <div> sits directly in <main>: every part of <main> is a <section> (SR-4)
       fix: put every block of <main> in a <section>, and give a band its own section instead of a ground inside one
  FAIL one-heading      h2#upload-heading "上传至电脑"  [1440]
       the section holds 2 h2 headings: one per section, first in its .wrap (SR-5)
       fix: give each section one h2, first in its .wrap, and the hero only its h1
  FAIL container-edges  header.topbar "跳转到文件传输LanDrop局域网文件传输"  [1440]
       a <header> at the top of the page, outside header.nav, main, footer.closing and nav.actionbar (SR-6)
       fix: build the page as header.nav, a main of sections (each one in-flow .wrap plus background layers) and footer.closing
  FAIL container-edges  main#top > section.hero "电脑分享的文件周末旅行下载到当前设备，或把文件上传至电脑。4 个文件总计 213"  [1440]
       the section needs exactly one in-flow child .wrap (it has 2 in-flow children, 0 .wrap) (SR-6)
       fix: build the page as header.nav, a main of sections (each one in-flow .wrap plus background layers) and footer.closing
  FAIL container-edges  main#top > div.workspace "下载文件点击文件即可下载 ZIP周末旅行照片.zip压缩包142 MB下载 IM"  [1440]
       the section needs exactly one in-flow child .wrap (it has 2 in-flow children, 0 .wrap) (and 1 more like it: "LanDrop · 局域网文件传输文件通过此电脑") (SR-6)
       fix: build the page as header.nav, a main of sections (each one in-flow .wrap plus background layers) and footer.closing
  FAIL container-edges  div.workspace > aside > p.network-note > span "请连接同一 Wi-Fi传输时请保持电脑上的 LanDrop 和本页面打开。"  [1440]
       1 text block starts on a left line at x 1010, 890px from the container's left: text starts on the container's left, or on one split line (x 630, 732, 834) (SR-6)
       fix: start the text on the container's left, or on the one split line every split shares
  FAIL container-edges  h2#upload-heading "上传至电脑"  [1440]
       the h2 starts 885px right of the container's left: every h1 and h2 starts on it, 2px either way (SR-6)
       fix: start the text on the container's left, or on the one split line every split shares
  FAIL container-edges  main#top > div.workspace > aside > p.network-note "请连接同一 Wi-Fi传输时请保持电脑上的 LanDrop 和本页面打开。"  [1440]
       1 text block starts on a left line at x 980, 860px from the container's left: text starts on the container's left, or on one split line (x 630, 732, 834) (and 2 more like it: x 145, "下载文件") (SR-6)
       fix: start the text on the container's left, or on the one split line every split shares
  FAIL container-edges  main#top > div.workspace > section.download-panel "下载文件点击文件即可下载 ZIP周末旅行照片.zip压缩包142 MB下载 I  [1440]
       a box over half the container wide runs 120-956px, not on the container's lines at 120-1320px (SR-6)
       fix: run the picture or box from the container's left line to its right line, or put it in a row or a split
  FAIL flush            section.hero > div.stats > div.stat:nth-of-type(1) > strong "4"  [390]
       its last line sits 5px above the rule on top of section.download-panel
       fix: give the section its padding at the edge where the ground changes (the closing call keeps a clear gap above the footer)
  FAIL flush            section#upload-panel "当前设备 → 电脑 上传至电脑 选择文件，发送到这台电脑的接收目录。 选择上传文"  [390]
       its first line sits 0px under the top edge of aside, where the ground changes
       fix: give the section its padding at the edge where the ground changes (the closing call keeps a clear gap above the footer)
  FAIL text-only        main#top > div.workspace > aside "上传至电脑"  [390]
       the closing section is only text: no picture, icon, mock or effect in it
       fix: give the section a visual: a photograph that fits, the real icons, or a UI fragment on a ground
  FAIL edge-left        div.workspace h2 "下载文件"  [1440, 390]
       starts at x 145; the lines are 120 and the column starts
       fix: start it on the .wrap left line
  FAIL edge-left        div.workspace p.network-note "请连接同一 Wi-Fi传输时请保持电脑上的 LanDrop 和本"  [1440]
       starts at x 980; the lines are 120 and the column starts
       fix: start it on the .wrap left line
  FAIL screen-short     section.hero section.hero "电脑分享的文件周末旅行下载到当前设备，或把文件上传至电脑。4 个"  [1440, 390]
       120px tall; one screen under the nav is 900px
       fix: make the section one full screen (--h: 1, layout-v4.md section 2)
  FAIL neighbour        section.hero section.hero "电脑分享的文件周末旅行下载到当前设备，或把文件上传至电脑。4 个"  [1440]
       framed, 29px of the footer shows
       fix: keep the next section's heading and picture out of this screen
  FAIL hero-fold        section.hero section.hero "电脑分享的文件周末旅行下载到当前设备，或把文件上传至电脑。4 个"  [1440, 390]
       starts at y 129, not under the nav
       fix: the hero fills the first screen alone, its button inside it
  WAIVED motion-layer html[data-motion]: The actual offline server response embeds the full hover, press and reduced-motion CSS in this one HTML file rather than requesting motion.css. Full consistency reports hover-move PASS and reduced-motion PASS; this is not a missing interaction.
  WAIVED hero-enter main#top > section.hero: This task page has an actual once-only CSS rise animation and data-enter. It is readable with scripts off and under reduced motion, without a separate html.m-enter boot script. The required load feedback exists without a hidden initial state.
  WAIVED menu-toggle button#theme-toggle "切换深色模式": This control toggles a light/dark preference, not a disclosure menu. It already exposes aria-pressed and a changing accessible name; aria-expanded would misrepresent the interaction.
  16 WARN (not blocking), first: flush h2#download-heading "下载文件"; flush main#top > div.workspace > section.downl; flush div.workspace > aside > p.network-note >; copy-headline h1#page-title "周末旅行"; copy-actions (the page)
Stop fixing: put these open FAILs and the waivers in your report, then finish.
GATE: OPEN 26 (rounds used up)
```

## 性能完整输出

```text

perf index.html @ 1440px
  WARN  host CPU load (before/after)               91/25 %        busy host: timing verdicts capped at WARN, rerun when idle
  PASS  total transfer                             16.1 KiB       html 8K  other 8K
  PASS  requests                                   2              1 by load
  PASS  images bytes                               0 KiB          0 files
  PASS  JS parsed                                  0 KiB          0 files, 0K gz
  PASS  CSS                                        0 KiB          0 files
  PASS  font families                              0
  PASS  font files                                 0              0K
  PASS  images without width+height                0
  PASS  below-fold images not lazy                 0
  PASS  oversized images (natural > 2.2x shown)    0
  PASS  WebGL live at load                         0
  PASS  WebGL live at bottom                       0
  PASS  WebGL peak live                            0              0 contexts made in all
  PASS  long tasks                                 0              runs 3, 0..0, busy host, max 0ms
  PASS  blocking time                              0 ms           runs 3, 0..0, busy host ms; at load 0ms
  PASS  FCP (CPU, relative)                        64 ms          runs 3, 44..64, busy host
  PASS  LCP (CPU, relative)                        64 ms          runs 3, 44..64, busy host, span
  PASS  layout shift                               0.000          runs 3, 0.000..0.000; at load 0.000
  PASS  modules loaded, never mounted              0
  PASS  broken requests                            0
  PASS  page height                                1.1 screens    DOM 119 nodes

perf index.html @ 390px
  WARN  host CPU load (before/after)               91/25 %        busy host: timing verdicts capped at WARN, rerun when idle
  PASS  total transfer                             16.1 KiB       html 8K  other 8K
  PASS  requests                                   2              1 by load
  PASS  images bytes                               0 KiB          0 files
  PASS  JS parsed                                  0 KiB          0 files, 0K gz
  PASS  CSS                                        0 KiB          0 files
  PASS  font families                              0
  PASS  font files                                 0              0K
  PASS  images without width+height                0
  PASS  below-fold images not lazy                 0
  PASS  oversized images (natural > 2.2x shown)    0
  PASS  WebGL live at load                         0
  PASS  WebGL live at bottom                       0
  PASS  WebGL peak live                            0              0 contexts made in all
  PASS  long tasks                                 0              runs 3, 0..0, busy host, max 0ms
  PASS  blocking time                              0 ms           runs 3, 0..0, busy host ms; at load 0ms
  PASS  FCP (CPU, relative)                        56 ms          runs 3, 52..56, busy host
  PASS  LCP (CPU, relative)                        56 ms          runs 3, 52..56, busy host, h1
  PASS  layout shift                               0.000          runs 3, 0.000..0.000; at load 0.000
  PASS  modules loaded, never mounted              0
  PASS  broken requests                            0
  PASS  page height                                1.7 screens    DOM 119 nodes

SUMMARY index.html: 0 FAIL, 2 WARN  -> WARN
```
