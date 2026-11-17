# LanDrop

在电脑或手机上选择文件，生成同一局域网内可访问的下载网页和二维码。使用 Flutter/Dart 共用应用 UI、页面状态与 HTTP 服务逻辑，目标平台为 **macOS、Windows、Android、iOS**。手机下载页是离线自包含 HTML/CSS/JS 模板，具备响应式布局、轻量动画、暗色模式及减少动态效果适配。

## 使用方式

1. 新建传输页面，填写名称，选择一个或多个文件。
2. 连接同一个 Wi-Fi 的另一台设备扫码打开下载页，点击文件下载。
3. 多个页面彼此独立，可分别停止、启动、重启和删除。删除页面不会删除原始文件。
4. 手机网页的“上传至电脑”区域支持多文件选择、逐个上传和进度反馈；成功后电脑自动保存到下载目录下的 `LanDrop/<页面 ID>/`（不可用时回退到应用文档目录），应用显示接收记录与保存路径。macOS / Windows 的接收记录支持“打开接收文件夹”，以及针对单个文件的“在文件夹中显示”（打开 Finder / 资源管理器并选中文件），不会直接打开或运行该文件；被移动或删除时会提示。单文件最大 1 GiB；同名文件不会覆盖。停止或删除页面会中断进行中的上传，已接收文件保留，接收列表仅展示本次运行的记录。
5. 移动平台选择的文件会复制到应用私有目录，确保重新打开仍可分享；请注意设备可用空间。电脑端直接读取原文件，移动或删除原文件后对应分享会失效。

**安全提示：** 目前网页以局域网明文 HTTP 分享，没有密码或加密；任何能访问页面的局域网设备均可下载或向接收目录上传文件。不要直接打开、运行不可信来源上传的文件；接收服务仅保存文件，不自动执行。请仅在可信网络内分享非敏感文件。电脑防火墙可能需要放行应用入站连接；访客 Wi-Fi 的客户端隔离也可能阻断访问。

架构、双向传输协议和权限边界详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 构建跨端版

安装 [Flutter stable](https://docs.flutter.dev/get-started/install)，进入 `flutter_app`：

```bash
flutter pub get
flutter run -d macos         # macOS
flutter run -d windows       # Windows（在 Windows 上执行）
flutter run -d android       # Android（需要 Android SDK）
flutter run -d ios           # iOS（在 macOS 上，需 Xcode 与签名）
```

发布构建：`flutter build macos --release`、`flutter build windows --release`、`flutter build apk --release`、`flutter build ios --release`。Android/iOS 真机安装需要各自的签名配置；iOS 的分发通常需要 Apple Developer 账号。首次联网时请允许本地网络权限，部分手机系统可能限制应用退到后台后的文件服务。

macOS 构建后请使用 `bash tool/package_macos.sh` 打包。该脚本显式保留文件选择权限并验证最终签名；不要直接用不带 entitlements 的签名命令替换应用签名，否则原生文件选择器可能拒绝弹出。新建弹窗会显示选择器错误并支持重试。

### 自动构建

每次向 `master` 推送，GitHub Actions 的 `Build desktop apps` 工作流在 GitHub 托管的 macOS 和 Windows runner 上分别运行分析、测试、发布构建，并上传 `LanDrop-macOS.zip` / `LanDrop-Windows.zip` 到该次 Actions 运行的 Artifacts。也可手动触发。**这是可下载构建产物，不是已公证、已签名的正式安装包**；面向公众分发需要另行配置签名证书、macOS 公证或 Windows 代码签名。

## 旧版 macOS 原生原型

仓库根目录的 Swift Package (`Sources/LanDrop`) 是最初的 macOS 原型，保留作参考；跨端版本以 `flutter_app` 为主。旧版依然可执行 `./build-app.sh` 构建 `dist/LanDrop.app`，但新功能优先在 Flutter 跨端版实现。
