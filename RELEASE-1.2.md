GATE: OFF (no build active)

# LanDrop 1.2.0 验证记录

## 本版范围

第一、第三优先级已实现：

- 文件及文件夹原生拖拽；可新建页面或导入已有页面，保留普通文件的相对目录。
- 接收记录跨重启持久化，显示时间、实际路径并保留文件夹定位。
- 网页全选/多选 ZIP 下载；工作 isolate + 流式磁盘构建，支持 ZIP64 与准备阶段取消。
- 桌面传输动态：真实收发字节、速度、ETA、状态及取消。
- 手机分块上传断点续传；保存会话并校准真实磁盘偏移；完成回执可幂等确认。
- 单文件下载 Range + ETag / If-Range / Last-Modified，源文件改变时回退整文件。
- 独立页面接收根目录与日期整理；不搬动已有文件和已开始的会话。
- macOS 菜单栏 / Windows 托盘，默认关闭隐藏而不停止服务，设置可关闭后台模式。
- 网页安全图片、音频、视频预览，关闭后停止媒体读取；格式/编解码支持由浏览器决定。
- 两端操作动效：按钮 hover/press、导航切换、拖入高亮、面板尺寸变化、进度过渡、上传状态、主题与媒体预览；减少动态效果时静止可读。

## 回归与原生构建

- 最终 `flutter analyze`：No issues found。
- 最终 `flutter test`：**73项全部通过**，默认并发运行。
- 桌面实际字体截图测试及新增工作台交互测试通过，覆盖1440/1024/820/680/390；四个导航在1440/390均无 RenderFlex overflow。
- 真实 Dart HttpServer + Node 执行服务器实际生成 JS 的联调覆盖：4MiB分块、409偏移校准、断网后恢复、重新选择原文件、取消/清理、跨页隔离、来源拒绝、媒体、ZIP、完成回执。
- 首次 Windows CI 暴露路径断言分隔符及强杀 ZIP isolate 后遗留文件句柄；已改平台路径 API 和协作式取消，在每次读取检查取消，并在 finally 关闭输入/输出，等待 worker 退出后才完成清理。新增独立子进程检查原生文件句柄释放（Mac lsof / Windows FileShare.None），没有跳过 Windows 测试。
- 引擎测试另外覆盖目录链接跳过、ZIP CRC/路径/重名、128MiB真实socket取消、ZIP准备取消、设置/记录恢复、完成响应丢失及重启后确认、receipt TTL/数量边界、If-Range匹配与源文件变更。
- Mac 原生 Flutter bundle 实际运行：desktop shell initialize、后台模式开关、窗口显示回调、原生 quit 均通过，进程正常退出。
- Mac AppKit 真实窗口 harness：`performClose` 隐藏而非销毁、恢复窗口通过；harness未读取用户页面。
- Mac release 明确以生产入口构建（不是 smoke entrypoint），打包脚本验证文件选择权限与最终签名。
- Windows 原生运行/Explorer拖放、手机 Safari/Chrome 真机系统挂起场景未在本机实测；Windows 编译与测试交 GitHub Actions，不能把静态审查当作实机通过。

## 网页视觉、可访问性与性能

沿用原有 `software` 任务页：cool-grey-cobalt，系统 sans/mono 回退；不新增营销 hero、照片、shader、scene 或装饰循环。Voice card：事实型工具、中文动作、真实进度、明确错误与续传边界。没有虚构客户、数据、价格、新造品牌、外链素材、客户待补插槽或 `.example` 表单；canonical/share海报不适用于每台电脑的临时LAN地址。

- copy-lint：0 FAIL / 0 WARN。
- 完整 consistency 在1440/1024/820/768/390运行；320 walk：0 FAIL。真实布局 overflow/collision、对比、焦点、reduced-motion、hover均通过。
- 发现新增 checkbox 没有可见 label、点击区域过小后，已增加明确关联 label 与44px真实触控区域。最终1440/390 quick复查：field-label、tap-size、spill、off-viewport、collide、focus-ring、focus-visible均PASS，320 walk仍0 FAIL。
- 五种尺寸 layout 检查和截图已生成并人工查看；它的营销hero高度、全屏章节、正文列起点规则仍有开放项，不宣称整体PASS。
- perf：1440/390均 **0 FAIL / 0 WARN**，记录24.7KiB总传输、布局偏移0，无图片/字体外部下载、无WebGL。CPU相对时间不代表手机真机性能。

## 门禁开放项与解释

本次 gate 命令实际输出 `GATE: OFF (no build active)`；按工具规则未再启动或重跑，不能宣称GATE PASS。上轮1.1.0的门禁仍是OPEN，不会把旧结果冒充本版通过。

完整 consistency 初次为147 FAIL / 47 WARN，含重复宽度/屏高细项；修复可见标签和触控目标后最终quick为33 FAIL / 24 WARN（quick跳过动画步进等，因此不能直接作为修复数量对比）。剩余FAIL类型：hero-fill、flush、no-visual、text-only、cta、hero-screen、section-height、one-section、one-heading、container-edges、motion-layer、menu-toggle。没有为了检查器把文件任务藏到全屏宣传区之后，或修改检查器。

继续沿用原验证记录的三项解释（本次gate OFF没有新增生效豁免）：
1. motion-layer：单HTML内联离线动画，不额外请求 motion.css；完整实际hover/reduced-motion检查通过。
2. menu-toggle：主题按钮是aria-pressed的主题开关，不是假装可展开菜单。
3. hero-enter：已有一次性CSS入场；不为工具再加入先隐藏页面的boot脚本。

其他保留WARN：页面名来自用户、不强制品类标题；中文“下载全部ZIP”是实际动词但英文词表不识别；逐文件动作与真实进度条是任务需要；卡片内边距不等同营销章节网格；使用离线系统字体；静态fixture不提供下载端点，但真实HTTP联调已覆盖；页面不设置公共分享海报。未隐瞒这些开放项。

## 使用边界

- 手机系统可挂起后台网页；返回后继续或重新选择原文件，不承诺系统级自动后台传输。
- 应用重启可换端口，需要重新扫码；原下载地址不保证有效。ZIP每次重新生成，不支持续传，需要额外临时磁盘空间。
- macOS有拖入前高亮；Windows WM_DROPFILES只有drop事件，无拖入前高亮。
- 关闭主窗保持传输不等于电脑睡眠后还能传输；显式退出会停止服务。
- 接收记录从本版开始持久化，不能恢复旧版本已丢失的进程内历史。
- 仍为可信局域网明文HTTP，无密码、TLS、杀毒或全局磁盘配额；没有把访问控制第二优先级混入本次交付。
