# LanDrop

**电脑打开，手机扫码，文件在同一局域网内互传。** 支持 macOS、Windows；手机用浏览器即可，**不用安装 App**。

[下载当前桌面版（GitHub Release）](<https://github.com/xingzhichen/landrop/releases/latest>) · [反馈问题](<https://github.com/xingzhichen/landrop/issues>)

电脑可以分享多个文件或整个文件夹，手机可下载、预览，也能把照片和文件传回电脑。先下载安装桌面版，再按下方步骤操作。

> 下图均为操作演示，文件名、地址和速度仅作示意；实际请以自己电脑上显示的信息为准。

![LanDrop 桌面端与手机浏览器在同一个传输里双向收发文件](<docs/images/01-overview.webp>)

## 1. 下载桌面版

**正式版本从 [GitHub Releases](<https://github.com/xingzhichen/landrop/releases/latest>) 下载**，选择 `LanDrop-macOS.zip` 或 `LanDrop-Windows.zip`；不需要下载源码或安装开发工具。

**备用下载：** 如果 Release 暂不可用，可登录免费的 [GitHub 账号](<https://github.com/login>)，打开 [最新构建列表](<https://github.com/xingzhichen/landrop/actions/workflows/build-desktop.yml>)，选择带绿色成功标记的一次构建；在 **Summary（摘要）** 页面底部的 **Artifacts（构建产物）** 中下载对应平台包。左侧的 macOS / Windows job 是构建日志，**不是下载入口**。

**找不到备用包？** Actions Artifacts 会过期，请换较新的成功构建；如果都已过期，请 [提 Issue 请维护者重新构建](<https://github.com/xingzhichen/landrop/issues>)。仓库的 **Code → Download ZIP 只是源码，不能双击安装**。

![备用下载方式：GitHub Actions 成功构建列表、Summary 与底部 Artifacts 下载入口](<docs/images/02-github-download.webp>)

## 2. 解压并打开

从 **GitHub Release** 下载的 `LanDrop-macOS.zip` / `LanDrop-Windows.zip` 解压一次即可，再按对应系统操作。若使用上面的 **Actions 备用 Artifacts**，浏览器下载的是外层 ZIP：先解压得到内层 `LanDrop-macOS.zip` 或 `LanDrop-Windows.zip`，再解压内层 ZIP。如果浏览器已自动解压，看到 `.app` 或 `.exe` 就不必重复解压。

| macOS | Windows |
| --- | --- |
| 将解压得到的 `LanDrop.app` 拖入「应用程序（Applications）」，再打开。 | 将内层 ZIP **完整解压**到一个固定文件夹，再运行其中的 `LanDrop.exe`，没有 MSI / EXE 安装向导。 |
| 当前构建未使用 Developer ID 签名、未公证，首次可能被系统拦截。**只有确认来自本仓库后**，才到「系统设置 → 隐私与安全性」允许打开；不要全局关闭 Gatekeeper。 | **保持 EXE、DLL 和 `data` 文件夹在同一目录**，不要只取出 EXE。首次出现防火墙提示时，仅允许可信的「专用网络」。 |

![外层 Artifact ZIP 与内层应用 ZIP 的两次解压，以及 Mac 和 Windows 启动流程](<docs/images/03-install.webp>)

## 3. 新建一个传输

1. 让电脑和手机连接**同一 Wi-Fi**；电脑用网线接同一路由器也可以。
2. 电脑点击「**新建传输**」，只输入一个名称就能创建并启动，不必先选文件。
3. 打开这个传输后，再点「添加文件」或「添加文件夹」，也可把文件直接拖进传输；可随时增删分享内容，手机已打开的网页会自动更新。
4. 用手机扫描**传输详情里自己电脑当前显示的二维码**，在浏览器打开。**不要扫描本指南截图中的演示码。**

![电脑端新建命名传输、添加文件及二维码入口](<docs/images/04-share.webp>)

## 4. 手机与电脑双向传文件

扫描二维码后，手机浏览器打开的就是**这个传输**：

- **电脑 → 手机：** 点单个文件下载，或勾选多项打包为 ZIP；支持的图片、音频、视频可预览。
- **手机 → 电脑：** 在同一网页的「上传到电脑」区域选文件并上传，**无需电脑端确认**。每个文件最大 **1 GiB**；传完后电脑详情里的「来自手机的文件」会显示这次传输收到的文件和位置。
- **断网后继续上传：** 回到网页点「继续上传」；如果刷新或重开网页，重新选择同一原文件即可恢复。手机系统可能挂起后台网页，因此请保持在前台，不能保证自动后台上传。

![手机浏览器中从电脑下载或 ZIP，以及无需电脑端确认直接上传回电脑](<docs/images/05-phone.webp>)

## 5. 查看本传输收到的文件

打开某个传输，在详情下方的「**来自手机的文件**」中查看文件名、保存位置、大小与接收时间。记录持久保存，可复制路径、打开接收文件夹，或在 **Finder / 文件资源管理器**中定位。该列表只属于当前传输，其他传输的接收文件不会混在一起。

默认按传输保存到「下载 / LanDrop / 传输 ID」；下载目录不可用时可能回退到文档目录。每个传输可单独设置接收位置、按日期整理；只影响新收到的文件，不搬动已有文件，同名文件不会覆盖。LanDrop 不会自动打开收到的文件。

![传输详情中该传输自己的接收文件、保存目录与文件定位入口](<docs/images/06-received.webp>)

## 6. 外观与后台设置

在「**应用设置**」可选择「跟随系统」「浅色」或「深色」，选择会保存；跟随系统时，系统切换外观，App 也自动切换。关闭主窗口默认只是隐藏到 **Mac 菜单栏 / Windows 系统托盘**，传输服务仍在运行；「应用设置」可关闭后台模式。

真正退出应用会停止服务，电脑睡眠或断网也会中断。传输期间请让电脑保持唤醒；重启应用后端口可能变化，应重新扫描二维码。

![应用设置中的浅色、深色、跟随系统及后台模式](<docs/images/07-settings.webp>)

## 常见问题

**扫码后打不开网页？**

先确认在同一网络、电脑上的页面已启动，重新扫描当前二维码，并检查防火墙是否允许 LanDrop。访客 Wi-Fi 的「客户端隔离」可能阻止设备互访，可换到可信的普通家庭网络；不要为了连通而关闭整个防火墙。

**手机文件下载到哪里了？**

先看浏览器的下载列表，再到手机「文件」或文件管理器中找下载目录；系统和浏览器的保存位置可能不同，下载后也不一定自动出现在相册。

**ZIP 下载中断了，能继续吗？**

ZIP **不支持断点续传**，中断后需要重新下载，电脑还需留有临时磁盘空间。大文件建议单独下载；单文件能否恢复下载取决于浏览器或下载器，重启后旧链接不保证有效。

**取消上传或删除传输，会删掉文件吗？**

取消上传或删除传输会清理对应未完成的上传数据，已接收完成的文件和电脑原始文件不会删除。

**可以跨网、发到公网，或者设置密码吗？**

目前只面向**可信局域网**，使用明文 **HTTP，无密码、无 TLS 加密**。能访问页面的设备都可能下载或上传；请勿把端口暴露到公网，也不要直接运行来源不明的文件。

## 开发与项目资料

<details>
<summary>开发者展开：源码、构建命令与旧版原型</summary>

当前主工程是 [Flutter 工程](<flutter_app>)，桌面使用 Flutter/Dart，手机网页为不依赖 CDN 的自包含 HTML/CSS/JS。仅交付 macOS / Windows 桌面版；工程中的移动平台脚手架不代表已提供手机 App。

- [架构与协议](<ARCHITECTURE.md>)
- [1.3 验证记录与已知边界](<RELEASE-1.3.md>)
- [1.2 验证记录与已知边界](<RELEASE-1.2.md>)（历史版本）
- [GitHub Actions 构建配置](<.github/workflows/build-desktop.yml>)：推送 `master` 或手动触发，分析、测试并构建两端，再上传备用 Artifacts。
- [GitHub Release 发布配置](<.github/workflows/publish-release.yml>)：推送 `v*` 标签后，重新构建并将 macOS / Windows ZIP 发布到正式 Release；macOS 尚未公证，Windows 包未做代码签名。

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
