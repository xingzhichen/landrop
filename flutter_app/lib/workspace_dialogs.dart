// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_theme.dart';
import 'landrop_controller.dart';
import 'workspace_motion.dart';

typedef PickDirectory = Future<String?> Function();

typedef DropChoice = ({String title, SharePage? page});

class ImportPathsDialog extends StatefulWidget {
  const ImportPathsDialog(
      {super.key, required this.paths, required this.pages});
  final List<String> paths;
  final List<SharePage> pages;
  @override
  State<ImportPathsDialog> createState() => _ImportPathsDialogState();
}

class _ImportPathsDialogState extends State<ImportPathsDialog> {
  static const _maxTitleLength = 80;
  late final TextEditingController _title = TextEditingController(
      text: (widget.paths.length == 1 ? p.basename(widget.paths.first) : '拖拽分享')
          .characters
          .take(_maxTitleLength)
          .toString());
  String? _pageId;
  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('分享文件与文件夹'),
        content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Text('${widget.paths.length} 个项目；文件夹将保留内部文件的目录结构。',
                      style: TextStyle(
                          color: AppTheme.colorsOf(context).muted,
                          height: 1.6)),
                  const SizedBox(height: 16),
                  for (final path in widget.paths.take(5))
                    Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(p.basename(path),
                            overflow: TextOverflow.ellipsis)),
                  if (widget.paths.length > 5)
                    Text('另有 ${widget.paths.length - 5} 个项目'),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '添加到'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('新建传输')),
                      for (final page in widget.pages)
                        DropdownMenuItem(
                            value: page.id,
                            child: Text(page.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis))
                    ],
                    onChanged: (value) =>
                        setState(() => _pageId = value == '' ? null : value),
                  ),
                  AnimatedSize(
                      duration: motionDuration(context),
                      alignment: Alignment.topCenter,
                      child: _pageId == null
                          ? Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: TextField(
                                  key: const ValueKey('import-page-title'),
                                  controller: _title,
                                  maxLength: _maxTitleLength,
                                  onChanged: (_) => setState(() {}),
                                  decoration:
                                      const InputDecoration(labelText: '传输名称')))
                          : const SizedBox.shrink()),
                  const SizedBox(height: 12),
                  Text('不会复制或删除电脑上的原文件。符号链接和空文件夹不加入分享。',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.colorsOf(context).muted,
                          height: 1.6)),
                ]))),
        actions: [
          ActionMotion(
              child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'))),
          ActionMotion(
              child: FilledButton(
                  key: const ValueKey('confirm-import-paths'),
                  onPressed: _pageId == null && _title.text.trim().isEmpty
                      ? null
                      : () {
                          final page = _pageId == null
                              ? null
                              : widget.pages
                                  .firstWhere((item) => item.id == _pageId);
                          Navigator.pop<DropChoice>(
                              context, (title: _title.text.trim(), page: page));
                        },
                  child: Text(_pageId == null ? '创建并启动' : '添加到传输')))
        ],
      );
}

typedef ReceiveOptions = ({String? directory, bool organizeByDate});

class ReceiveOptionsDialog extends StatefulWidget {
  const ReceiveOptionsDialog(
      {super.key, required this.page, required this.pickDirectory});
  final SharePage page;
  final PickDirectory pickDirectory;
  @override
  State<ReceiveOptionsDialog> createState() => _ReceiveOptionsDialogState();
}

class _ReceiveOptionsDialogState extends State<ReceiveOptionsDialog> {
  late String? _directory = widget.page.receiveDirectory;
  late bool _dated = widget.page.organizeByDate;
  bool _picking = false;
  String? _error;
  Future<void> _choose() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final path = await widget.pickDirectory();
      if (mounted && path != null) setState(() => _directory = path);
    } catch (_) {
      if (mounted) setState(() => _error = '选择文件夹失败，请检查访问权限后重试。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('接收目录设置'),
        content: SizedBox(
            width: 470,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Text('传输：${widget.page.title}',
                      style:
                          TextStyle(color: AppTheme.colorsOf(context).muted)),
                  const SizedBox(height: 16),
                  const Text('保存位置',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SelectableText(_directory ?? '使用默认下载目录下的 LanDrop 文件夹',
                      style: const TextStyle(fontSize: 13, height: 1.6)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    ActionMotion(
                        child: OutlinedButton.icon(
                            key: const ValueKey('choose-receive-directory'),
                            onPressed: _picking ? null : _choose,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('选择文件夹'))),
                    ActionMotion(
                        child: TextButton(
                            onPressed: _picking
                                ? null
                                : () => setState(() => _directory = null),
                            child: const Text('恢复默认位置')))
                  ]),
                  if (_picking)
                    const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: WorkspaceProgress(
                            linear: true, label: '正在选择接收文件夹')),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Semantics(
                            container: true,
                            liveRegion: true,
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)))),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                      key: const ValueKey('organize-by-date'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('按接收日期整理'),
                      subtitle: const Text('在传输目录内创建 YYYY-MM-DD 子文件夹。'),
                      value: _dated,
                      onChanged: _picking
                          ? null
                          : (value) => setState(() => _dated = value)),
                  const SizedBox(height: 12),
                  Text('每个传输使用独立子文件夹。设置只影响之后新建的上传任务；已有文件不会搬动。',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.colorsOf(context).muted,
                          height: 1.6)),
                ]))),
        actions: [
          ActionMotion(
              child: TextButton(
                  onPressed: _picking ? null : () => Navigator.pop(context),
                  child: const Text('取消'))),
          ActionMotion(
              child: FilledButton(
                  key: const ValueKey('save-receive-options'),
                  onPressed: _picking
                      ? null
                      : () => Navigator.pop<ReceiveOptions>(context,
                          (directory: _directory, organizeByDate: _dated)),
                  child: const Text('保存设置')))
        ],
      );
}
