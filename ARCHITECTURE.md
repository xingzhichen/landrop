# LanDrop 技术架构

## 产品与分层

主产品是 [Flutter 桌面工程](<flutter_app>)，面向 macOS / Windows。手机使用浏览器，无需安装 App。Dart `HttpServer` 在电脑上提供局域网文件服务，不依赖云服务、WebView 或 CDN。

- [工作台](<flutter_app/lib/main.dart>)：以命名传输为中心，二维码、分享文件、该传输的接收记录、拖拽导入及主题/应用设置均在对应位置。
- [控制器](<flutter_app/lib/landrop_controller.dart>)：独立监听器、动态清单、磁盘流、Range、会话/回执、传输任务取消及持久状态。
- [ZIP worker](<flutter_app/lib/zip_service.dart>)：工作 isolate 中使用磁盘流构建 STORE ZIP/ZIP64，避免大文件读入内存或阻塞 UI。
- [网页模板](<flutter_app/lib/download_page.dart>)：转义后的真实文件列表、多选 ZIP、受限媒体预览、分块上传和可减弱动效；没有外部网络资源。
- [桌面外壳](<flutter_app/lib/desktop_shell.dart>)：原生拖放、窗口显示、菜单栏/托盘、后台模式与退出。
- [文件管理器桥](<flutter_app/lib/desktop_file_manager.dart>)：仅打开目录/定位文件，不执行收到的文件。

## HTTP 协议

每个页面使用独立 IPv4 TCP 端口。启动时使用系统分配端口，重启后旧地址不保证有效。

| 请求 | 作用 |
|---|---|
| `GET /` | 自包含传输网页；标题与文件增删会自动刷新 |
| `GET/HEAD /manifest` | 本传输的动态清单，无本地路径、同页缓存1秒、并发扫描合并 |
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

