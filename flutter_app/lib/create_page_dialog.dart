import 'package:file_picker/file_picker.dart';
// Keep the Material API consistent with the rest of the desktop app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'workspace_motion.dart';

typedef PickShareFiles = Future<List<PlatformFile>> Function();

/// A transfer exists before either device adds files.
class CreatePageDialog extends StatefulWidget {
  const CreatePageDialog({super.key});

  static const titleFieldKey = ValueKey('create-page-title');
  static const cancelKey = ValueKey('create-page-cancel');
  static const submitKey = ValueKey('create-page-submit');

  @override
  State<CreatePageDialog> createState() => _CreatePageDialogState();
}

class _CreatePageDialogState extends State<CreatePageDialog> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _input.text.trim();
    if (name.isNotEmpty) Navigator.pop<String>(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('新建传输'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('先给传输起个名字，文件可以稍后添加。手机扫码后，也能直接把文件传给电脑。',
                    style: TextStyle(
                        color: AppTheme.colorsOf(context).muted, height: 1.7)),
                const SizedBox(height: 20),
                TextField(
                  key: CreatePageDialog.titleFieldKey,
                  controller: _input,
                  autofocus: true,
                  maxLength: 80,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                      labelText: '传输名称', hintText: '例如：工作资料、旅行照片'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          ActionMotion(
              child: TextButton(
                  key: CreatePageDialog.cancelKey,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'))),
          ActionMotion(
              child: FilledButton(
                  key: CreatePageDialog.submitKey,
                  onPressed: _input.text.trim().isEmpty ? null : _submit,
                  child: const Text('创建传输'))),
        ],
      );
}
