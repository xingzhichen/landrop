// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/main.dart';
import 'package:landrop/app_theme.dart';

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
          pageTitle: '周末旅行',
          receivedAt: DateTime(2026, 11, 17, 19, 32)));
    }
    notifyListeners();
  }

  @override
  int? portFor(SharePage page) => page.running ? 47123 : null;
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
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light,
              home: HomeScreen(
                  controller: _PreviewController(),
                  pickFiles: () async => []))));
      await tester.pumpAndSettle();
      expect(find.text('周末旅行'), findsWidgets);
      expect(find.text('周末旅行照片.zip'), findsOneWidget);
      expect(find.text('海边的日落.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester
          .runAsync(() => _captureImage(key, 'desktop-${width.toInt()}'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('empty state opens file dialog without native picker',
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
    final create = find.widgetWithText(FilledButton, '新建页面');
    expect(create, findsWidgets);
    await tester.tap(create.first);
    await tester.pumpAndSettle();
    expect(find.text('选择文件（可多选）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('reception navigation shows saved files and copies actual path',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
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
    await tester.tap(find.text('接收记录').first);
    await tester.pumpAndSettle();
    expect(find.text('手机拍摄的照片.jpg'), findsOneWidget);
    expect(find.text('来自手机的文件'), findsOneWidget);
    expect(find.text('周末旅行照片.zip'), findsNothing);
    await tester.runAsync(() => _captureImage(key, 'desktop-received'));
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.tap(find.byTooltip('复制保存路径'));
    await tester.pumpAndSettle();
    expect(copied, controller.receivedFiles.single.path);
    expect(find.text('文件路径已复制'), findsOneWidget);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
