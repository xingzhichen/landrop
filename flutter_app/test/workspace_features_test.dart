// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/create_page_dialog.dart';
import 'package:landrop/desktop_shell.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/main.dart';
import 'package:landrop/theme_controller.dart';
import 'package:landrop/workspace_dialogs.dart';
import 'package:landrop/workspace_motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _existingId = '00000000-0000-4000-8000-000000000001';

final class _PickedFile extends PlatformFile {
  _PickedFile(this.name);
  @override
  final String name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  final fileSelections = <List<PlatformFile>>[];
  var refreshCalls = 0;
  Completer<void>? refreshBarrier;
  Completer<void>? startEntered;
  Completer<void>? startBarrier;
  @override
  Future<void> refreshAddresses() async {
    refreshCalls++;
    if (refreshBarrier != null) await refreshBarrier!.future;
  }

  @override
  Future<String> receiveDirectoryFor(SharePage page) async =>
      page.receiveDirectory ?? "/downloads/${page.id}";

  @override
  Future<void> addFiles(SharePage page, List<PlatformFile> selections) async {
    fileSelections.add(List.of(selections));
    await addPaths(page, selections.map((file) => file.name).toList());
  }

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
    final entered = startEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    final barrier = startBarrier;
    if (barrier != null) await barrier.future;
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
  Future<List<PlatformFile>> Function()? pickFiles,
  ThemeController? appearance,
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
  final theme = appearance ?? ThemeController();
  if (appearance == null) addTearDown(theme.dispose);
  await tester.pumpWidget(LanDropApp(
    appearance: theme,
    home: Builder(
        builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: HomeScreen(
                controller: model,
                shell: shell,
                appearance: theme,
                pickFiles: pickFiles ?? () async => [],
                pickDirectory: pickDirectory ?? () async => null,
              ),
            )),
  ));
  await tester.pumpAndSettle();
  expect(shell.drop, isNotNull);
  expect(tester.takeException(), isNull);
  return (controller: model, shell: shell);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
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

  testWidgets('drop import completion respects navigation during startup',
      (tester) async {
    final fixture = await _mount(tester);
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    fixture.controller.startEntered = startEntered;
    fixture.controller.startBarrier = releaseStart;
    addTearDown(() {
      if (!releaseStart.isCompleted) releaseStart.complete();
    });

    fixture.shell.drop!(['/drop/late-import.pdf']);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('import-page-title')), '延迟导入');
    await tester
        .ensureVisible(find.byKey(const ValueKey('confirm-import-paths')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-import-paths')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(startEntered.isCompleted, isTrue);

    await tester.tap(find.byKey(const ValueKey('navigation-item-1')));
    await tester.pump();
    expect(find.text('工作台  /  应用设置'), findsOneWidget);

    releaseStart.complete();
    await tester.pumpAndSettle();

    expect(fixture.controller.pages.last.running, isTrue);
    expect(
        fixture.controller.addedPaths.single.paths, ['/drop/late-import.pdf']);
    expect(find.text('工作台  /  应用设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('back-to-transfers')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long dragged basename is truncated before title submission',
      (tester) async {
    final fixture = await _mount(tester);
    // 79 CJK characters plus a decomposed accent, extra text and extension
    // stay below common 255-byte filename limits while exceeding 80 graphemes.
    final longName = '${List.filled(79, '字').join()}e\u0301x.txt';
    final expectedTitle = longName.characters.take(80).toString();
    expect(expectedTitle.endsWith('e\u0301'), isTrue);
    fixture.shell.drop!(['/drop/$longName']);
    await tester.pumpAndSettle();

    final titleField = tester
        .widget<TextField>(find.byKey(const ValueKey('import-page-title')));
    expect(titleField.maxLength, 80);
    expect(titleField.controller!.text, expectedTitle);
    expect(titleField.controller!.text.characters.length, 80);
    await _tap(tester, find.byKey(const ValueKey('confirm-import-paths')));

    final submittedTitle = fixture.controller.events
        .singleWhere((event) => event.startsWith('create:'))
        .substring('create:'.length);
    expect(submittedTitle, expectedTitle);
    expect(submittedTitle.characters.length, lessThanOrEqualTo(80));
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
      'detail folder cancellation is inert and retry adds to selected transfer',
      (tester) async {
    var picks = 0;
    final fixture = await _mount(tester,
        pickDirectory: () async => ++picks == 1 ? null : '/chosen/项目资料');
    await _tap(
        tester, find.byKey(const ValueKey('open-transfer-$_existingId')));
    await _tap(tester, find.text('添加文件夹'));
    expect(fixture.controller.events, isEmpty);
    await _tap(tester, find.text('添加文件夹'));
    expect(find.byType(ImportPathsDialog), findsNothing);
    expect(fixture.controller.addedPaths.single.paths, ['/chosen/项目资料']);
    expect(fixture.controller.events, ['add:已有页面']);
    expect(fixture.controller.pages, hasLength(1));
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

  testWidgets('receive-directory picker errors are announced accessibly',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = await _mount(tester, pickDirectory: () async {
      throw StateError('permission denied');
    });
    await _openReceiveSettings(tester);
    await _tap(tester, find.byKey(const ValueKey('choose-receive-directory')));

    const message = '选择文件夹失败，请检查访问权限后重试。';
    final error = find.text(message);
    expect(error, findsOneWidget);
    final data = tester.getSemantics(error).getSemanticsData();
    expect(data.label, message);
    expect(data.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    expect(tester.takeException(), isNull);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(fixture.controller.pages, hasLength(1));
  });

  testWidgets(
      'receive settings block conflicting edits while picker is pending',
      (tester) async {
    final selection = Completer<String?>();
    addTearDown(() {
      if (!selection.isCompleted) selection.complete(null);
    });
    final fixture = await _mount(tester, pickDirectory: () => selection.future);
    await _openReceiveSettings(tester);
    await tester.tap(find.byKey(const ValueKey('choose-receive-directory')));
    await tester.pump();

    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('choose-receive-directory')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '恢复默认位置'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('organize-by-date')))
            .onChanged,
        isNull);
    expect(tester.widget<TextButton>(_cancel).onPressed, isNull);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('save-receive-options')))
            .onPressed,
        isNull);

    selection.complete('/chosen/late-result');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('choose-receive-directory')))
            .onPressed,
        isNotNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '恢复默认位置'))
            .onPressed,
        isNotNull);

    await _tap(tester, find.text('恢复默认位置'));
    await _tap(tester, find.byKey(const ValueKey('save-receive-options')));
    expect(fixture.controller.receiveOptions.single.directory, isNull);
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

  for (final width in [1440.0, 1024.0, 820.0, 680.0, 390.0]) {
    testWidgets(
        'two navigation destinations and detail do not overflow at $width',
        (tester) async {
      await _mount(tester, width: width);
      expect(find.text('接收记录'), findsNothing);
      expect(find.text('传输动态'), findsNothing);
      await _tap(
          tester, find.byKey(const ValueKey('open-transfer-$_existingId')));
      expect(find.text('来自手机的文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.byKey(const ValueKey('back-to-transfers')));
      for (final title in ['应用设置', '我的传输']) {
        await _navigate(tester, title);
        expect(find.text('工作台  /  $title'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $title');
      }
    });
  }

  testWidgets('late transfer startup does not override later navigation',
      (tester) async {
    final fixture = await _mount(tester);
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    fixture.controller.startEntered = startEntered;
    fixture.controller.startBarrier = releaseStart;
    addTearDown(() {
      if (!releaseStart.isCompleted) releaseStart.complete();
    });

    await _tap(tester, find.byKey(const ValueKey('new-transfer')));
    await tester.enterText(
        find.byKey(CreatePageDialog.titleFieldKey), '延迟启动传输');
    await tester.ensureVisible(find.byKey(CreatePageDialog.submitKey));
    await tester.pump();
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CreatePageDialog), findsNothing);
    expect(fixture.controller.events, ['create:延迟启动传输', 'start:延迟启动传输']);
    expect(startEntered.isCompleted, isTrue);

    await tester.tap(find.byKey(const ValueKey('navigation-item-1')));
    await tester.pump();
    expect(find.text('工作台  /  应用设置'), findsOneWidget);

    releaseStart.complete();
    await tester.pumpAndSettle();

    expect(fixture.controller.pages.last.running, isTrue);
    expect(find.text('工作台  /  应用设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('back-to-transfers')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('name-only creation starts empty transfer and opens its detail',
      (tester) async {
    var pickerCalls = 0;
    final fixture = await _mount(tester, pickFiles: () async {
      pickerCalls++;
      return [];
    });
    await _tap(tester, find.byKey(const ValueKey('new-transfer')));
    await tester.enterText(
        find.byKey(CreatePageDialog.titleFieldKey), '  空传输  ');
    await _tap(tester, find.byKey(CreatePageDialog.submitKey));
    expect(fixture.controller.events, ['create:空传输', 'start:空传输']);
    expect(pickerCalls, 0);
    expect(fixture.controller.pages.last.files, isEmpty);
    expect(fixture.controller.pages.last.running, isTrue);
    expect(find.byKey(const ValueKey('back-to-transfers')), findsOneWidget);
    expect(find.text('还没有接收文件'), findsOneWidget);
    expect(find.text('添加文件'), findsOneWidget);
  });

  testWidgets(
      'same-title transfers isolate share files and receipts after back navigation',
      (tester) async {
    final model = _WorkspaceController();
    final first = model.pages.single;
    final second = SharePage(
        id: 'second',
        title: first.title,
        files: [
          const SharedFile(
              id: 'second-file',
              name: '第二组分享.txt',
              path: '/second.txt',
              size: 1,
              managed: false),
        ],
        running: true);
    model.pages.add(second);
    for (final page in model.pages) {
      model.receivedFiles.add(ReceivedFile(
          name: '${page.id}.jpg',
          path: '/saved/${page.id}.jpg',
          size: 42,
          pageId: page.id,
          pageTitle: page.title,
          receivedAt: DateTime(2026, 11, 17)));
    }
    await _mount(tester, controller: model);
    await _tap(tester, find.byKey(ValueKey('open-transfer-${first.id}')));
    expect(find.text('${first.id}.jpg'), findsOneWidget);
    expect(find.text('${second.id}.jpg'), findsNothing);
    expect(find.text('第二组分享.txt'), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('back-to-transfers')));
    await _tap(tester, find.byKey(ValueKey('open-transfer-${second.id}')));
    expect(find.text('${second.id}.jpg'), findsOneWidget);
    expect(find.text('${first.id}.jpg'), findsNothing);
    expect(find.text('第二组分享.txt'), findsOneWidget);
  });

  testWidgets('drop in detail directly appends only to the selected transfer',
      (tester) async {
    final fixture = await _mount(tester);
    await _tap(
        tester, find.byKey(const ValueKey('open-transfer-$_existingId')));
    fixture.shell.drop!(['/drop/detail.txt']);
    await tester.pumpAndSettle();
    expect(find.byType(ImportPathsDialog), findsNothing);
    expect(fixture.controller.events, ['add:已有页面']);
    expect(fixture.controller.addedPaths.single.page.id, _existingId);
    expect(find.text('detail.txt'), findsOneWidget);
  });

  testWidgets(
      'file picker cancel, error and retry keep existing transfer intact',
      (tester) async {
    var calls = 0;
    final fixture = await _mount(tester, pickFiles: () async {
      switch (++calls) {
        case 1:
          return [];
        case 2:
          throw PlatformException(code: 'ENTITLEMENT_NOT_FOUND');
        default:
          return [_PickedFile('重试成功.txt')];
      }
    });
    await _tap(
        tester, find.byKey(const ValueKey('open-transfer-$_existingId')));
    await _tap(tester, find.text('添加文件'));
    expect(fixture.controller.fileSelections, isEmpty);
    await _tap(tester, find.text('添加文件'));
    expect(find.textContaining('ENTITLEMENT_NOT_FOUND'), findsOneWidget);
    expect(fixture.controller.pages.single.files, isEmpty);
    await _tap(tester, find.text('添加文件'));
    expect(calls, 3);
    expect(fixture.controller.fileSelections.single.single.name, '重试成功.txt');
    expect(find.text('重试成功.txt'), findsOneWidget);
  });

  testWidgets('pending file picker blocks stale and repeated add actions',
      (tester) async {
    final pending = Completer<List<PlatformFile>>();
    var calls = 0;
    final fixture = await _mount(tester, pickFiles: () {
      calls++;
      return pending.future;
    });
    await _tap(
        tester, find.byKey(const ValueKey('open-transfer-$_existingId')));
    final button = find.widgetWithText(OutlinedButton, '添加文件');
    final stale = tester.widget<OutlinedButton>(button).onPressed!;
    stale();
    stale();
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '添加文件夹'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('new-transfer')))
            .onPressed,
        isNull);
    expect(fixture.controller.fileSelections, isEmpty);
    pending.complete([_PickedFile('单次添加.txt')]);
    await tester.pumpAndSettle();
    expect(fixture.controller.fileSelections, hasLength(1));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
  });

  testWidgets('async refresh restores focus after its busy state',
      (tester) async {
    final fixture = await _mount(tester);
    final barrier = Completer<void>();
    fixture.controller.refreshBarrier = barrier;
    final button = find.widgetWithIcon(IconButton, Icons.refresh);
    final focus = tester.widget<IconButton>(button).focusNode!;
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.controller.refreshCalls, 1);
    barrier.complete();
    await tester.pumpAndSettle();
    expect(focus.hasPrimaryFocus, isTrue);

    final secondBarrier = Completer<void>();
    fixture.controller.refreshBarrier = secondBarrier;
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final userFocus = FocusManager.instance.primaryFocus;
    expect(userFocus, isNot(same(focus)));
    secondBarrier.complete();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(userFocus));
  });

  testWidgets(
      'real LanDropApp persists all appearance choices and follows live system brightness',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final theme = ThemeController();
    addTearDown(theme.dispose);
    await _mount(tester, appearance: theme);
    await _navigate(tester, '应用设置');
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(HomeScreen))).brightness;
    for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
      await _tap(tester, find.byKey(ValueKey('theme-${mode.name}')));
      expect(theme.mode, mode);
      expect(
          tester
              .widget<ChoiceChip>(find.byKey(ValueKey('theme-${mode.name}')))
              .selected,
          isTrue);
      expect(
          (await SharedPreferences.getInstance())
              .getString(ThemeController.preferenceKey),
          mode.name);
      expect(brightness(),
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light);
    }
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect(theme.mode, ThemeMode.system);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    expect(
        (await SharedPreferences.getInstance())
            .getString(ThemeController.preferenceKey),
        'system');
  });

  testWidgets('disabled actions do not receive hover or press motion',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: ActionMotion(
            child: FilledButton(
              onPressed: null,
              child: Text('Disabled action'),
            ),
          ),
        ),
      ),
    ));
    final button = find.byType(FilledButton);
    final outerMotion = find
        .ancestor(of: button, matching: find.byType(AnimatedContainer))
        .first;
    final scaleMotion =
        find.ancestor(of: button, matching: find.byType(AnimatedScale)).first;
    final center = tester.getCenter(button);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await tester.pump();
    await mouse.moveTo(center + const Offset(1, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
        tester
            .widget<AnimatedContainer>(outerMotion)
            .transform!
            .getTranslation()
            .y,
        0);
    await mouse.down(center);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.widget<AnimatedScale>(scaleMotion).scale, 1);
    await mouse.up();
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('indeterminate wait states respect reduced motion and announce',
      (tester) async {
    final semantics = tester.ensureSemantics();
    void expectLiveRegion(Finder finder, String label) {
      final data = tester.getSemantics(finder).getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
      expect(data.label, contains(label));
    }

    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Column(mainAxisSize: MainAxisSize.min, children: [
            WorkspaceProgress(label: '正在准备传输工作台…'),
            WorkspaceProgress(linear: true, label: '正在处理操作'),
          ]),
        ),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.hourglass_empty_rounded), findsNWidgets(2));
    expect(find.text('正在准备传输工作台…'), findsOneWidget);
    expect(find.text('正在处理操作'), findsOneWidget);
    expectLiveRegion(find.text('正在准备传输工作台…'), '正在准备传输工作台…');
    expectLiveRegion(find.text('正在处理操作'), '正在处理操作');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(mainAxisSize: MainAxisSize.min, children: [
          WorkspaceProgress(label: '正在准备传输工作台…'),
          WorkspaceProgress(linear: true, label: '正在处理操作'),
        ]),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expectLiveRegion(find.text('正在准备传输工作台…'), '正在准备传输工作台…');
    expectLiveRegion(find.byType(LinearProgressIndicator), '正在处理操作');
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'reduced-motion content is visible immediately without an entry opacity tween',
      (tester) async {
    await _mount(tester, reduceMotion: true);
    final pageEntry = find.byKey(const ValueKey("open-transfer-$_existingId"));
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
