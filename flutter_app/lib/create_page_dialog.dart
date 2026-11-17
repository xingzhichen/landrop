import 'package:file_picker/file_picker.dart';
// Match the app's Material API while the replacement package stabilizes.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

typedef PickShareFiles = Future<List<PlatformFile>> Function();

/// Collects a page title and files without starting the transfer itself.
///
/// Use with `showDialog<(String, List<PlatformFile>)>` to receive the selection.
class CreatePageDialog extends StatefulWidget {
  const CreatePageDialog({super.key, required this.pickFiles});

  final PickShareFiles pickFiles;

  static const titleFieldKey = ValueKey('create-page-title');
  static const pickFilesKey = ValueKey('create-page-pick-files');
  static const cancelKey = ValueKey('create-page-cancel');
  static const submitKey = ValueKey('create-page-submit');
  static const progressKey = ValueKey('create-page-progress');
  static const errorKey = ValueKey('create-page-error');

  @override
  State<CreatePageDialog> createState() => _CreatePageDialogState();
}

class _CreatePageDialogState extends State<CreatePageDialog> {
  final TextEditingController _input = TextEditingController();
  List<PlatformFile> _selections = [];
  bool _picking = false;
  String? _error;

  @override
  void dispose() {
    // The controller lives as long as the dialog, including its exit animation.
    _input.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    // Also guard callbacks invoked twice before the next frame rebuilds buttons.
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final files = await widget.pickFiles();
      if (!mounted) return;
      // An empty result means the native picker was cancelled, not "clear".
      if (files.isNotEmpty) {
        setState(() => _selections = List<PlatformFile>.of(files));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error =
            error is PlatformException && error.code == 'ENTITLEMENT_NOT_FOUND'
                ? '选择文件失败：缺少文件访问权限（ENTITLEMENT_NOT_FOUND），请检查应用权限后重试。'
                : '选择文件失败：$error。请重试。';
      });
    } finally {
      // The barrier/back button can dismiss the dialog while the picker is open.
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    if (_picking || _input.text.trim().isEmpty || _selections.isEmpty) return;
    Navigator.pop<(String, List<PlatformFile>)>(
      context,
      (_input.text.trim(), List<PlatformFile>.of(_selections)),
    );
  }

  void _cancel() {
    if (!_picking) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 26, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 22),
      title: const Text('新建传输页面'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '为这组文件命名，创建后即可通过链接或二维码传输。',
                style:
                    TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.7),
              ),
              const SizedBox(height: 22),
              TextField(
                key: CreatePageDialog.titleFieldKey,
                controller: _input,
                autofocus: true,
                maxLength: 80,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '页面名称',
                  hintText: '例如：旅行照片',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  border: Border.all(color: AppTheme.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      key: CreatePageDialog.pickFilesKey,
                      onPressed: _picking ? null : _pickFiles,
                      icon: const Icon(Icons.folder_open_outlined, size: 19),
                      label: const Text('选择文件（可多选）'),
                    ),
                    const SizedBox(height: 8),
                    const Text('可一次选择多个文件，原文件保留在本机。',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.muted, height: 1.6)),
                  ],
                ),
              ),
              if (_picking) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(
                  key: CreatePageDialog.progressKey,
                  semanticsLabel: '正在选择文件',
                ),
                const Text('正在选择文件…'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    key: CreatePageDialog.errorKey,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '已选择 ${_selections.length} 个文件',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_selections.isNotEmpty)
                SizedBox(
                  height: 110,
                  child: ListView.builder(
                    primary: false,
                    itemCount: _selections.length,
                    itemBuilder: (_, index) => Text(
                      _selections[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: CreatePageDialog.cancelKey,
          onPressed: _picking ? null : _cancel,
          child: const Text('取消'),
        ),
        FilledButton(
          key: CreatePageDialog.submitKey,
          onPressed:
              _picking || _input.text.trim().isEmpty || _selections.isEmpty
                  ? null
                  : _submit,
          child: const Text('创建并启动'),
        ),
      ],
    );
  }
}
