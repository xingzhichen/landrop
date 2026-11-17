# LanDrop 技术架构

## 跨端边界

主产品位于 `flutter_app`。Flutter 提供 macOS、Windows、Android、iOS 的公共 UI；Dart `dart:io` 提供真正运行在设备上的 HTTP 服务，不依赖云服务器或内嵌 WebView。平台工程提供应用入口、图标、本地网络权限和插件注册。

- **界面层**：`lib/main.dart`。创建页面、原生文件选择、分享地址/二维码、生命周期操作、手机上传的接收记录。
- **状态与服务层**：`lib/landrop_controller.dart`。页面 JSON 持久化、独立 HttpServer、文件流读写、HTTP Range、上传落盘、移动端文件副本管理。
- **网页呈现层**：`lib/download_page.dart`。无外部资源的移动端 HTML/CSS/JS，下载列表、主题切换、入场动画、上传进度和错误反馈。
- **平台适配**：file_picker 调原生选择器，path_provider 获取各平台可写目录，shared_preferences 持久化页面，qr_flutter 在本地生成二维码。

## 双向传输

每个运行中的页面占用独立 TCP 端口，监听 IPv4 局域网网卡。网页 `GET /`，电脑共享文件 `GET/HEAD /file/<UUID>`，手机发送文件 `POST /upload?name=<encoded-name>`，请求体为原始二进制流。这样无需在内存中拼装大文件或 multipart 数据。

上传成功表示服务器已完成文件写入；网页的上传进度表示发送进度，不代表电脑已保存。只有收到成功响应后才显示保存成功。传输需要电脑与手机网络互通，移动平台作为服务端时须保持前台运行。

## 文件与权限

电脑端分享通常引用原路径；Android SAF 等只有内容 URI 的情况，以及移动平台选择的文件，先流式复制到私有持久目录。上传的文件放在独立接收目录，不替换本地原文件。移除分享页面不删除用户原文件和接收的文件，只清理应用管理的分享副本。

文件下载按当前页面 UUID 白名单查找，不根据网页传来的任意路径读文件。上传文件名清洗、唯一命名与固定目录限制用于防止路径穿越和覆盖；限制单文件 1 GiB。网页对动态文本转义，拒绝跨站上传来源，不开放 CORS。

当前产品适用于可信局域网，未提供 TLS、账号认证、上传配额或杀毒扫描。不要将服务端口映射到公网，不要运行不可信上传文件。macOS 采用站外分发模式（App Sandbox 关闭）；面向 App Store 需要另行实现 sandbox 安全书签与签名配置。

## 构建与分发

`master` 推送触发 GitHub Actions，在 macOS/Windows runner 构建 release 并上传压缩包。Windows 包必须连同 DLL 和 data 目录整体解压；不能只复制 EXE。macOS 包经过本机临时签名以保证完整性，但没有 Developer ID 公证。正式发布需管理 Apple/Windows 证书与密钥；iOS 真机包还需 provisioning profile。

根目录 Swift 原型仅作历史参考，不是跨端主产品。后续功能统一在 Flutter 版迭代。
