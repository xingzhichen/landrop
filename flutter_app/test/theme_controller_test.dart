// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/app_theme.dart';
import 'package:landrop/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Models the legacy plugin's optimistic cache, separate from durable storage.
class _Preferences extends Fake implements SharedPreferences {
  Object? stored;
  Object? cached;
  Completer<void>? writeGate;
  Completer<void>? readGate;
  bool failWrite = false;
  bool throwWrite = false;
  final writes = <String>[];

  @override
  Object? get(String key) => cached;

  @override
  Future<void> reload() async {
    await readGate?.future;
    cached = stored;
  }

  @override
  Future<bool> setString(String key, String value) async {
    expect(key, ThemeController.preferenceKey);
    cached = value;
    writes.add(value);
    await writeGate?.future;
    if (throwWrite) throw StateError('Storage unavailable');
    if (failWrite) return false;
    stored = value;
    return true;
  }
}

Widget _app(ThemeController controller) => AnimatedBuilder(
      animation: controller,
      builder: (context, child) => MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: controller.mode,
        home: Builder(builder: (context) {
          final colors = AppTheme.colorsOf(context);
          return Scaffold(
            body: Column(children: [
              Text(Theme.of(context).brightness.name),
              ColoredBox(
                key: const ValueKey('semantic-surface'),
                color: colors.surface,
                child: const FileTypeIcon(name: 'report.pdf'),
              ),
            ]),
          );
        }),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default is system, absent and invalid preferences remain system',
      () async {
    for (final stored in [null, 'unknown', 42]) {
      SharedPreferences.setMockInitialValues({
        if (stored != null) ThemeController.preferenceKey: stored,
      });
      final controller = ThemeController();
      addTearDown(controller.dispose);
      expect(controller.mode, ThemeMode.system);
      await controller.initialize();
      expect(controller.mode, ThemeMode.system);
    }
  });

  for (final mode in ThemeMode.values) {
    test('restores the saved ${mode.name} preference', () async {
      SharedPreferences.setMockInitialValues({
        ThemeController.preferenceKey: mode.name,
      });
      final controller = ThemeController();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.mode, mode);
    });
  }

  test('changes persist and restore on controller restart, including system',
      () async {
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await controller.initialize();
    var notifications = 0;
    controller.addListener(() => notifications++);
    for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
      await controller.setMode(mode);
      expect(controller.mode, mode);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(ThemeController.preferenceKey), mode.name);
      final restarted = ThemeController();
      await restarted.initialize();
      expect(restarted.mode, mode);
      restarted.dispose();
    }
    expect(notifications, 3);
  });

  test('repeated initialize cannot overwrite a manual choice', () async {
    final preferences = _Preferences()..stored = 'dark';
    final controller =
        ThemeController(preferencesLoader: () async => preferences);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.setMode(ThemeMode.light);
    preferences.stored = 'dark';
    await Future.wait([controller.initialize(), controller.initialize()]);
    expect(controller.mode, ThemeMode.light);
  });

  test('a manual choice made before initialization is never overwritten',
      () async {
    final controller = ThemeController();
    addTearDown(controller.dispose);
    final save = controller.setMode(ThemeMode.dark);
    final initialize = controller.initialize();
    await Future.wait([save, initialize]);
    expect(controller.mode, ThemeMode.dark);
  });

  test('initialization and a concurrent choice are serialized', () async {
    final gate = Completer<void>();
    final preferences = _Preferences()
      ..stored = 'dark'
      ..readGate = gate;
    final controller =
        ThemeController(preferencesLoader: () async => preferences);
    addTearDown(controller.dispose);
    final initialize = controller.initialize();
    final save = controller.setMode(ThemeMode.light);
    await Future<void>.delayed(Duration.zero);
    expect(preferences.writes, isEmpty);
    gate.complete();
    await Future.wait([initialize, save]);
    expect(controller.mode, ThemeMode.light);
    expect(preferences.stored, 'light');
    await controller.initialize();
    expect(controller.mode, ThemeMode.light);
  });

  test('rapid changes commit in request order and notify only after saving',
      () async {
    final gate = Completer<void>();
    final preferences = _Preferences()..writeGate = gate;
    final controller =
        ThemeController(preferencesLoader: () async => preferences);
    addTearDown(controller.dispose);
    final announced = <ThemeMode>[];
    controller.addListener(() => announced.add(controller.mode));
    final dark = controller.setMode(ThemeMode.dark);
    final light = controller.setMode(ThemeMode.light);
    final system = controller.setMode(ThemeMode.system);
    await Future<void>.delayed(Duration.zero);
    expect(preferences.writes, ['dark']);
    expect(controller.mode, ThemeMode.system);
    expect(announced, isEmpty);
    gate.complete();
    await Future.wait([dark, light, system]);
    expect(preferences.writes, ['dark', 'light', 'system']);
    expect(announced, [ThemeMode.dark, ThemeMode.light, ThemeMode.system]);
    expect(controller.mode, ThemeMode.system);
    expect(preferences.stored, 'system');
  });

  for (final throws in [false, true]) {
    test(
        'storage ${throws ? 'exception' : 'false'} is exposed without false save',
        () async {
      final preferences = _Preferences()..stored = 'light';
      final controller =
          ThemeController(preferencesLoader: () async => preferences);
      addTearDown(controller.dispose);
      await controller.initialize();
      var notifications = 0;
      controller.addListener(() => notifications++);
      preferences.failWrite = !throws;
      preferences.throwWrite = throws;
      await expectLater(controller.setMode(ThemeMode.dark), throwsStateError);
      expect(controller.mode, ThemeMode.light);
      expect(preferences.stored, 'light');
      expect(preferences.cached, 'light');
      expect(notifications, 0);
      final restarted =
          ThemeController(preferencesLoader: () async => preferences);
      await restarted.initialize();
      expect(restarted.mode, ThemeMode.light);
      restarted.dispose();
      preferences.failWrite = false;
      preferences.throwWrite = false;
      await controller.setMode(ThemeMode.dark);
      expect(controller.mode, ThemeMode.dark);
      expect(notifications, 1);
    });
  }

  test('failed initialization can be retried', () async {
    var fail = true;
    final preferences = _Preferences()..stored = 'dark';
    final controller = ThemeController(preferencesLoader: () async {
      if (fail) throw StateError('Read failed');
      return preferences;
    });
    addTearDown(controller.dispose);
    await expectLater(controller.initialize(), throwsStateError);
    expect(controller.mode, ThemeMode.system);
    fail = false;
    await controller.initialize();
    expect(controller.mode, ThemeMode.dark);
  });

  testWidgets('default, restored choice and changed choice survive app restart',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final first = ThemeController();
    addTearDown(first.dispose);
    await first.initialize();
    await tester.pumpWidget(_app(first));
    expect(first.mode, ThemeMode.system);
    expect(find.text('light'), findsOneWidget);
    await first.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final restarted = ThemeController();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    await tester.pumpWidget(_app(restarted));
    expect(restarted.mode, ThemeMode.dark);
    expect(find.text('dark'), findsOneWidget);
    await restarted.setMode(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final restartedAgain = ThemeController();
    addTearDown(restartedAgain.dispose);
    await restartedAgain.initialize();
    await tester.pumpWidget(_app(restartedAgain));
    expect(restartedAgain.mode, ThemeMode.light);
    expect(find.text('light'), findsOneWidget);
  });

  testWidgets(
      'rapid changes leave rendered and persisted mode in request order',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await Future.wait([
      controller.setMode(ThemeMode.dark),
      controller.setMode(ThemeMode.light),
      controller.setMode(ThemeMode.system),
      controller.setMode(ThemeMode.dark),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    expect(controller.mode, ThemeMode.dark);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(ThemeController.preferenceKey), 'dark');
  });

  testWidgets(
      'system mode follows live platform brightness, never snapshots it',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(_app(controller));
    expect(find.text('light'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    expect(controller.mode, ThemeMode.system);
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('semantic-surface')))
          .color,
      AppTheme.darkColors.surface,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey(ThemeController.preferenceKey), isFalse);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);
  });

  testWidgets('explicit mode ignores system until system is selected again',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final controller = ThemeController();
    addTearDown(controller.dispose);
    await controller.setMode(ThemeMode.dark);
    await tester.pumpWidget(_app(controller));
    expect(find.text('dark'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    await controller.setMode(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    expect(controller.mode, ThemeMode.system);
  });

  testWidgets('file icons brighten and use stronger backgrounds in dark mode',
      (tester) async {
    for (final name in [
      'photo.jpg',
      'report.pdf',
      'bundle.zip',
      'movie.mp4',
      'audio.mp3',
      'sheet.xlsx',
      'notes.docx',
      'unknown.bin',
    ]) {
      Future<(Color, Color)> sample(ThemeData theme) async {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: FileTypeIcon(name: name),
        ));
        await tester.pumpAndSettle();
        final icon = tester.widget<Icon>(find.byType(Icon));
        final container = tester.widget<Container>(
          find.descendant(
              of: find.byType(FileTypeIcon), matching: find.byType(Container)),
        );
        return (icon.color!, (container.decoration! as BoxDecoration).color!);
      }

      final (lightIcon, lightBackground) = await sample(AppTheme.light);
      final (darkIcon, darkBackground) = await sample(AppTheme.dark);
      expect(darkIcon.computeLuminance(),
          greaterThan(lightIcon.computeLuminance()),
          reason: name);
      expect(darkBackground.a, greaterThan(lightBackground.a), reason: name);
      final composed =
          Color.alphaBlend(darkBackground, AppTheme.darkColors.surface);
      expect(_contrast(darkIcon, composed), greaterThan(4.5), reason: name);
    }
  });

  test('semantic tokens and component colours have readable contrast', () {
    expect(AppTheme.lightColors.background, AppTheme.background);
    expect(AppTheme.lightColors.surface, AppTheme.surface);
    expect(AppTheme.lightColors.ink, AppTheme.ink);
    expect(AppTheme.lightColors.primary, AppTheme.primary);
    expect(AppTheme.lightColors.muted, AppTheme.muted);
    expect(AppTheme.lightColors.border, AppTheme.border);
    expect(AppTheme.lightColors.primaryTint, AppTheme.primaryTint);
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final colors = theme.extension<AppColors>()!;
      for (final background in [colors.background, colors.surface]) {
        expect(_contrast(colors.ink, background), greaterThan(4.5));
        expect(_contrast(colors.muted, background), greaterThan(4.5));
        expect(_contrast(colors.primary, background), greaterThan(4.5));
      }
      expect(_contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
          greaterThan(4.5));
      expect(theme.cardTheme.color, colors.surface);
      expect(theme.dialogTheme.backgroundColor, colors.surface);
      expect(theme.inputDecorationTheme.fillColor, colors.background);
      expect(theme.tooltipTheme.textStyle!.color, colors.surface);
      expect(theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
          colors.primary);
    }
    final midpoint = AppTheme.lightColors.lerp(AppTheme.darkColors, 0.5);
    expect(midpoint.surface,
        Color.lerp(AppTheme.surface, AppTheme.darkColors.surface, 0.5));
    expect(AppTheme.lightColors.copyWith(ink: Colors.red).ink, Colors.red);
  });
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}
