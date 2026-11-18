// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/main.dart';
import 'package:landrop/app_theme.dart';
import 'package:landrop/desktop_file_manager.dart';
import 'package:landrop/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PreviewController extends LanDropController {
  _PreviewController({this.empty = false});
  final bool empty;

  @override
  Future<void> initialize() async {
    addresses = ['192.168.1.108'];
    receiveDirectory = '/Users/you/Downloads/LanDrop';
    if (!empty) {
      pages.add(SharePage(
        id: '00000000-0000-4000-8000-000000000001',
        title: '周末旅行',
        running: true,
        files: const [
          SharedFile(
              id: '00000000-0000-4000-8000-000000000002',
              name: '周末旅行照片.zip',
              path: '/tmp/photos.zip',
              size: 148478361,
              managed: false),
          SharedFile(
              id: '00000000-0000-4000-8000-000000000003',
              name: '海边的日落.jpg',
              path: '/tmp/sunset.jpg',
              size: 5242880,
              managed: false),
          SharedFile(
              id: '00000000-0000-4000-8000-000000000004',
              name: '行程与预订信息.pdf',
              path: '/tmp/trip.pdf',
              size: 854016,
              managed: false),
        ],
      ));
      receivedFiles.add(ReceivedFile(
          name: '手机拍摄的照片.jpg',
          path: '/Users/you/Downloads/LanDrop/手机拍摄的照片.jpg',
          size: 3485286,
          pageId: pages.first.id,
          pageTitle: '周末旅行',
          receivedAt: DateTime(2026, 11, 17, 19, 32)));
    }
    if (!empty) {
      transfers.add(TransferTask(
          id: 'preview-transfer',
          pageId: pages.first.id,
          pageTitle: pages.first.title,
          name: '手机拍摄的旅行短片.mp4',
          direction: 'upload',
          totalBytes: 104857600,
          transferredBytes: 67108864)
        ..bytesPerSecond = 4194304);
    }
    notifyListeners();
  }

  @override
  Future<String> receiveDirectoryFor(SharePage page) async =>
      "/virtual/receipts/${page.id}";

  @override
  int? portFor(SharePage page) => page.running ? 47123 : null;

  final deletedPageIds = <String>[];

  @override
  Future<void> removePage(SharePage page) async {
    deletedPageIds.add(page.id);
    pages.removeWhere((candidate) => candidate.id == page.id);
    receivedFiles.removeWhere((file) => file.pageId == page.id);
    notifyListeners();
  }
}

class _TestFileManager extends DesktopFileManager {
  final opened = <String>[];
  final revealed = <String>[];
  bool fail = false;
  Completer<void>? pending;

  @override
  Future<void> openDirectory(String path) async {
    opened.add(path);
    if (pending != null) await pending!.future;
    if (fail) throw const FileManagerException('接收文件夹不存在或已被移动。');
  }

  @override
  Future<void> revealFile(String path) async {
    revealed.add(path);
    if (pending != null) await pending!.future;
    if (fail) throw const FileManagerException('文件不存在或已被移动，无法在文件夹中显示。');
  }
}

const _capture = bool.fromEnvironment('UI_SHOTS');
const _fontPath = String.fromEnvironment('UI_FONT');

