import 'dart:async';

import 'package:file_picker/file_picker.dart';
// Match the Material API used by the app and the dialog under test.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/create_page_dialog.dart';

// Only names are consumed by the dialog; no native file or picker is needed.
final class TestPlatformFile extends PlatformFile {
  TestPlatformFile(this.name);

  @override
  final String name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef CreatedPage = (String, List<PlatformFile>);

class DialogHarness {
  Future<CreatedPage?>? result;
}

Future<DialogHarness> openDialog(
  WidgetTester tester,
  PickShareFiles picker,
) async {
  final harness = DialogHarness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () {
              harness.result = showDialog<CreatedPage>(
                context: context,
                builder: (_) => CreatePageDialog(pickFiles: picker),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return harness;
}

ButtonStyleButton button(WidgetTester tester, Key key) =>
    tester.widget<ButtonStyleButton>(find.byKey(key));

Future<void> pickFiles(WidgetTester tester) async {
  await tester.tap(find.byKey(CreatePageDialog.pickFilesKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'requires a nonblank title and files, returns trimmed title and files',
      (tester) async {
    final files = <PlatformFile>[
      TestPlatformFile('旅行照片.jpg'),
      TestPlatformFile('行程.pdf'),
    ];
    final harness = await openDialog(tester, () async => files);

    expect(find.text('新建传输页面'), findsOneWidget);
    expect(find.text('例如：旅行照片'), findsOneWidget);
    expect(find.text('选择文件（可多选）'), findsOneWidget);
    expect(find.text('已选择 0 个文件'), findsOneWidget);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNull);

    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '  ');
    await pickFiles(tester);
    expect(find.text('已选择 2 个文件'), findsOneWidget);
    expect(find.text('旅行照片.jpg'), findsOneWidget);
    expect(find.text('行程.pdf'), findsOneWidget);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNull);

    await tester.enterText(
      find.byKey(CreatePageDialog.titleFieldKey),
      '  我的旅行  ',
    );
    await tester.pump();
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNotNull);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();

    final result = await harness.result!;
    expect(result!.$1, '我的旅行');
    expect(result.$2, orderedEquals(files));
    expect(identical(result.$2, files), isFalse);
    expect(find.byType(CreatePageDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'title alone cannot create; native cancellation keeps existing files',
      (tester) async {
    final files = <PlatformFile>[TestPlatformFile('保留.txt')];
    var calls = 0;
    final harness = await openDialog(tester, () async {
      calls++;
      return calls == 2 ? files : <PlatformFile>[];
    });
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '保留选择');
    await tester.pump();
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNull);

    // Cancelling even the first picker is harmless.
    await pickFiles(tester);
    expect(find.text('已选择 0 个文件'), findsOneWidget);
    expect(find.byKey(CreatePageDialog.errorKey), findsNothing);
    await pickFiles(tester);
    expect(find.text('已选择 1 个文件'), findsOneWidget);
    await pickFiles(tester);
    expect(find.text('已选择 1 个文件'), findsOneWidget);
    expect(find.text('保留.txt'), findsOneWidget);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNotNull);

    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect((await harness.result!)!.$2, orderedEquals(files));
  });

