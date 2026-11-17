// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'landrop_controller.dart';
import 'workspace_motion.dart';

String transferSize(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class TransferPanel extends StatelessWidget {
  const TransferPanel({super.key, required this.tasks, required this.onCancel});
  final List<TransferTask> tasks;
  final void Function(TransferTask) onCancel;
  @override
  Widget build(BuildContext context) {
    final active = tasks
        .where((task) => task.status == 'active' || task.status == 'paused')
        .toList();
    final history = tasks
        .where((task) => task.status != 'active' && task.status != 'paused')
        .take(30)
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
          '${active.where((task) => task.status == 'active').length} 项正在传输 · ${active.where((task) => task.status == 'paused').length} 项暂停',
          style: const TextStyle(color: AppTheme.muted)),
      const SizedBox(height: 16),
      if (tasks.isEmpty)
        const Card(
            child: Padding(
                padding: EdgeInsets.all(36),
                child: Column(children: [
                  Icon(Icons.sync_alt, size: 42, color: AppTheme.primary),
                  SizedBox(height: 16),
                  Text('还没有传输任务',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  SizedBox(height: 8),
                  Text('手机开始上传或下载后，会在这里显示真实进度、速度和剩余时间。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.muted, height: 1.6))
                ]))),
      for (final task in [...active, ...history])
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WorkspaceEntry(
                key: ValueKey(task.id), child: _taskCard(context, task))),
      if (tasks.isNotEmpty)
        const Text(
            '上传暂停后，请在网页中继续，或重新选择原文件续传。下载由浏览器管理，支持 HTTP Range 续传。进度统计以本机收发字节为准，不代表对端已经保存到磁盘。',
            style: TextStyle(fontSize: 12, color: AppTheme.muted, height: 1.6)),
    ]);
  }

  Widget _taskCard(BuildContext context, TransferTask task) {
    final status = switch (task.status) {
      'active' => '传输中',
      'completed' => '已完成',
      'paused' => '已暂停',
      'cancelled' => '已取消',
      _ => '失败'
    };
    final seconds = task.remainingSeconds;
    final eta = seconds == null
        ? '计算剩余时间…'
        : seconds >= 60
            ? '约 ${(seconds / 60).ceil()} 分钟'
            : '约 ${seconds.ceil()} 秒';
    final transferring = task.status == 'active';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                        task.direction == 'upload'
                            ? Icons.south_west_rounded
                            : Icons.north_east_rounded,
                        color: AppTheme.primary,
                        size: 23),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(task.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 5),
                          Text(
                              '${task.direction == 'upload' ? '接收' : '发送'} · ${task.pageTitle}',
                              style: const TextStyle(
                                  color: AppTheme.muted, fontSize: 12))
                        ])),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                        duration: motionDuration(context),
                        child: Text(status,
                            key: ValueKey(status),
                            style: TextStyle(
                                color: task.status == 'failed'
                                    ? Theme.of(context).colorScheme.error
                                    : AppTheme.muted,
                                fontSize: 12))),
                  ]),
                  const SizedBox(height: 16),
                  TweenAnimationBuilder<double>(
                      tween: Tween(end: task.progress),
                      duration: motionDuration(context, 160),
                      builder: (context, progress, _) => ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 6,
                              semanticsLabel: '${task.name}传输进度',
                              semanticsValue:
                                  '${(task.progress * 100).round()}%'))),
                  const SizedBox(height: 10),
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                            '${transferSize(task.transferredBytes)} / ${transferSize(task.totalBytes)}',
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.muted)),
                        if (transferring)
                          Text('${transferSize(task.bytesPerSecond)}/s · $eta',
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.muted)),
                        if (transferring || task.status == 'paused')
                          ActionMotion(
                              child: TextButton.icon(
                                  key: ValueKey('cancel-transfer-${task.id}'),
                                  onPressed: () => onCancel(task),
                                  icon: const Icon(Icons.close, size: 16),
                                  label: const Text('取消传输'))),
                      ]),
                ])));
  }
}