Future<void> _captureImage(GlobalKey key, String name) async {
  if (!_capture) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final directory = Directory('../.tmp/ui-preview/shots')
    ..createSync(recursive: true);
  File('${directory.path}/$name.png')
      .writeAsBytesSync(data!.buffer.asUint8List());
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_fontPath.isNotEmpty) {
      final bytes = File(_fontPath).readAsBytesSync();
      for (final family in ['Roboto', 'Arial', 'Ahem', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(File(
                '../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytesSync())));
      await icons.load();
    }
  });

  for (final width in [1440.0, 1024.0, 820.0, 680.0, 390.0]) {
    testWidgets('workspace renders without overflow at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      addTearDown(controller.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light,
              home: HomeScreen(
                  controller: controller, pickFiles: () async => []))));
      await tester.pumpAndSettle();
      expect(find.text('周末旅行'), findsWidgets);
      expect(find.text('周末旅行照片.zip'), findsNothing);
      expect(find.text('传输动态'), findsNothing);
      expect(find.text('接收记录'), findsNothing);
      expect(find.text('手机拍摄的旅行短片.mp4'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester
          .runAsync(() => _captureImage(key, 'desktop-${width.toInt()}'));
      await tester.tap(find.byKey(const ValueKey(
          'open-transfer-00000000-0000-4000-8000-000000000001')));
      await tester.pumpAndSettle();
      expect(find.text('周末旅行照片.zip'), findsOneWidget);
      expect(find.text('海边的日落.jpg'), findsOneWidget);
      expect(find.text('手机拍摄的照片.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
          () => _captureImage(key, 'desktop-detail-${width.toInt()}'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('dark transfer detail and settings have themed surfaces',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    final appearance = ThemeController();
    addTearDown(controller.dispose);
    addTearDown(appearance.dispose);
    await appearance.setMode(ThemeMode.dark);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: LanDropApp(
          appearance: appearance,
          home: HomeScreen(
              controller: controller,
              appearance: appearance,
              pickFiles: () async => []),
        )));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(HomeScreen))).brightness,
        Brightness.dark);
    await tester.tap(find.byKey(
        const ValueKey('open-transfer-00000000-0000-4000-8000-000000000001')));
    await tester.pumpAndSettle();
    expect(find.text('来自手机的文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => _captureImage(key, 'desktop-dark'));
    await tester.tap(find.text('应用设置').first);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('theme-dark')))
            .selected,
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => _captureImage(key, 'desktop-settings-dark'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty state opens name-only creation without native picker',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(
            controller: _PreviewController(empty: true),
            pickFiles: () async => [])));
    await tester.pumpAndSettle();
    final create = find.byKey(const ValueKey('new-transfer'));
    expect(create, findsWidgets);
    await tester.tap(create.first);
    await tester.pumpAndSettle();
    expect(find.text('传输名称'), findsOneWidget);
    expect(find.text('选择文件（可多选）'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('transfer summary exposes confirmed delete action',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light, home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();

    const pageId = '00000000-0000-4000-8000-000000000001';
    final delete = find.byKey(const ValueKey('delete-transfer-$pageId'));
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('删除「周末旅行」？'), findsOneWidget);
    expect(find.textContaining('已接收文件和电脑上的原文件不会删除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.deletedPageIds, isEmpty);

    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(controller.deletedPageIds, [pageId]);
    expect(find.text('还没有传输'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'transfer detail shows shared and received files and copies actual path',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            home: HomeScreen(
                controller: controller, pickFiles: () async => []))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
        const ValueKey('open-transfer-00000000-0000-4000-8000-000000000001')));
    await tester.pumpAndSettle();
    expect(find.text('手机拍摄的照片.jpg'), findsOneWidget);
    expect(find.text('来自手机的文件'), findsOneWidget);
    expect(find.text('周末旅行照片.zip'), findsOneWidget);
    await tester.ensureVisible(find.text('手机拍摄的照片.jpg'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => _captureImage(key, 'desktop-received'));
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.ensureVisible(find.byTooltip('复制保存路径'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制保存路径'));
    await tester.pumpAndSettle();
    expect(copied, controller.receivedFiles.single.path);
    expect(find.text('文件路径已复制'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(HomeScreen)))
        .removeCurrentSnackBar();
    for (final entry in {'应用设置': 'desktop-settings'}.entries) {
      await tester.tap(find.text(entry.key).first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => _captureImage(key, entry.value));
      expect(tester.takeException(), isNull);
    }
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final width in [1440.0, 390.0]) {
    testWidgets('received folder actions route actual paths at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _PreviewController();
      final manager = _TestFileManager();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: HomeScreen(controller: controller, fileManager: manager)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(
          'open-transfer-00000000-0000-4000-8000-000000000001')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('打开接收文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开接收文件夹'));
      await tester.pumpAndSettle();
      expect(manager.opened,
          [await controller.receiveDirectoryFor(controller.pages.single)]);
      final reveal = find.text('在文件夹中显示');
      await tester.ensureVisible(reveal);
      await tester.pumpAndSettle();
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(manager.revealed, [controller.receivedFiles.single.path]);
      expect(tester.takeException(), isNull);
      manager.fail = true;
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(find.textContaining('文件不存在或已被移动'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('folder actions block duplicate requests while opening',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    final manager = _TestFileManager()..pending = Completer<void>();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(controller: controller, fileManager: manager)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
        const ValueKey('open-transfer-00000000-0000-4000-8000-000000000001')));
    await tester.pumpAndSettle();
    final folder = find.byKey(const ValueKey('open-receive-directory'));
    await tester.ensureVisible(folder);
    await tester.pumpAndSettle();
    await tester.tap(folder);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(folder).onPressed, isNull);
    expect(manager.opened, hasLength(1));
    manager.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(folder).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