- 命名传输、带归属 ID 的接收记录、未完成会话和有限完成回执使用 SharedPreferences 独立版本 key；迁移旧记录时只会归入唯一匹配的旧传输。
- 文件夹递归只加入普通文件，跳过 symlink，记录 relativePath；ZIP 路径净化和唯一化，不接受客户端任意本地路径。分享文件持久化选择时的 canonical path，清单、单文件和 ZIP 请求都会复核目标，检测校验时已经发生的祖先 symlink 替换；旧记录升级时为现存普通文件建立基线，缺失/不安全条目保持不可下载，需重新选择。网页 GET /manifest 只枚举本传输 ID 白名单内的文件，不泄露本机 path；每传输清单1秒去重/合并，变更即时失效并有界并行检查。
- 接收根目录默认 Downloads/LanDrop，回退应用文档目录；可按传输覆盖，并追加传输UUID及可选日期目录。子目录不得是链接。
- 收到文件先写随机 `.part`，完整后独占保留不重名目标，再提交文件与记录。分块会话持久化各自授权的传输目录与 canonical root，后续目录设置只影响新会话；恢复时校验 `.part` 仍位于已授权目录内。旧版会话从经过结构校验的 `.part` 路径推断原目录。启动恢复时按会话隔离文件系统异常：暂不可访问的恢复记录与配额会保留、页面显示警告，恢复权限后重启可重试。
- 原始旧版上传断开后清理 partial。分块上传断网/stop 后保留可恢复数据；cancel/removePage 先持久化 `deleting` 意图，再通过 native `landrop/secure_fs` 从 canonical receive root 逐组件 no-follow 打开目录，并相对已打开的父目录句柄清理 `.part`，不删除已收文件；恢复目录不可访问或被替换时保留会话记录、操作不报成功，修复原路径后重试；重启时对此类会话只重试清理，不恢复成可续传会话，避免崩溃后把已取消记录复活；若临时文件已被外部移动，残留文件需手动处理。每页最多16个、全局最多保留128个未完成会话，并按声明大小合计预留最多4GiB；新建会话同步预留完整大小，完成/取消释放，恢复会话也计入预算；升级恢复的会话数量超限存量仍可续传，但若其预留字节超过4GiB则保留数据并拒绝PATCH/新建，需先取消部分会话降低预留；整个 App 同时进入业务 handler 的 HTTP 请求最多64个（超限请求不进入 handler；拒绝响应最多16路，带 body 的请求最多排空250ms；超额快速关闭且错误响应体不保证送达）；同时接收的数据流最多8个、单文件下载最多16个、ZIP 打包最多2个，超限返回429；数据流超过2分钟无新数据时返回408，分块会话保留已确认偏移以便续传。
- 完成回执24小时过期，每页最多64条、总计256条，只含 id/pageId/name/size/time，不含路径。complete 响应丢失后可重试确认，不重复保存；新建上传仍允许用户主动重传同一文件。
- 接收文件历史只保留每传输最近200条、全局最近1000条；删除传输会删其历史元数据但不触碰已保存文件，限制偏好设置体积和工作台列表长度。
- 应用内受管分享副本位于 Application Support 下的 `landrop_shared_files/<uuid>`。读写前校验 root 的 canonical path 与 native 目录身份；删除通过各平台 secure_fs 从应用数据根逐组件 no-follow 打开并相对目录句柄 unlink。`removeFile`/`removePage` 会先持久化 managed-delete journal，再移除页面元数据；删除失败或崩溃时保留意图，启动后仅在页面不再引用该 ID 时重试；目录/记录异常时持久化 cleanup-quarantine marker 并关闭孤儿扫描，避免把无法归属的文件误删；这个隔离在重启后仍有效。应用还持久化受管根目录身份，跨重启检测普通目录替换；无受管引用/删除意图时可在新根目录重建 pin，但会先持久化隔离孤儿扫描，避免清理替换目录中的未知 UUID 项。升级时未 pin 的旧条目只会在路径严格等于固定 root/UUID、no-follow 检查为普通文件时建立基线；失败会持久化 blocked 标志，不会因后来出现同名文件而重新授权。`addFiles`/`addPaths` 与页面删除互斥，删除会等待已开始的导入完成。导入写入仍使用 Dart 路径 API（exclusive create、前后身份校验、失败清理），没有把整段文件流写入 native pinned handle；因此不能声称抵御同 UID 恶意进程对最终 leaf/路径的并发替换，失败时可能留下待启动扫描的孤儿文件。
- 真实收发 task 仍供传输/取消协议使用，但不再设独立的全局「传输动态」界面；当前工作台按传输呈现分享清单和本传输的接收历史。终态 task 最多保留最近128条，活动任务与未完成分块会话任务不参与裁剪。发送进度不代表对端保存证明。

## 主题与原生桌面生命周期

App 提供 system/light/dark 三种偏好。默认保存 `ThemeMode.system`，由操作系统亮度动态驱动，不把当前系统亮度固化为用户浅/深选择；手动切换浅色/深色时持久化偏好。网页原生使用 `prefers-color-scheme` 自动匹配。


macOS 使用 AppKit 状态栏及窗口隐藏，Windows 使用通知区域图标与 WM_DROPFILES；关闭主窗默认不释放 Flutter engine。显式退出才终止服务；后台模式可关闭并持久保存。Windows 也给 Flutter 子 HWND 注册拖放，处理 Explorer 重启后的托盘恢复。Mac 支持 drag-enter/leave 高亮，Windows WM_DROPFILES 不提供该前置反馈。

文件夹定位使用 NSWorkspace / Windows Shell API，不拼接 shell 命令。拖入路径只作为本地待选分享条目，不打开或执行文件。

## 安全与交付

