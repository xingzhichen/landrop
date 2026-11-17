// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/app_theme.dart';
import 'package:landrop/desktop_shell.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/main.dart';
import 'package:landrop/transfer_panel.dart';
import 'package:landrop/workspace_dialogs.dart';
import 'package:landrop/workspace_motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _existingId = '00000000-0000-4000-8000-000000000001';

/// Only test-owned models are mutated. No sockets, filesystem or platform APIs.
class _WorkspaceController extends LanDropController {
  _WorkspaceController() {
    pages.add(SharePage(
      id: _existingId,
      title: '已有页面',
      files: [],
      running: true,
      receiveDirectory: '/saved/接收目录',
    ));
  }

  final events = <String>[];
  final addedPaths = <({SharePage page, List<String> paths})>[];
  final receiveOptions =
      <({SharePage page, String? directory, bool organizeByDate})>[];
  final cancelled = <String>[];

  @override
  Future<void> initialize() async {
    addresses = ['192.168.1.108'];
    receiveDirectory = '/downloads/LanDrop';
    notifyListeners();
  }

  @override
  int? portFor(SharePage page) => page.running ? 47123 : null;

  @override
  Future<SharePage> createPage(String title) async {
    events.add('create:$title');
    final page = SharePage(
      id: '00000000-0000-4000-8000-${(pages.length + 1).toString().padLeft(12, '0')}',
      title: title,
      files: [],
    );
    pages.add(page);
    notifyListeners();
    return page;
  }

  @override
  Future<void> addPaths(SharePage page, List<String> paths) async {
    events.add('add:${page.title}');
    addedPaths.add((page: page, paths: List.of(paths)));
    for (final path in paths) {
      page.files.add(SharedFile(
        id: 'test-file-${page.files.length}',
        name: path.split('/').last,
        path: path,
        size: 256,
        managed: false,
      ));
    }
    notifyListeners();
  }

  @override
  Future<void> start(SharePage page) async {
    events.add('start:${page.title}');
    page.running = true;
    notifyListeners();
  }

  @override
  Future<void> setReceiveOptions(SharePage page,
      {String? directory, bool organizeByDate = false}) async {
    receiveOptions.add((
      page: page,
      directory: directory,
      organizeByDate: organizeByDate,
    ));
    page.receiveDirectory = directory;
    page.organizeByDate = organizeByDate;
    notifyListeners();
  }

  @override
  Future<void> cancelTransfer(String id) async {
    cancelled.add(id);
    transfers.firstWhere((task) => task.id == id).status = 'cancelled';
    notifyListeners();
  }

  void advance(TransferTask task, int bytes) {
    task.transferredBytes = bytes;
    task.bytesPerSecond = 128;
    notifyListeners();
  }
}

class _WorkspaceShell extends DesktopShell {
  void Function(List<String>)? drop;
  void Function(bool)? drag;
  final backgroundModes = <bool>[];
  var quitCalls = 0;
  var disposed = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize({
    required void Function(List<String>) onDrop,
    required void Function() onShow,
    void Function(bool)? onDragChanged,
  }) async {
    drop = onDrop;
    drag = onDragChanged;
  }

  @override
  Future<void> setBackgroundMode(bool enabled) async {
    backgroundModes.add(enabled);
  }

  @override
  Future<void> quit() async {
    quitCalls++;
  }

  @override
  void dispose() {
    disposed = true;
    drop = null;
    drag = null;
  }
}

typedef _Fixture = ({
  _WorkspaceController controller,
  _WorkspaceShell shell,
});

Future<_Fixture> _mount(
  WidgetTester tester, {
  double width = 1440,
  _WorkspaceController? controller,
  Future<String?> Function()? pickDirectory,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = controller ?? _WorkspaceController();
  final shell = _WorkspaceShell();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: HomeScreen(
      controller: model,
      shell: shell,
      pickFiles: () async => [],
      pickDirectory: pickDirectory ?? () async => null,
    ),
  ));
  await tester.pumpAndSettle();
  expect(shell.drop, isNotNull);
  expect(tester.takeException(), isNull);
  return (controller: model, shell: shell);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _navigate(WidgetTester tester, String title) =>
    _tap(tester, find.text(title).first);

Finder get _dialog => find.byType(AlertDialog);
Finder get _cancel => find.descendant(
      of: _dialog,
      matching: find.widgetWithText(TextButton, '取消'),
    );

