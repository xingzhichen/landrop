import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final configuration in ['Release', 'DebugProfile']) {
    test('$configuration declares file picker read permission', () {
      final plist =
          File('macos/Runner/$configuration.entitlements').readAsStringSync();
      expect(
        RegExp(r'<key>com\.apple\.security\.files\.user-selected\.read-only</key>\s*<true\s*/>')
            .hasMatch(plist),
        isTrue,
        reason:
            'file_picker_darwin checks user-selected entitlements even without App Sandbox',
      );
    });
  }

  test('CI packages with explicit entitlements and verifies the signed app',
      () {
    final workflow =
        File('../.github/workflows/build-desktop.yml').readAsStringSync();
    final script = File('tool/package_macos.sh').readAsStringSync();
    expect(workflow, contains('bash tool/package_macos.sh'));
    expect(script, contains('--entitlements "\$ENTITLEMENTS"'));
    expect(script, contains('codesign -d --entitlements :-'));
    expect(
        script, contains('com.apple.security.files.user-selected.read-only'));
    expect(script, contains('codesign --verify --deep --strict'));
  });
}
