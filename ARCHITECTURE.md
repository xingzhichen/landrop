# LanDrop 技术架构

## 产品与分层

主产品是 [Flutter 桌面工程](<flutter_app>)，面向 macOS / Windows。手机使用浏览器，无需安装 App。Dart `HttpServer` 在电脑上提供局域网文件服务，不依赖云服务、WebView 或 CDN。

- [工作台](<flutter_app/lib/main.dart>)：页面管理、二维码、持久接收记录、拖拽导入、传输动态及应用设置。
- [控制器](<flutter_app/lib/landrop_controller.dart>)：独立监听器、磁盘流、Range、会话/回执、任务取消及持久状态。
- [ZIP worker](<flutter_app/lib/zip_service.dart>)：工作 isolate 中使用磁盘流构建 STORE ZIP/ZIP64，避免大文件读入内存或阻塞 UI。
- [网页模板](<flutter_app/lib/download_page.dart>)：转义后的真实文件列表、多选 ZIP、受限媒体预览、分块上传和可减弱动效；没有外部网络资源。
- [桌面外壳](<flutter_app/lib/desktop_shell.dart>)：原生拖放、窗口显示、菜单栏/托盘、后台模式与退出。
- [文件管理器桥](<flutter_app/lib/desktop_file_manager.dart>)：仅打开目录/定位文件，不执行收到的文件。

## HTTP 协议

每个页面使用独立 IPv4 TCP 端口。启动时使用系统分配端口，重启后旧地址不保证有效。

| 请求 | 作用 |
|---|---|
| `GET /` | 自包含传输网页 |
| `GET/HEAD /file/<UUID>` | 白名单文件，支持单 Range、ETag、If-Range 和 Last-Modified |
| `GET /file/<UUID>?inline=1` | 仅对受支持的安全媒体类型返回 inline，其余仍是 attachment |
| `GET/HEAD /download.zip?ids=<UUID,UUID>` | 仅打包白名单条目，省略 ids 为全部；无 Range 续传 |
| `POST /uploads?name=&size=&fingerprint=` | 创建/恢复未完成会话，201 `{id,offset,size}` |
| `GET /uploads/<UUID>` | 返回当前真实磁盘 offset，200 `{id,offset,size}` |
| `PATCH /uploads/<UUID>?offset=N` | 接收最多4MiB原始字节，成功200，偏移冲突409 |
| `POST /uploads/<UUID>/complete` | 完整长度且持久化成功后201 `{name,size}` |
| `DELETE /uploads/<UUID>` | 清理未完成数据或完成回执，204；不删除已收文件 |
| `POST /upload?name=` | 兼容旧版一次性原始二进制上传 |

浏览器 fingerprint 来自文件名、大小、mtime 及首尾各64KiB的纯JS SHA-256，用于找回未完成上传，不作为认证或完整文件校验。没有 `crypto.subtle` 的局域网 HTTP 浏览器也可使用。4MiB块的进度表示发送进度；只有201完整保存回执才显示成功。断网暂停后重新读取服务器 offset，不凭浏览器估计偏移。

单文件下载的 If-Range 在源文件改变后回退完整200，避免拼接两个版本的数据。浏览器/下载器决定是否恢复下载。ZIP 每次重新构建；准备阶段没有网络进度，完成后才跟踪输出字节，并支持准备/输出取消。

## 状态与文件生命周期

- 页面、接收记录、未完成会话和有限完成回执使用 SharedPreferences 独立版本 key。
- 文件夹递归只加入普通文件，跳过 symlink，记录 relativePath；ZIP 路径净化和唯一化，不接受客户端任意本地路径。
- 接收根目录默认 Downloads/LanDrop，回退应用文档目录；可按页面覆盖，并追加页面UUID及可选日期目录。子目录不得是链接。
- 收到文件先写随机 `.part`，完整后独占保留不重名目标，再提交文件与记录。后续目录设置不搬动已有会话的目标。
- 原始旧版上传断开后清理 partial。分块上传断网/stop 后保留可恢复数据；cancel/removePage 清理 partial，不删除已收文件。每页最多16个未完成会话。
- 完成回执24小时过期，每页最多64条、总计256条，只含 id/pageId/name/size/time，不含路径。complete 响应丢失后可重试确认，不重复保存；新建上传仍允许用户主动重传同一文件。
- 活跃传输列表来自真实字节流，UI 仅做短时插值反馈；任务速度/ETA是估算，不是对端保存证明。完成任务面板仅显示最近30项，接收历史独立持久化。

## 原生桌面生命周期

macOS 使用 AppKit 状态栏及窗口隐藏，Windows 使用通知区域图标与 WM_DROPFILES；关闭主窗默认不释放 Flutter engine。显式退出才终止服务；后台模式可关闭并持久保存。Windows 也给 Flutter 子 HWND 注册拖放，处理 Explorer 重启后的托盘恢复。Mac 支持 drag-enter/leave 高亮，Windows WM_DROPFILES 不提供该前置反馈。

文件夹定位使用 NSWorkspace / Windows Shell API，不拼接 shell 命令。拖入路径只作为本地待选分享条目，不打开或执行文件。

## 安全与交付

适用可信局域网：没有 TLS、账号/密码、杀毒或全局磁盘配额，不要映射公网。保留同源写入 Origin/Host/Fetch-Site 校验、不开放 CORS、UUID 页面隔离、文件名净化、1GiB单文件限制、nosniff、受限同源 CSP；HTML/SVG 等不以内联媒体返回。

macOS 当前为非 App Store 分发，App Sandbox 关闭，带文件选择权限；公开发布仍需 Developer ID 与公证。Windows 需整体分发 EXE/DLL/data；正式代码签名另配。根目录 Swift 原型不是本版主产品。