  testWidgets('entitlement failure is visible inside dialog and can be retried',
      (tester) async {
    var calls = 0;
    final recovered = TestPlatformFile('重试成功.txt');
    final harness = await openDialog(tester, () async {
      if (++calls == 1) {
        throw PlatformException(code: 'ENTITLEMENT_NOT_FOUND');
      }
      return [recovered];
    });
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '重试');
    await pickFiles(tester);

    expect(find.byType(CreatePageDialog), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final error = find.byKey(CreatePageDialog.errorKey);
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).data, contains('ENTITLEMENT_NOT_FOUND'));
    expect(tester.widget<Text>(error).data, contains('文件访问权限'));
    expect(tester.widget<Text>(error).data, contains('重试'));
    expect(button(tester, CreatePageDialog.pickFilesKey).onPressed, isNotNull);
    expect(button(tester, CreatePageDialog.cancelKey).onPressed, isNotNull);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNull);

    await pickFiles(tester);
    expect(calls, 2);
    expect(find.byKey(CreatePageDialog.errorKey), findsNothing);
    expect(find.text('重试成功.txt'), findsOneWidget);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect((await harness.result!)!.$2.single, same(recovered));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'other picker failures are visible and do not clear prior selection',
      (tester) async {
    var calls = 0;
    final file = TestPlatformFile('仍然保留.txt');
    final harness = await openDialog(tester, () async {
      if (++calls == 1) return [file];
      throw StateError('picker unavailable');
    });
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '标题');
    await pickFiles(tester);
    await pickFiles(tester);

    expect(
      tester.widget<Text>(find.byKey(CreatePageDialog.errorKey)).data,
      contains('选择文件失败'),
    );
    expect(find.text('仍然保留.txt'), findsOneWidget);
    expect(find.text('已选择 1 个文件'), findsOneWidget);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNotNull);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect((await harness.result!)!.$2.single, same(file));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending picker shows progress and blocks duplicate/select/create/cancel',
      (tester) async {
    final pending = Completer<List<PlatformFile>>();
    var calls = 0;
    final first = TestPlatformFile('第一次.txt');
    final second = TestPlatformFile('第二次.txt');
    final harness = await openDialog(tester, () {
      calls++;
      return calls == 1 ? Future.value([first]) : pending.future;
    });
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '等待');
    await pickFiles(tester);
    final oldSubmit = button(tester, CreatePageDialog.submitKey).onPressed!;
    final oldCancel = button(tester, CreatePageDialog.cancelKey).onPressed!;
    final select = button(tester, CreatePageDialog.pickFilesKey).onPressed!;

    // Exercise guards before disabled button state has reached the next frame.
    select();
    select();
    oldSubmit();
    oldCancel();
    expect(calls, 2);
    await tester.pump();
    expect(find.byKey(CreatePageDialog.progressKey), findsOneWidget);
    expect(find.text('正在选择文件…'), findsOneWidget);
    for (final key in [
      CreatePageDialog.pickFilesKey,
      CreatePageDialog.submitKey,
      CreatePageDialog.cancelKey,
    ]) {
      expect(button(tester, key).onPressed, isNull);
      await tester.tap(find.byKey(key));
    }
    expect(calls, 2);
    expect(find.byType(CreatePageDialog), findsOneWidget);

    pending.complete([second]);
    await tester.pumpAndSettle();
    expect(find.byKey(CreatePageDialog.progressKey), findsNothing);
    expect(find.text('第二次.txt'), findsOneWidget);
    expect(find.text('第一次.txt'), findsNothing);
    expect(button(tester, CreatePageDialog.pickFilesKey).onPressed, isNotNull);
    expect(button(tester, CreatePageDialog.cancelKey).onPressed, isNotNull);
    expect(button(tester, CreatePageDialog.submitKey).onPressed, isNotNull);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect((await harness.result!)!.$2.single, same(second));
  });

  testWidgets('cancel returns null and controller survives exit animation',
      (tester) async {
    final harness = await openDialog(tester, () async => []);
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '取消');
    await tester.tap(find.byKey(CreatePageDialog.cancelKey));
    await tester.pump();
    expect(await harness.result!, isNull);
    // The route future resolves before its exit animation disposes the widget.
    expect(find.byType(CreatePageDialog, skipOffstage: false), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(CreatePageDialog.titleFieldKey, skipOffstage: false),
    );
    void listener() {}
    field.controller!.addListener(listener);
    field.controller!.removeListener(listener);
    await tester.pumpAndSettle();
    expect(find.byType(CreatePageDialog), findsNothing);
    expect(() => field.controller!.addListener(listener), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    testWidgets(
        'barrier dismissal while pending ignores late ${fails ? 'error' : 'success'}',
        (tester) async {
      final pending = Completer<List<PlatformFile>>();
      final harness = await openDialog(tester, () => pending.future);
      await tester.tap(find.byKey(CreatePageDialog.pickFilesKey));
      await tester.pump();
      expect(find.byKey(CreatePageDialog.progressKey), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(await harness.result!, isNull);
      expect(find.byType(CreatePageDialog), findsNothing);

      if (fails) {
        pending.completeError(PlatformException(code: 'ENTITLEMENT_NOT_FOUND'));
      } else {
        pending.complete([TestPlatformFile('已关闭.txt')]);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CreatePageDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });
  }
}
