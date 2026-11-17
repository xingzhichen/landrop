# LanDrop

**电脑打开，手机扫码，文件在同一局域网内互传。** 支持 macOS、Windows；手机用浏览器即可，**不用安装 App**。

[下载 1.2.0 桌面版](<https://github.com/xingzhichen/landrop/actions/runs/44091260031#artifacts>) · [查看最新构建](<https://github.com/xingzhichen/landrop/actions/workflows/build-desktop.yml>) · [反馈问题](<https://github.com/xingzhichen/landrop/issues>)

电脑可以分享多个文件或整个文件夹，手机可下载、预览，也能把照片和文件传回电脑。先下载安装桌面版，再按下方步骤操作。

> 下图均为操作演示，文件名、地址和速度仅作示意；实际请以自己电脑上显示的信息为准。

![LanDrop 桌面端与手机浏览器传输页面总览](<docs/images/01-overview.webp>)

## 1. 下载桌面版

**本仓库目前没有 GitHub Release。可下载的桌面版在 GitHub Actions 构建产物中，不需要下载源码或安装开发工具。**

1. 登录一个免费的 [GitHub 账号](<https://github.com/login>)，打开 [1.2.0 构建页面](<https://github.com/xingzhichen/landrop/actions/runs/44091260031>)；也可进入 [最新构建列表](<https://github.com/xingzhichen/landrop/actions/workflows/build-desktop.yml>)，选择带绿色成功标记的一次构建。
2. 留在 **Summary（摘要）**，滚动到页面最底部的 **Artifacts（构建产物）**。
3. Mac 点击 **LanDrop-macOS**，Windows 点击 **LanDrop-Windows**，下载 ZIP。左侧的 macOS / Windows job 是构建日志，**不是下载入口**。

**找不到下载？** Artifacts 会过期，请换较新的成功构建；如果都已过期，请 [提 Issue 请维护者重新构建](<https://github.com/xingzhichen/landrop/issues>)。仓库的 **Code → Download ZIP 只是源码，不能双击安装**。

![GitHub Actions 成功构建列表、Summary 与底部 Artifacts 下载入口](<docs/images/02-github-download.webp>)

## 2. 解压并打开

**通常需要解压两次：** 浏览器下载的是外层 Artifact ZIP，解压后得到内层 `LanDrop-macOS.zip` 或 `LanDrop-Windows.zip`；再解压内层 ZIP，然后按对应系统操作。如果浏览器已自动解压，看到 `.app` 或 `.exe` 就不必重复解压。

| macOS | Windows |
| --- | --- |
| 将解压得到的 `LanDrop.app` 拖入「应用程序（Applications）」，再打开。 | 将内层 ZIP **完整解压**到一个固定文件夹，再运行其中的 `LanDrop.exe`，没有 MSI / EXE 安装向导。 |
| 当前构建未使用 Developer ID 签名、未公证，首次可能被系统拦截。**只有确认来自本仓库后**，才到「系统设置 → 隐私与安全性」允许打开；不要全局关闭 Gatekeeper。 | **保持 EXE、DLL 和 `data` 文件夹在同一目录**，不要只取出 EXE。首次出现防火墙提示时，仅允许可信的「专用网络」。 |

![外层 Artifact ZIP 与内层应用 ZIP 的两次解压，以及 Mac 和 Windows 启动流程](<docs/images/03-install.webp>)

## 3. 电脑分享，手机扫码

1. 让电脑和手机连接**同一 Wi-Fi**；电脑用网线连接同一路由器也可以。
2. 电脑点击「**新建页面**」→ 填写名称 → 选择多个文件 →「**创建并启动**」。分享整个目录可直接点「**分享文件夹**」；也可把文件或文件夹拖入窗口，再选择新建或加入已有页面。
3. 用手机扫描**自己电脑当前页面上的二维码**，在浏览器打开。**不要扫描本指南截图里的演示二维码。**

每个页面都可独立启动、停止、重启或删除。分享时读取原文件，不复制原文件；删除页面也不删除原文件或已接收文件。分享期间请勿移动、删除或修改原文件。

![电脑端新建页面、分享文件夹、拖入文件与实际分享二维码的位置](<docs/images/04-share.webp>)

## 4. 手机上下载或上传

- **下载到手机：** 点击单个文件下载；或勾选多个文件，再下载 ZIP。图片、音频、视频可在网页内预览，具体格式能否播放取决于浏览器。
- **上传到电脑：** 在同一网页向下找到上传区域 →「选择上传文件」→「上传到电脑」。支持多选，**每个文件最多 1 GiB**；上传时保持网页在前台。
- **断网后继续：** 恢复网络后点「继续上传」；若刷新或重开网页，重新选择**同一原文件**即可恢复。手机系统可能挂起后台浏览器，不能保证自动后台上传。

![手机浏览器中的单文件下载、勾选 ZIP、媒体预览和上传到电脑操作入口](<docs/images/05-phone.webp>)

## 5. 在电脑找到收到的文件

打开「**接收记录**」查看文件名、保存路径、所属页面和接收时间。记录会持久保存，可复制路径、打开文件夹，或在 **Finder / 文件资源管理器**中定位文件；不会自动打开或运行收到的文件。

默认位置为「**下载 / LanDrop / 页面 ID**」（下载目录不可用时可能回退到文档目录）。每页的「**接收设置**」可覆盖默认保存位置，也可开启按日期整理；**只影响新任务**，不会搬动旧文件或已开始的续传任务，同名文件不会覆盖。

![持久化接收记录、完整保存路径、打开文件夹与 Finder 定位入口](<docs/images/06-received.webp>)

## 6. 查看进度，按需取消

「**传输动态**」显示实际传输进度、速度、预计剩余时间（ETA），也可以取消任务。ZIP 准备阶段可以取消，准备完成前尚未开始发送。

**发送进度不代表对方已保存到磁盘。** 手机下载完成后，请在浏览器下载列表或手机文件管理器中确认；上传则可在电脑的接收记录中确认。

![传输动态中的实际进度、速度、预计剩余时间和取消操作](<docs/images/07-transfers.webp>)

## 7. 关窗口后，还能继续传吗？

默认关闭主窗口只是隐藏到 **Mac 菜单栏 / Windows 系统托盘**，传输服务仍在运行；点击图标可重新显示窗口。可在「**应用设置**」关闭后台模式。

**真正退出应用会停止服务，电脑睡眠或断网也会中断传输。** 传输期间请让电脑保持唤醒；重启应用或页面后端口可能变化，应重新扫描当前二维码。

![应用设置中的后台模式开关及关闭窗口后的菜单栏或托盘行为](<docs/images/08-settings.webp>)

## 常见问题

**扫码后打不开网页？**

先确认在同一网络、电脑上的页面已启动，重新扫描当前二维码，并检查防火墙是否允许 LanDrop。访客 Wi-Fi 的「客户端隔离」可能阻止设备互访，可换到可信的普通家庭网络；不要为了连通而关闭整个防火墙。

**手机文件下载到哪里了？**

先看浏览器的下载列表，再到手机「文件」或文件管理器中找下载目录；系统和浏览器的保存位置可能不同，下载后也不一定自动出现在相册。

**ZIP 下载中断了，能继续吗？**

ZIP **不支持断点续传**，中断后需要重新下载，电脑还需留有临时磁盘空间。大文件建议单独下载；单文件能否恢复下载取决于浏览器或下载器，重启后旧链接不保证有效。

**取消上传或删除页面，会删掉文件吗？**

取消上传或删除页面会清理对应的未完成上传数据，之后不能恢复该任务；已经接收完成的文件和电脑原有文件不会删除。

**可以跨网、发到公网，或者设置密码吗？**

目前只面向**可信局域网**，使用明文 **HTTP，无密码、无 TLS 加密**。能访问页面的设备都可能下载或上传；请勿把端口暴露到公网，也不要直接运行来源不明的文件。

## 开发与项目资料

<details>
<summary>开发者展开：源码、构建命令与旧版原型</summary>

当前主工程是 [Flutter 工程](<flutter_app>)，桌面使用 Flutter/Dart，手机网页为不依赖 CDN 的自包含 HTML/CSS/JS。仅交付 macOS / Windows 桌面版；工程中的移动平台脚手架不代表已提供手机 App。

- [架构与协议](<ARCHITECTURE.md>)
- [1.2 验证记录与已知边界](<RELEASE-1.2.md>)
- [GitHub Actions 构建配置](<.github/workflows/build-desktop.yml>)：推送 `master` 或手动触发，分析、测试并构建两端，再上传 Artifacts；这些不是已公证的正式安装包。

安装 [Flutter stable](<https://docs.flutter.dev/get-started/install>)，从仓库根目录执行；生产入口为 `lib/main.dart`，两种桌面构建分别在对应系统上运行：

```bash
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter run -d macos -t lib/main.dart
# Windows 上运行：flutter run -d windows -t lib/main.dart
flutter build macos --release -t lib/main.dart
# Windows 上运行：flutter build windows --release -t lib/main.dart
bash tool/package_macos.sh  # 仅 macOS，构建后打包
```

macOS 使用 [打包脚本](<flutter_app/tool/package_macos.sh>) 保留文件选择权限并验证最终签名；不要用不带 entitlements 的签名命令替换。公开分发仍需另行配置 macOS 公证或 Windows 代码签名。

根目录的 [Swift 源码](<Sources/LanDrop>) 是最初的 macOS 原型，仅供参考；根目录构建脚本只构建旧原型，不包含当前版本功能。

</details>
