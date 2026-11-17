// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/create_page_dialog.dart';

class DialogHarness {
  Future<String?>? result;
}

Future<DialogHarness> openDialog(WidgetTester tester) async {
  final harness = DialogHarness();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () {
                  harness.result = showDialog<String>(
                      context: context,
                      builder: (_) => const CreatePageDialog());
                },
                child: const Text('打开')))),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets(
      'name only creation requires nonblank text and returns trimmed name',
      (tester) async {
    final harness = await openDialog(tester);
    expect(find.text('新建传输'), findsOneWidget);
    expect(find.textContaining('文件可以稍后添加'), findsOneWidget);
    expect(find.text('选择文件（可多选）'), findsNothing);
    FilledButton submit() =>
        tester.widget(find.byKey(CreatePageDialog.submitKey));
    expect(submit().onPressed, isNull);
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '   ');
    await tester.pump();
    expect(submit().onPressed, isNull);
    await tester.enterText(
        find.byKey(CreatePageDialog.titleFieldKey), '  我的旅行  ');
    await tester.pump();
    expect(submit().onPressed, isNotNull);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect(await harness.result!, '我的旅行');
    expect(find.byType(CreatePageDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter submits a name without ever invoking a file picker',
      (tester) async {
    final harness = await openDialog(tester);
    await tester.enterText(
        find.byKey(CreatePageDialog.titleFieldKey), '  工作资料 ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await harness.result!, '工作资料');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter on whitespace does not submit', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(CreatePageDialog), findsOneWidget);
    await tester.tap(find.byKey(CreatePageDialog.cancelKey));
    await tester.pumpAndSettle();
  });

  testWidgets('name length is limited to 80 characters', (tester) async {
    final harness = await openDialog(tester);
    final text = List.filled(90, '旅').join();
    await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), text);
    await tester.pump();
    final field =
        tester.widget<TextField>(find.byKey(CreatePageDialog.titleFieldKey));
    expect(field.maxLength, 80);
    expect(field.controller!.text.length, 80);
    await tester.tap(find.byKey(CreatePageDialog.submitKey));
    await tester.pumpAndSettle();
    expect(await harness.result!, List.filled(80, '旅').join());
  });

  for (final barrier in [false, true]) {
    testWidgets(
        '${barrier ? 'barrier' : 'cancel'} dismissal retains controller through exit then disposes it',
        (tester) async {
      final harness = await openDialog(tester);
      await tester.enterText(find.byKey(CreatePageDialog.titleFieldKey), '取消');
      final field =
          tester.widget<TextField>(find.byKey(CreatePageDialog.titleFieldKey));
      if (barrier) {
        await tester.tapAt(const Offset(5, 5));
      } else {
        await tester.tap(find.byKey(CreatePageDialog.cancelKey));
      }
      await tester.pump();
      expect(await harness.result!, isNull);
      expect(
          find.byType(CreatePageDialog, skipOffstage: false), findsOneWidget);
      void listener() {}
      field.controller!.addListener(listener);
      field.controller!.removeListener(listener);
      await tester.pumpAndSettle();
      expect(find.byType(CreatePageDialog), findsNothing);
      expect(() => field.controller!.addListener(listener), throwsFlutterError);
      expect(tester.takeException(), isNull);
    });
  }
}
