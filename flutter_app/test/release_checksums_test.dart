import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('documented Windows checksum command is smoke-tested in CI', () {
    final readme =
        File('../README.md').readAsStringSync().replaceAll('\r\n', '\n');
    final workflow = File('../.github/workflows/build-desktop.yml')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final snippetMatch = RegExp(
      r'```powershell\n(.*?)\n```',
      dotAll: true,
    ).firstMatch(readme);
    expect(snippetMatch, isNotNull);
    final documentedSnippet = snippetMatch!.group(1)!;

    const stepHeading =
        '- name: Smoke-test documented Windows checksum instructions';
    final stepStart = workflow.indexOf(stepHeading);
    expect(stepStart, isNonNegative);
    final nextStep =
        workflow.indexOf('\n      - name:', stepStart + stepHeading.length);
    final workflowStep = workflow.substring(
      stepStart,
      nextStep == -1 ? workflow.length : nextStep,
    );
    final normalizedSnippet =
        documentedSnippet.split('\n').map((line) => line.trim()).join('\n');
    final normalizedStep =
        workflowStep.split('\n').map((line) => line.trim()).join('\n');

    expect(workflowStep, contains('shell: pwsh'));
    expect(normalizedStep, contains(normalizedSnippet));
    expect(
      workflowStep,
      contains("Checksum verifier accepted an incorrect hash"),
    );
    expect(
      workflowStep,
      contains('Checksum verifier accepted duplicate entries'),
    );
    expect(
      workflowStep,
      contains('Checksum verifier accepted a missing entry'),
    );
    expect(
      workflowStep,
      contains('Remove-Item -LiteralPath \$manifestPath -Force'),
    );
    expect(workflow, contains('name: LanDrop-SHA256SUMS'));
    expect(readme, contains('LanDrop-SHA256SUMS'));
  });
}