Future<void> _openReceiveSettings(WidgetTester tester) async {
  await _navigate(tester, '应用设置');
  await _tap(tester, find.widgetWithText(OutlinedButton, '设置'));
  expect(find.byType(ReceiveOptionsDialog), findsOneWidget);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('native drop creates a page, imports exact paths, then starts it',
      (tester) async {
    final fixture = await _mount(tester);
    fixture.shell.drop!(['/drop/手机 照片.jpg', '/drop/旅行文件夹']);
    await tester.pumpAndSettle();
    expect(find.byType(ImportPathsDialog), findsOneWidget);
    expect(fixture.controller.events, isEmpty);
    await tester.enterText(
        find.byKey(const ValueKey('import-page-title')), '旅行分享');
    await _tap(tester, find.byKey(const ValueKey('confirm-import-paths')));
    expect(
        fixture.controller.events, ['create:旅行分享', 'add:旅行分享', 'start:旅行分享']);
    final imported = fixture.controller.addedPaths.single;
    expect(imported.paths, ['/drop/手机 照片.jpg', '/drop/旅行文件夹']);
    expect(imported.page, fixture.controller.pages.last);
    expect(imported.page.running, isTrue);
    expect(imported.page.files, hasLength(2));
    expect(find.byType(ImportPathsDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'native drop into existing page adds paths without creating or restarting',
      (tester) async {
    final fixture = await _mount(tester);
    final existing = fixture.controller.pages.single;
    fixture.shell.drop!(['/drop/追加.pdf']);
    await tester.pumpAndSettle();
    await _tap(
        tester,
        find.descendant(
            of: find.byType(ImportPathsDialog),
            matching: find.byType(DropdownButtonFormField<String>)));
    await _tap(tester, find.text('已有页面').last);
    expect(find.byKey(const ValueKey('import-page-title')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('confirm-import-paths')));
    expect(fixture.controller.pages, [existing]);
    expect(fixture.controller.events, ['add:已有页面']);
    expect(fixture.controller.addedPaths.single.page, same(existing));
    expect(fixture.controller.addedPaths.single.paths, ['/drop/追加.pdf']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cancelling native drop has no model side effects and allows retry',
      (tester) async {
    final fixture = await _mount(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      fixture.shell.drop!(['/drop/cancelled.txt']);
      await tester.pumpAndSettle();
      expect(find.byType(ImportPathsDialog), findsOneWidget);
      await _tap(tester, _cancel);
    }
    expect(fixture.controller.events, isEmpty);
    expect(fixture.controller.addedPaths, isEmpty);
    expect(fixture.controller.pages, hasLength(1));
    expect(fixture.controller.pages.single.files, isEmpty);
  });

  testWidgets(
      'native drag enter and leave change only the non-interactive overlay',
      (tester) async {
    final fixture = await _mount(tester);
    final overlay = find.ancestor(
        of: find.text('松开以分享文件或文件夹'), matching: find.byType(AnimatedOpacity));
    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 0);
    fixture.shell.drag!(true);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 1);
    final ignore =
        find.ancestor(of: overlay, matching: find.byType(IgnorePointer));
    expect(tester.widget<IgnorePointer>(ignore.first).ignoring, isTrue);
    expect(fixture.controller.events, isEmpty);
    fixture.shell.drag!(false);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 0);
    expect(find.byType(ImportPathsDialog), findsNothing);
  });

  testWidgets(
      'share folder picker cancellation is inert and a folder uses the import flow',
      (tester) async {
    var picks = 0;
    final fixture = await _mount(tester,
        pickDirectory: () async => ++picks == 1 ? null : '/chosen/项目资料');
    await _tap(tester, find.text('分享文件夹'));
    expect(find.byType(ImportPathsDialog), findsNothing);
    expect(fixture.controller.events, isEmpty);
    await _tap(tester, find.text('分享文件夹'));
    expect(find.byType(ImportPathsDialog), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('confirm-import-paths')));
    expect(picks, 2);
    expect(fixture.controller.addedPaths.single.paths, ['/chosen/项目资料']);
    expect(
        fixture.controller.events, ['create:项目资料', 'add:项目资料', 'start:项目资料']);
  });

  testWidgets(
      'receive directory picker cancellation preserves saved location and dialog cancel does not save',
      (tester) async {
    var picks = 0;
    final fixture = await _mount(tester, pickDirectory: () async {
      picks++;
      return null;
    });
    await _openReceiveSettings(tester);
    await _tap(tester, find.byKey(const ValueKey('choose-receive-directory')));
    expect(picks, 1);
    expect(find.text('/saved/接收目录'), findsWidgets);
    final date = find.byKey(const ValueKey('organize-by-date'));
    expect(tester.widget<SwitchListTile>(date).value, isFalse);
    await _tap(tester, date);
    await _tap(tester, _cancel);
    expect(fixture.controller.receiveOptions, isEmpty);
    expect(fixture.controller.pages.single.receiveDirectory, '/saved/接收目录');
    expect(fixture.controller.pages.single.organizeByDate, isFalse);
  });

  testWidgets(
      'receive settings save chosen directory and organize-by-date, then restore default',
      (tester) async {
    final fixture =
        await _mount(tester, pickDirectory: () async => '/chosen/按日期接收');
    await _openReceiveSettings(tester);
    await _tap(tester, find.byKey(const ValueKey('choose-receive-directory')));
    expect(find.text('/chosen/按日期接收'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('organize-by-date')));
    await _tap(tester, find.byKey(const ValueKey('save-receive-options')));
    final saved = fixture.controller.receiveOptions.single;
    expect(saved.page, same(fixture.controller.pages.single));
    expect(saved.directory, '/chosen/按日期接收');
    expect(saved.organizeByDate, isTrue);
    expect(fixture.controller.pages.single.organizeByDate, isTrue);
    await _tap(tester, find.widgetWithText(OutlinedButton, '设置'));
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('organize-by-date')))
            .value,
        isTrue);
    await _tap(tester, find.text('恢复默认位置'));
    await _tap(tester, find.byKey(const ValueKey('save-receive-options')));
    expect(fixture.controller.receiveOptions.last.directory, isNull);
    expect(fixture.controller.receiveOptions.last.organizeByDate, isTrue);
  });

  testWidgets(
      'transfer panel displays live model bytes, speed, ETA and invokes cancellation',
      (tester) async {
    final controller = _WorkspaceController();
    final task = TransferTask(
        id: 'live-transfer',
        pageId: _existingId,
        pageTitle: '已有页面',
        name: '正在接收.bin',
        direction: 'upload',
        totalBytes: 1024,
        transferredBytes: 256)
      ..bytesPerSecond = 128;
    controller.transfers.add(task);
    await _mount(tester, controller: controller);
    await _navigate(tester, '传输动态');
    expect(find.byType(TransferPanel), findsOneWidget);
    expect(find.text('256 B / 1.0 KB'), findsOneWidget);
    expect(find.text('128 B/s · 约 6 秒'), findsOneWidget);
    Finder progress() => find.byWidgetPredicate((widget) =>
        widget is LinearProgressIndicator &&
        widget.semanticsLabel == '正在接收.bin传输进度');
    expect(tester.widget<LinearProgressIndicator>(progress()).value, .25);
    controller.advance(task, 768);
    await tester.pumpAndSettle();
    expect(tester.widget<LinearProgressIndicator>(progress()).value, .75);
    expect(find.text('768 B / 1.0 KB'), findsOneWidget);
    expect(find.text('128 B/s · 约 2 秒'), findsOneWidget);
    await _tap(
        tester, find.byKey(const ValueKey('cancel-transfer-live-transfer')));
    expect(controller.cancelled, ['live-transfer']);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-transfer-live-transfer')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'settings persist background mode and quit requires explicit confirmation',
      (tester) async {
    final fixture = await _mount(tester);
    expect(fixture.shell.backgroundModes, [true]);
    await _navigate(tester, '应用设置');
    final toggle = find.widgetWithText(SwitchListTile, '关闭窗口后继续传输');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await _tap(tester, toggle);
    expect(fixture.shell.backgroundModes, [true, false]);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('landrop.background.v1'),
        isFalse);
    await _tap(tester, find.text('退出 LanDrop'));
    expect(find.text('退出 LanDrop？'), findsOneWidget);
    expect(fixture.shell.quitCalls, 0);
    await _tap(tester, _cancel);
    expect(fixture.shell.quitCalls, 0);
    await _tap(tester, find.text('退出 LanDrop'));
    await _tap(tester, find.widgetWithText(FilledButton, '退出'));
    expect(fixture.shell.quitCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(fixture.shell.disposed, isTrue);
  });

  testWidgets(
      'stored background preference is applied when initializing the widget',
      (tester) async {
    SharedPreferences.setMockInitialValues({'landrop.background.v1': false});
    final fixture = await _mount(tester);
    expect(fixture.shell.backgroundModes, [false]);
    await _navigate(tester, '应用设置');
    expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, '关闭窗口后继续传输'))
            .value,
        isFalse);
  });

  for (final width in [1440.0, 390.0]) {
    testWidgets(
        'all four navigation destinations render without overflow at $width',
        (tester) async {
      final controller = _WorkspaceController();
      controller.transfers.add(TransferTask(
          id: 'responsive-task',
          pageId: _existingId,
          pageTitle: '已有页面',
          name: '跨设备的文件传输.zip',
          direction: 'download',
          totalBytes: 4096,
          transferredBytes: 1024));
      final fixture =
          await _mount(tester, width: width, controller: controller);
      for (final title in ['传输页面', '接收记录', '传输动态', '应用设置']) {
        await _navigate(tester, title);
        expect(find.text('工作台  /  $title'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $title');
        await tester.drag(find.byType(ListView).first, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '$width / $title scrolled');
      }
      expect(fixture.shell.quitCalls, 0);
    });
  }

  testWidgets(
      'reduced-motion content is visible immediately without an entry opacity tween',
      (tester) async {
    await _mount(tester, reduceMotion: true);
    final pageEntry = find.byKey(const ValueKey(_existingId));
    expect(pageEntry, findsOneWidget);
    expect(find.descendant(of: pageEntry, matching: find.byType(Opacity)),
        findsNothing);
    expect(
        find.descendant(
            of: pageEntry,
            matching: find.byType(TweenAnimationBuilder<double>)),
        findsNothing);
    expect(tester.getSize(find.text('已有页面').first).height, greaterThan(0));
    // Mount a fresh WorkspaceEntry without settling to prove its initial frame
    // is visible, rather than merely checking the end of an animation.
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(body: WorkspaceEntry(child: Text('立即显示的内容'))),
      ),
    ));
    expect(find.text('立即显示的内容'), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
