# LanDrop

在电脑或手机上选择文件，生成同一局域网内可访问的下载网页和二维码。使用 Flutter/Dart 共用应用 UI、页面状态与 HTTP 服务逻辑，目标平台为 **macOS、Windows、Android、iOS**。手机下载页是离线自包含 HTML/CSS/JS 模板，具备响应式布局、轻量动画、暗色模式及减少动态效果适配。

## 使用方式

1. 新建传输页面，填写名称，选择一个或多个文件。
2. 连接同一个 Wi-Fi 的另一台设备扫码打开下载页，点击文件下载。
3. 多个页面彼此独立，可分别停止、启动、重启和删除。删除页面不会删除原始文件。
4. 移动平台选择的文件会复制到应用私有目录，确保重新打开仍可分享；请注意设备可用空间。电脑端直接读取原文件，移动或删除原文件后对应分享会失效。

**安全提示：** 目前网页以局域网明文 HTTP 分享，没有密码或加密；任何知道链接且能访问局域网的设备均可下载。请仅在可信网络内分享非敏感文件。电脑防火墙可能需要放行应用入站连接；访客 Wi-Fi 的客户端隔离也可能阻断访问。

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

### 自动构建

每次向 `master` 推送，GitHub Actions 的 `Build desktop apps` 工作流在 GitHub 托管的 macOS 和 Windows runner 上分别运行分析、测试、发布构建，并上传 `LanDrop-macOS.zip` / `LanDrop-Windows.zip` 到该次 Actions 运行的 Artifacts。也可手动触发。**这是可下载构建产物，不是已公证、已签名的正式安装包**；面向公众分发需要另行配置签名证书、macOS 公证或 Windows 代码签名。

## 旧版 macOS 原生原型

仓库根目录的 Swift Package (`Sources/LanDrop`) 是最初的 macOS 原型，保留作参考；跨端版本以 `flutter_app` 为主。旧版依然可执行 `./build-app.sh` 构建 `dist/LanDrop.app`，但新功能优先在 Flutter 跨端版实现。
