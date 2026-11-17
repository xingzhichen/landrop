// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'landrop_controller.dart';
import 'create_page_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanDropApp());
}

class LanDropApp extends StatelessWidget {
  const LanDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3366E8)),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final LanDropController _controller = LanDropController();
  bool _loading = true;
  bool _working = false;
  String? _selectedAddress;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
    } catch (error) {
      _startupError = '初始化失败：$error';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() work) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await work();
    } catch (error) {
      if (mounted) _notice('操作失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newPage() async {
    final created = await showDialog<(String, List<PlatformFile>)>(
      context: context,
      builder: (_) => CreatePageDialog(pickFiles: FilePicker.pickFiles),
    );
    if (created == null || !mounted) return;
    await _perform(() async {
      final page = await _controller.createPage(created.$1);
      try {
        await _controller.addFiles(page, created.$2);
        await _controller.start(page);
      } catch (_) {
        await _controller.removePage(page);
        rethrow;
      }
    });
  }

  Future<void> _addFiles(SharePage page) async {
    await _perform(() async {
      final result = await FilePicker.pickFiles();
      if (result.isEmpty) return;
      await _controller.addFiles(page, result);
    });
  }

  Future<bool> _confirm(String title, String detail) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deletePage(SharePage page) async {
    if (!await _confirm(
        '删除「${page.title}」？', '此页面会停止服务并删除页面记录；移动端保存的副本也会删除。')) {
      return;
    }
    await _perform(() => _controller.removePage(page));
  }

  Future<void> _deleteFile(SharePage page, SharedFile file) async {
    if (!await _confirm(
      '移除「${file.name}」？',
      _controller.isMobile ? '移动端保存的此文件副本也会被删除。' : '仅移除分享，不删除电脑上的原文件。',
    )) {
      return;
    }
    await _perform(() => _controller.removeFile(page, file));
  }

  Future<void> _refreshAddresses() async {
    await _perform(() => _controller.refreshAddresses());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final available = _controller.addresses;
        final address = available.contains(_selectedAddress)
            ? _selectedAddress
            : (available.isEmpty ? null : available.first);
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'LanDrop',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                tooltip: '刷新局域网地址',
                onPressed: _working || _loading ? null : _refreshAddresses,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _startupError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Text(_startupError!, textAlign: TextAlign.center),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 840),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _networkCard(available, address),
                                const SizedBox(height: 16),
                                _receivedCard(),
                                const SizedBox(height: 22),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '下载页',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    FilledButton.icon(
                                      onPressed: _working ? null : _newPage,
                                      icon: const Icon(Icons.add),
                                      label: const Text('新建页面'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (_controller.pages.isEmpty)
                                  _emptyCard()
                                else
                                  for (final page in _controller.pages) ...[
                                    _pageCard(page, address),
                                    const SizedBox(height: 14),
                                  ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _receivedCard() => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.move_to_inbox_outlined),
                SizedBox(width: 10),
                Text('来自手机的文件',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              const Text('手机在分享网页中上传后，文件将自动保存到此设备，无需再次下载。'),
              if (_controller.receiveDirectory != null) ...[
                const SizedBox(height: 8),
                SelectableText('接收目录：${_controller.receiveDirectory}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              if (_controller.receivedFiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('本次运行尚未接收文件。请保持对应传输页面运行。'),
                ),
              for (final file in _controller.receivedFiles.take(20))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download_done_rounded,
                      color: Colors.green),
                  title: Text(file.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: SelectableText(
                      '${_sizeLabel(file.size)} · ${file.pageTitle}\n${file.path}'),
                  trailing: IconButton(
                    tooltip: '复制保存路径',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: file.path));
                      if (mounted) _notice('文件路径已复制');
                    },
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _networkCard(List<String> available, String? address) {
    return Card(
      elevation: 0,
      color: const Color(0xFFE8EEFF),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '同一局域网内，扫码即可下载',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            const Text('每个页面使用独立端口；停止一个页面不会影响其他页面。'),
            const SizedBox(height: 10),
            if (available.isEmpty)
              const Text('未找到本机 IPv4 地址。请连接 Wi-Fi / 局域网后点击右上角刷新。')
            else
              DropdownButton<String>(
                value: address,
                isExpanded: true,
                items: available
                    .map(
                      (ip) => DropdownMenuItem(
                        value: ip,
                        child: Text(ip, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (ip) => setState(() => _selectedAddress = ip),
              ),
            if (_controller.isMobile) ...[
              const SizedBox(height: 6),
              const Text(
                '移动设备请保持应用在前台；后台运行可能受 iOS / Android 系统限制。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(
                Icons.folder_copy_outlined,
                size: 50,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              const Text('还没有下载页',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('新建页面、添加多个文件，然后启动分享。'),
            ],
          ),
        ),
      );

  Widget _pageCard(SharePage page, String? address) {
    final port = _controller.portFor(page);
    final link =
        port != null && address != null ? 'http://$address:$port/' : null;
    final error = _controller.pageErrors[page.id];
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        page.title,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        port == null ? '已停止' : '运行中 · 端口 $port',
                        style: TextStyle(
                          color: port == null
                              ? Colors.grey.shade700
                              : Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除页面',
                  onPressed: _working ? null : () => _deletePage(page),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _working ? null : () => _addFiles(page),
                  icon: const Icon(Icons.add),
                  label: const Text('添加文件'),
                ),
                if (port == null)
                  FilledButton.icon(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _controller.start(page)),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('启动'),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _controller.stop(page)),
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _controller.restart(page)),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重启'),
                  ),
                ],
              ],
            ),
            if (link != null) ...[
              const Divider(height: 30),
              const Text('下载链接', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(child: SelectableText(link)),
                  IconButton(
                    tooltip: '复制链接',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (mounted) _notice('链接已复制');
                    },
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: 176,
                height: 176,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE3E7EF)),
                ),
                child: QrImageView(
                  data: link,
                  version: QrVersions.auto,
                  size: 160,
                ),
              ),
            ] else if (port != null) ...[
              const SizedBox(height: 12),
              const Text('服务已启动；连接局域网后刷新地址以显示链接和二维码。'),
            ],
            const Divider(height: 30),
            Text(
              '文件 (${page.files.length})',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (page.files.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 9),
                child: Text('尚未添加文件'),
              ),
            for (final file in page.files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_sizeLabel(file.size)),
                trailing: IconButton(
                  tooltip: '移除文件',
                  onPressed: _working ? null : () => _deleteFile(page, file),
                  icon: const Icon(Icons.close),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