适用可信局域网：没有 TLS、账号/密码、杀毒或全局磁盘配额，不要映射公网。保留同源写入 Origin/Host/Fetch-Site 校验、不开放 CORS、UUID 页面隔离、文件名净化、1GiB 单文件限制、nosniff、受限同源 CSP；HTML/SVG 等不以内联媒体返回。拒绝的上传请求会先发送完整 HTTP 错误，再最多等待 250ms 排空残余请求体，避免无界等待及 unread body 导致连接复位。分块会话的 `.part` 由 native secure_fs 在已验证的根/父目录句柄下 exclusive-create 并返回 leaf identity（POSIX `st_dev`/`st_ino`，Windows volume/file ID），身份与目录 pin 一起持久化在 session 记录；恢复续传前会重新获取 leaf identity 并与记录比较。删除时要求传入预期 leaf identity：POSIX 的 Android/iOS/macOS 路径会将 `.part` 以 no-replace 原子 rename 移入根下 `.landrop-quarantine/<session UUID>` 私有子目录，再核对身份，仅删除匹配对象；不匹配时只尝试 no-replace 恢复，冲突则保留隔离项和 `deleting` 意图，重启后可重放。每个 session 隔离子目录的 identity 与删除意图一起持久化；重放必须重新打开同一目录 identity，缺失/替换时不会重建或清除 marker。确认删除完成并持久化清除 marker 后，才尝试移除已验证为空的 session 子目录。隔离目录每次都 no-follow 打开、检查 owner/device 并收紧到 `0700`；Windows 在 no-follow 打开的叶子句柄上比较 FILE_ID_INFO，再通过同一句柄设置删除标志。缺失/链接/reparse root 或身份不匹配都会失败并保留 `deleting` 意图；目录身份匹配且日期父目录确认不存在时按幂等清理完成，leaf 缺失也仅在目录身份匹配后幂等成功。没有 leaf identity 的旧 session 不会被自动恢复或删除，而是保留待恢复警告。原始上传 `.part` 与目标名占位文件也使用 no-replace quarantine；隔离目录与叶子身份在 unlink 前写入独立恢复日志，启动时重放，清除日志后才尝试移除已验证为空的 session 子目录。崩溃恰好发生在日志写入前或清除后，可能留下空的 session 子目录，仅影响存储卫生。Windows 接收目录限本地驱动器，不支持 UNC/网络映射盘。原始/分块上传普通读写、受管副本导入写入及外部非受管分享源读取仍使用路径访问。受管副本读取已改为 native 有界 chunk：每块都在同一 no-follow 打开的叶子句柄上核对 identity 并读取，读取前后校验长度和修改时间；块间替换会中止读取，ZIP 也先用该 API 把受管输入复制到本次任务的私有临时快照再交给 worker。该设计不维持跨块打开句柄，不能防恶意同 UID 对同一 inode 原地修改并恢复元数据；导入写入仍未绑定 native handle。
- no-replace 原子 quarantine 与隔离后身份复核用于 POSIX 分块会话删除及原始上传临时/目标清理；两者均有持久化恢复意图。隔离目录根按 owner/device/mode 检查，每个 session 子目录另有持久化 identity；POSIX 对 quarantine 文件执行的最终 `unlinkat` 仍基于目录名，不能抵御恶意同 UID 进程。Windows 接收删除比对已打开句柄，但 Dart 文件读写仍未绑定到该句柄。新建/导入的受管副本在提交共享前捕获并持久化 leaf identity，服务前重新校验；删除意图优先使用该创建 pin 并写入 journal，恢复时不重新授权当前占位。旧记录首次升级时仅对当前存在且 root/path 校验通过的普通文件建立一次性叶子基线，这不能证明升级前未被替换；缺失或损坏身份会 fail-closed。native unlink 会在核对预期 root 与 leaf identity 后执行。Windows 在同一已打开叶子句柄上比较并设置删除标志；POSIX 最终按目录项名称执行 `unlinkat`，仍保留恶意同 UID 进程在身份核验与 unlink 之间替换目录项的竞态。受管副本读取虽按 chunk 验证同一打开句柄并跨 chunk 比较元数据，但不是跨 chunk 的不可变句柄快照；同 UID 可原地篡改并恢复元数据的风险仍存在。Android armeabi-v7a secure_fs 显式启用 `_FILE_OFFSET_BITS=64` 并以编译期断言保护 64-bit `off_t`，避免大文件读取偏移截断。

macOS 当前为非 App Store 分发，App Sandbox 关闭，带文件选择权限；公开发布仍需 Developer ID 与公证。Windows 需整体分发 EXE/DLL/data；正式代码签名另配。根目录 Swift 原型不是本版主产品。
