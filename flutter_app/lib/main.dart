// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'landrop_controller.dart';
import 'create_page_dialog.dart';
import 'app_theme.dart';
import 'desktop_file_manager.dart';
import 'desktop_shell.dart';
import 'workspace_dialogs.dart';
import 'workspace_motion.dart';
import 'transfer_panel.dart';

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
      theme: AppTheme.light,
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      this.controller,
      this.pickFiles,
      this.fileManager,
      this.shell,
      this.pickDirectory});

  /// Optional state/picker injection for native widget previews and tests.
  /// An injected controller remains owned by its caller and is not disposed here.
  final LanDropController? controller;
  final PickShareFiles? pickFiles;
  final DesktopFileManager? fileManager;
  final DesktopShell? shell;
  final PickDirectory? pickDirectory;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final LanDropController _controller =
      widget.controller ?? LanDropController();
  PickShareFiles get _pickFiles => widget.pickFiles ?? FilePicker.pickFiles;
  DesktopFileManager get _fileManager =>
      widget.fileManager ?? const DesktopFileManager();
  late final DesktopShell _shell = widget.shell ??
      (widget.controller == null
          ? const DesktopShell()
          : const DesktopShell.disabled());
  PickDirectory get _pickDirectory =>
      widget.pickDirectory ?? () => FilePicker.getDirectoryPath();
  bool _dragging = false;
  bool _handlingDrop = false;
  bool _backgroundMode = true;
  static const _titles = ['传输页面', '接收记录', '传输动态', '应用设置'];
  static const _descriptions = [
    '把文件交给同一网络中的设备。',
    '来自手机的文件，已保存到这台设备。',
    '查看本机收发进度，暂停任务可从网页继续。',
    '管理后台运行与各页面的接收位置。'
  ];
  int _destination = 0;
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
    if (!mounted) return;
    setState(() => _loading = false);
    try {
      await _shell.initialize(
          onDrop: (paths) => unawaited(_importPaths(paths)),
          onShow: () {},
          onDragChanged: (value) {
            if (mounted) setState(() => _dragging = value);
          });
      if (_shell.isSupported) {
        final preferences = await SharedPreferences.getInstance();
        _backgroundMode = preferences.getBool('landrop.background.v1') ?? true;
        await _shell.setBackgroundMode(_backgroundMode);
        if (mounted) setState(() {});
      }
    } catch (error) {
      if (mounted) _notice('桌面后台服务未能启动：$error');
    }
  }

  @override
  void dispose() {
    _shell.dispose();
    if (widget.controller == null) _controller.dispose();
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
      builder: (_) => CreatePageDialog(pickFiles: _pickFiles),
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
      final result = await _pickFiles();
      if (result.isEmpty) return;
      await _controller.addFiles(page, result);
    });
  }

  Future<void> _addFolder([SharePage? page]) async {
    String? directory;
    await _perform(() async {
      directory = await _pickDirectory();
    });
    if (directory == null || !mounted) return;
    if (page == null) {
      await _importPaths([directory!]);
      return;
    }
    await _perform(() async {
      final before = page.files.length;
      await _controller.addPaths(page, [directory!]);
      if (mounted) _notice('已添加 ${page.files.length - before} 个文件');
    });
  }

  Future<void> _importPaths(List<String> paths) async {
    if (!mounted || paths.isEmpty) return;
    if (_working || _loading || _handlingDrop) {
      _notice('请等待当前操作完成后再拖入文件。');
      return;
    }
    _handlingDrop = true;
    if (_dragging) setState(() => _dragging = false);
    try {
      final choice = await showDialog<DropChoice>(
          context: context,
          builder: (_) => ImportPathsDialog(
              paths: paths, pages: List.of(_controller.pages)));
      if (choice == null || !mounted) return;
      await _perform(() async {
        final isNew = choice.page == null;
        final page = choice.page ?? await _controller.createPage(choice.title);
        final before = page.files.length;
        try {
          await _controller.addPaths(page, paths);
          final added = page.files.length - before;
          if (isNew && added == 0) {
            await _controller.removePage(page);
            throw StateError('没有可分享的普通文件（空目录与符号链接不会加入）。');
          }
          if (isNew) await _controller.start(page);
          if (mounted) {
            setState(() => _destination = 0);
            _notice('已添加 $added 个文件，文件夹结构已保留');
          }
        } catch (_) {
          if (isNew && _controller.pages.contains(page)) {
            await _controller.removePage(page);
          }
          rethrow;
        }
      });
    } finally {
      _handlingDrop = false;
    }
  }

  Future<void> _receiveSettings(SharePage page) async {
    final options = await showDialog<ReceiveOptions>(
        context: context,
        builder: (_) =>
            ReceiveOptionsDialog(page: page, pickDirectory: _pickDirectory));
    if (options == null || !mounted) return;
    await _perform(() async {
      await _controller.setReceiveOptions(page,
          directory: options.directory, organizeByDate: options.organizeByDate);
      if (mounted) _notice('接收目录设置已保存，之后新建的上传任务将使用新位置');
    });
  }

  Future<void> _setBackgroundMode(bool value) => _perform(() async {
        await _shell.setBackgroundMode(value);
        final preferences = await SharedPreferences.getInstance();
        await preferences.setBool('landrop.background.v1', value);
        if (mounted) setState(() => _backgroundMode = value);
      });

  Future<void> _quit() async {
    if (!await _confirm('退出 LanDrop？', '退出会停止所有传输页面及正在传输的任务。已接收文件保留。',
        confirmText: '退出')) {
      return;
    }
    await _perform(_shell.quit);
  }

  Future<bool> _confirm(String title, String detail,
      {String confirmText = '删除'}) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              ActionMotion(
                  child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              )),
              ActionMotion(
                  child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              )),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deletePage(SharePage page) async {
    if (!await _confirm(
        '删除「${page.title}」？', '此页面会停止服务并清除未完成的上传；已接收文件和电脑上的原文件不会删除。')) {
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
        return Stack(children: [
          Scaffold(
            body: SafeArea(
              child: LayoutBuilder(builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 900;
                final workspace = _workspace(available, address, desktop);
                if (!desktop) {
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _topNavigation(),
                        Expanded(child: workspace),
                      ]);
                }
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sidebar(),
                      Expanded(child: workspace),
                    ]);
              }),
            ),
          ),
          Positioned.fill(
              child: IgnorePointer(
                  child: AnimatedOpacity(
                      opacity: _dragging ? 1 : 0,
                      duration: motionDuration(context),
                      child: Container(
                          color: AppTheme.primary.withValues(alpha: .12),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(30),
                          child: const Card(
                              child: Padding(
                                  padding: EdgeInsets.all(32),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.drive_folder_upload_outlined,
                                            color: AppTheme.primary, size: 48),
                                        SizedBox(height: 16),
                                        Text('松开以分享文件或文件夹',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w700)),
                                        SizedBox(height: 8),
                                        Text('下一步选择新建页面或添加到已有页面。',
                                            textAlign: TextAlign.center)
                                      ]))))))),
        ]);
      },
    );
  }

  Widget _brand() => const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.swap_vert_rounded, color: AppTheme.primary, size: 29),
        SizedBox(width: 9),
        Flexible(
            child: Text('LanDrop',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8))),
      ]);

  Widget _navItem(int index, IconData icon, String label) {
    final selected = _destination == index;
    return AnimatedContainer(
        duration: motionDuration(context),
        decoration: BoxDecoration(
            color: selected ? AppTheme.primaryTint : Colors.transparent,
            borderRadius: BorderRadius.circular(12)),
        child: Material(
          color: selected ? AppTheme.primaryTint : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _destination = index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 20,
                    color: selected ? AppTheme.primary : AppTheme.muted),
                const SizedBox(width: 10),
                Text(label,
                    style: TextStyle(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? AppTheme.primary : AppTheme.muted)),
              ]),
            ),
          ),
        ));
  }

  Widget _sidebar() => Container(
        width: 200,
        decoration: const BoxDecoration(
            color: AppTheme.surface,
            border: Border(right: BorderSide(color: AppTheme.border))),
        padding: const EdgeInsets.fromLTRB(18, 31, 18, 24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.only(left: 7), child: _brand()),
          const SizedBox(height: 9),
          const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Text('局域网文件传输',
                  style: TextStyle(fontSize: 12, color: AppTheme.muted))),
          const SizedBox(height: 40),
          _navItem(0, Icons.folder_outlined, '传输页面'),
          const SizedBox(height: 7),
          _navItem(1, Icons.move_to_inbox_outlined, '接收记录'),
          const SizedBox(height: 7),
          _navItem(2, Icons.sync_alt_rounded, '传输动态'),
          const SizedBox(height: 7),
          _navItem(3, Icons.tune_outlined, '应用设置'),
          const Spacer(),
          const Divider(),
          const SizedBox(height: 18),
          const Row(children: [
            Icon(Icons.devices_outlined, size: 17, color: AppTheme.muted),
            SizedBox(width: 8),
            Text('设备间，直接传输',
                style: TextStyle(fontSize: 12, color: AppTheme.muted)),
          ]),
        ]),
      );

  Widget _topNavigation() => Material(
        color: AppTheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _brand(),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _navItem(0, Icons.folder_outlined, '传输页面'),
              _navItem(1, Icons.move_to_inbox_outlined, '接收记录'),
              _navItem(2, Icons.sync_alt_rounded, '传输动态'),
              _navItem(3, Icons.tune_outlined, '应用设置'),
            ]),
          ]),
        ),
      );

  Widget _workspace(List<String> available, String? address, bool desktop) {
    if (_loading) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('正在准备传输工作台…'),
      ]));
    }
    if (_startupError != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child:
                  SelectableText(_startupError!, textAlign: TextAlign.center)));
    }
    final running = _controller.pages
        .where((page) => _controller.portFor(page) != null)
        .length;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          desktop ? 32 : 16, desktop ? 27 : 20, desktop ? 32 : 16, 40),
      children: [
        Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  Text('工作台  /  ${_titles[_destination]}',
                      style:
                          const TextStyle(fontSize: 12, color: AppTheme.muted)),
                  _status(address == null ? '未连接局域网' : '局域网可用',
                      active: address != null),
                ]),
            const SizedBox(height: 29),
            LayoutBuilder(builder: (context, constraints) {
              final heading = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_titles[_destination],
                        style: TextStyle(
                            fontSize: desktop ? 32 : 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.7)),
                    const SizedBox(height: 7),
                    Text(_descriptions[_destination],
                        style: const TextStyle(
                            color: AppTheme.muted, height: 1.6)),
                  ]);
              final button = Wrap(spacing: 8, runSpacing: 8, children: [
                ActionMotion(
                    child: OutlinedButton.icon(
                        onPressed: _working ? null : () => _addFolder(),
                        icon: const Icon(Icons.create_new_folder_outlined,
                            size: 19),
                        label: const Text('分享文件夹'))),
                ActionMotion(
                    child: FilledButton.icon(
                        onPressed: _working ? null : _newPage,
                        icon: const Icon(Icons.add, size: 19),
                        label: const Text('新建页面')))
              ]);
              if (constraints.maxWidth < 720) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heading,
                      const SizedBox(height: 16),
                      if (_destination == 0) button
                    ]);
              }
              return Row(children: [
                Expanded(child: heading),
                if (_destination == 0) button
              ]);
            }),
            const SizedBox(height: 25),
            if (_working)
              const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(semanticsLabel: '正在处理操作')),
            AnimatedSwitcher(
                duration: motionDuration(context, 180),
                switchInCurve: Curves.easeOutCubic,
                child: KeyedSubtree(
                    key: ValueKey(_destination),
                    child: _destination == 0
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 14),
                                    decoration: BoxDecoration(
                                        border:
                                            Border.all(color: AppTheme.border),
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: const Row(children: [
                                      Icon(Icons.drive_folder_upload_outlined,
                                          size: 22, color: AppTheme.primary),
                                      SizedBox(width: 12),
                                      Expanded(
                                          child: Text(
                                              '可将文件或文件夹拖入窗口；关闭窗口后仍可在菜单栏／系统托盘中管理。',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: AppTheme.muted,
                                                  height: 1.6)))
                                    ])),
                                const SizedBox(height: 16),
                                _networkCard(available, address),
                                const SizedBox(height: 27),
                                Wrap(
                                    spacing: 12,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Text('我的页面',
                                          style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                          '${_controller.pages.length} 个页面 · $running 个运行中',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.muted)),
                                    ]),
                                const SizedBox(height: 14),
                                if (_controller.pages.isEmpty) _emptyCard(),
                                for (final page in _controller.pages) ...[
                                  WorkspaceEntry(
                                      key: ValueKey(page.id),
                                      child: AnimatedSize(
                                          duration:
                                              motionDuration(context, 220),
                                          alignment: Alignment.topCenter,
                                          child: _pageCard(page, address))),
                                  const SizedBox(height: 18)
                                ],
                              ])
                        : _destination == 1
                            ? _receivedCard()
                            : _destination == 2
                                ? TransferPanel(
                                    tasks: _controller.transfers,
                                    onCancel: (task) => unawaited(_perform(() =>
                                        _controller.cancelTransfer(task.id))))
                                : _settingsCard())),
          ]),
        )),
      ],
    );
  }

  Widget _status(String label, {required bool active}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: active ? AppTheme.primaryTint : AppTheme.background,
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle,
              size: 6, color: active ? AppTheme.primary : AppTheme.muted),
          const SizedBox(width: 7),
          Text(label,
              style: TextStyle(
                  color: active ? AppTheme.primary : AppTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _networkCard(List<String> available, String? address) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(builder: (context, constraints) {
            final information =
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.wifi_rounded, size: 20, color: AppTheme.primary),
                SizedBox(width: 9),
                Expanded(
                    child: Text('同一局域网内，扫码即可下载',
                        style: TextStyle(fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 7),
              const Text('每个页面独立运行，手机无需安装应用。',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.muted, height: 1.6)),
              if (available.isEmpty)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('未找到本机 IPv4 地址。请连接 Wi-Fi / 局域网后刷新。',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted))),
              if (_controller.isMobile)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('移动设备请保持应用在前台；后台运行可能受 iOS / Android 系统限制。',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted))),
            ]);
            final selector = Row(children: [
              Expanded(
                  child: available.isEmpty
                      ? const Text('等待网络连接',
                          style: TextStyle(color: AppTheme.muted, fontSize: 13))
                      : DropdownButtonFormField<String>(
                          key: ValueKey(address),
                          initialValue: address,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: '本机 IP 地址',
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10)),
                          style: const TextStyle(
                              color: AppTheme.ink,
                              fontSize: 13,
                              fontFamily: 'monospace'),
                          items: available
                              .map((ip) => DropdownMenuItem(
                                  value: ip,
                                  child: Text(ip,
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: _working
                              ? null
                              : (ip) => setState(() => _selectedAddress = ip),
                        )),
              const SizedBox(width: 4),
              ActionMotion(
                  child: IconButton(
                      tooltip: '刷新局域网地址',
                      onPressed: _working ? null : _refreshAddresses,
                      icon: const Icon(Icons.refresh, size: 20))),
            ]);
            if (constraints.maxWidth < 600) {
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    information,
                    const SizedBox(height: 18),
                    selector
                  ]);
            }
            return Row(children: [
              Expanded(child: information),
              const SizedBox(width: 20),
              SizedBox(width: 245, child: selector)
            ]);
          }),
        ),
      );

  Future<void> _copy(String value, String notice) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _notice(notice);
  }

  String _receivedDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

  Widget _settingsCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('后台运行',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('关闭窗口后继续传输'),
                          subtitle:
                              const Text('窗口会隐藏；从菜单栏／系统托盘可重新打开或退出。退出应用才会停止服务。'),
                          value: _backgroundMode,
                          onChanged: _working ? null : _setBackgroundMode),
                      const Divider(),
                      const SizedBox(height: 12),
                      const Text('界面动效跟随系统的“减少动态效果”设置。动效只提供操作反馈，不会延迟传输。',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.muted,
                              height: 1.6)),
                      const SizedBox(height: 12),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: ActionMotion(
                              child: TextButton.icon(
                                  onPressed: _working ? null : _quit,
                                  icon: const Icon(
                                      Icons.power_settings_new_outlined),
                                  label: const Text('退出 LanDrop')))),
                    ]))),
        const SizedBox(height: 16),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('各页面的接收位置',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('可设置独立保存位置及按日期整理；历史文件不会随设置搬动。',
                          style: TextStyle(color: AppTheme.muted, height: 1.6)),
                      const SizedBox(height: 16),
                      if (_controller.pages.isEmpty)
                        const Text('新建传输页面后，即可为它配置接收位置。',
                            style: TextStyle(color: AppTheme.muted)),
                      for (final page in _controller.pages)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Text(page.title,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 5),
                                        Text(
                                            '${page.receiveDirectory ?? '默认下载目录'}${page.organizeByDate ? ' · 按日期整理' : ''}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: AppTheme.muted),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis)
                                      ])),
                                  const SizedBox(width: 12),
                                  ActionMotion(
                                      child: OutlinedButton(
                                          onPressed: _working
                                              ? null
                                              : () => _receiveSettings(page),
                                          child: const Text('设置')))
                                ])),
                    ]))),
      ]);

  Widget _receivedCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                runSpacing: 8,
                children: [
                  const Text('来自手机的文件',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  Text('${_controller.receivedFiles.length} 个文件 · 历史记录',
                      style:
                          const TextStyle(fontSize: 12, color: AppTheme.muted)),
                ]),
            const SizedBox(height: 8),
            const Text('手机在分享网页中上传后，文件将自动保存到此设备，无需再次下载。',
                style: TextStyle(color: AppTheme.muted, height: 1.6)),
            if (_controller.receiveDirectory != null) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border)),
                child: Row(children: [
                  Expanded(
                      child: SelectableText(
                          '接收目录：${_controller.receiveDirectory}',
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.muted,
                              fontFamily: 'monospace',
                              height: 1.6))),
                  ActionMotion(
                      child: IconButton(
                          tooltip: '复制接收目录',
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          onPressed: () =>
                              _copy(_controller.receiveDirectory!, '接收目录已复制'))),
                ]),
              ),
              const SizedBox(height: 12),
              Wrap(children: [
                ActionMotion(
                    child: OutlinedButton.icon(
                  key: const ValueKey('open-receive-directory'),
                  onPressed: _working
                      ? null
                      : () => _perform(() => _fileManager
                          .openDirectory(_controller.receiveDirectory!)),
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('打开接收文件夹'),
                )),
              ]),
            ],
            const SizedBox(height: 20),
            const Divider(),
            if (_controller.receivedFiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 46),
                child: Column(children: [
                  Icon(Icons.move_to_inbox_outlined,
                      size: 42, color: AppTheme.muted),
                  SizedBox(height: 16),
                  Text('还没有接收文件',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  SizedBox(height: 8),
                  Text('请保持对应传输页面运行，手机上传后会在这里留下记录。',
                      style: TextStyle(color: AppTheme.muted, height: 1.6),
                      textAlign: TextAlign.center),
                ]),
              ),
            for (final file in _controller.receivedFiles) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FileTypeIcon(name: file.name),
                      const SizedBox(width: 13),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(file.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 5),
                            Text(
                                '${_sizeLabel(file.size)} · ${file.pageTitle} · ${_receivedDate(file.receivedAt)}',
                                style: const TextStyle(
                                    color: AppTheme.muted, fontSize: 12)),
                            const SizedBox(height: 5),
                            SelectableText(file.path,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: AppTheme.muted,
                                    height: 1.6)),
                            const SizedBox(height: 12),
                            Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ActionMotion(
                                      child: OutlinedButton.icon(
                                    key: ValueKey(
                                        'reveal-received-${file.path}'),
                                    onPressed: _working
                                        ? null
                                        : () => _perform(() =>
                                            _fileManager.revealFile(file.path)),
                                    icon: const Icon(
                                        Icons.drive_file_move_outlined,
                                        size: 18),
                                    label: const Text('在文件夹中显示'),
                                  )),
                                  ActionMotion(
                                      child: IconButton(
                                    tooltip: '复制保存路径',
                                    icon: const Icon(Icons.copy_outlined,
                                        size: 18),
                                    onPressed: () =>
                                        _copy(file.path, '文件路径已复制'),
                                  )),
                                ]),
                          ])),
                    ]),
              ),
              const Divider(),
            ],
          ]),
        ),
      );

  Widget _emptyCard() => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 52),
          child: Column(children: [
            Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                    color: AppTheme.primaryTint,
                    borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.folder_copy_outlined,
                    size: 30, color: AppTheme.primary)),
            const SizedBox(height: 20),
            const Text('还没有下载页',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('新建页面、添加多个文件，然后启动分享。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.muted, height: 1.6)),
            const SizedBox(height: 8),
            const Text('文件保留在本机，停止页面即可结束分享。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.muted, fontSize: 12, height: 1.6)),
          ]),
        ),
      );

  Widget _pageCard(SharePage page, String? address) {
    final port = _controller.portFor(page);
    final link =
        port != null && address != null ? 'http://$address:$port/' : null;
    final error = _controller.pageErrors[page.id];
    final total = page.files.fold<int>(0, (sum, file) => sum + file.size);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(page.title,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 9),
                  Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _status(port == null ? '已停止' : '运行中 · 端口 $port',
                            active: port != null),
                        Text('${page.files.length} 个文件 · ${_sizeLabel(total)}',
                            style: const TextStyle(
                                color: AppTheme.muted, fontSize: 12)),
                      ]),
                ])),
            ActionMotion(
                child: IconButton(
                    tooltip: '删除页面',
                    onPressed: _working ? null : () => _deletePage(page),
                    icon: const Icon(Icons.delete_outline, size: 20))),
          ]),
          if (error != null)
            Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Semantics(
                    liveRegion: true,
                    child: Text(error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)))),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            final files = _fileList(page);
            final share = _sharePanel(link, port);
            if (constraints.maxWidth < 620) {
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [files, const SizedBox(height: 22), share]);
            }
            return IntrinsicHeight(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Expanded(child: files),
                  const SizedBox(width: 22),
                  const VerticalDivider(width: 1),
                  const SizedBox(width: 22),
                  SizedBox(width: 215, child: share),
                ]));
          }),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionMotion(
                child: OutlinedButton.icon(
                    onPressed: _working ? null : () => _addFiles(page),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加文件'))),
            ActionMotion(
                child: OutlinedButton.icon(
                    onPressed: _working ? null : () => _addFolder(page),
                    icon:
                        const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: const Text('添加文件夹'))),
            ActionMotion(
                child: TextButton.icon(
                    onPressed: _working ? null : () => _receiveSettings(page),
                    icon: const Icon(Icons.folder_special_outlined, size: 18),
                    label: const Text('接收设置'))),
            if (port == null)
              ActionMotion(
                  child: OutlinedButton.icon(
                      onPressed: _working
                          ? null
                          : () => _perform(() => _controller.start(page)),
                      icon: const Icon(Icons.play_arrow_outlined, size: 18),
                      label: const Text('启动')))
            else ...[
              ActionMotion(
                  child: TextButton.icon(
                      onPressed: _working
                          ? null
                          : () => _perform(() => _controller.stop(page)),
                      icon: const Icon(Icons.stop_rounded, size: 17),
                      label: const Text('停止'))),
              ActionMotion(
                  child: TextButton.icon(
                      onPressed: _working
                          ? null
                          : () => _perform(() => _controller.restart(page)),
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('重启'))),
            ],
          ]),
        ]),
      ),
    );
  }

  Widget _fileList(SharePage page) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('文件 (${page.files.length})',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 12),
        if (page.files.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Text('尚未添加文件', style: TextStyle(color: AppTheme.muted))),
        for (final file in page.files)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              FileTypeIcon(name: file.name),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Tooltip(
                        message: file.name,
                        child: Text(file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500))),
                    const SizedBox(height: 5),
                    if (file.relativePath != null &&
                        file.relativePath != file.name)
                      Text(file.relativePath!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.muted)),
                    Text(_sizeLabel(file.size),
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.muted)),
                  ])),
              ActionMotion(
                  child: IconButton(
                      tooltip: '移除文件',
                      onPressed:
                          _working ? null : () => _deleteFile(page, file),
                      icon: const Icon(Icons.close, size: 17))),
            ]),
          ),
      ]);

  Widget _sharePanel(String? link, int? port) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('扫码传输',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 12),
        if (link != null) ...[
          Center(
              child: Container(
            width: 176,
            height: 176,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border)),
            child: QrImageView(
                data: link,
                version: QrVersions.auto,
                size: 158,
                semanticsLabel: '扫描二维码打开传输页面'),
          )),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border)),
            padding: const EdgeInsets.only(left: 10),
            child: Row(children: [
              Expanded(
                  child: SelectableText(link,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: AppTheme.muted,
                          height: 1.6))),
              ActionMotion(
                  child: IconButton(
                      tooltip: '复制链接',
                      onPressed: () => _copy(link, '链接已复制'),
                      icon: const Icon(Icons.copy_outlined, size: 17))),
            ]),
          ),
        ] else
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              const Icon(Icons.qr_code_2_rounded,
                  size: 50, color: AppTheme.muted),
              const SizedBox(height: 12),
              Text(
                  port == null
                      ? '启动页面后显示二维码和下载链接。'
                      : '服务已启动；连接局域网后刷新地址以显示链接和二维码。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.muted, fontSize: 12, height: 1.7)),
            ]),
          ),
      ]);

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
