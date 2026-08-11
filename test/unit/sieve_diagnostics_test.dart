import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sieve/sieve_diagnostics.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';

void main() {
  group('fileIntoTargets', () {
    test('collects every fileinto folder in document order', () {
      final rules = SieveParser().parse('''
require ["fileinto"];
if header :contains "subject" "invoice" {
  fileinto "Invoices";
}
if header :contains "from" "boss@example.com" {
  fileinto "Work";
}
''');
      expect(fileIntoTargets(rules), ['Invoices', 'Work']);
    });

    test('is empty when no fileinto action is present', () {
      final rules = SieveParser().parse('keep;\n');
      expect(fileIntoTargets(rules), isEmpty);
    });
  });

  group('diagnoseSieve', () {
    test('flags an inactive script', () {
      final findings = diagnoseSieve(
        scriptIsActive: false,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const {'Work'},
        inboxMatchCount: 3,
      );
      expect(findings, hasLength(1));
      expect(findings.single.level, SieveFindingLevel.warning);
      expect(findings.single.message, contains('not active'));
    });

    test('flags a missing target folder', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const {'Inbox'},
        inboxMatchCount: 3,
      );
      expect(
        findings.where((f) => f.message.contains('"Work"')),
        hasLength(1),
      );
    });

    test('does not repeat the same missing folder twice', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Work', 'Work'],
        existingFolderPaths: const <String>{},
        inboxMatchCount: 3,
      );
      expect(
        findings.where((f) => f.message.contains('"Work"')),
        hasLength(1),
      );
    });

    test('flags zero inbox matches', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const {'Work'},
        inboxMatchCount: 0,
      );
      expect(
        findings.where((f) => f.message.contains('match this filter')),
        hasLength(1),
      );
    });

    test('reports an all-clear when nothing local is wrong', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const {'Work'},
        inboxMatchCount: 2,
      );
      expect(findings, hasLength(1));
      expect(findings.single.level, SieveFindingLevel.ok);
      expect(findings.single.message, contains('only visible in its logs'));
    });

    test('accumulates several problems at once', () {
      final findings = diagnoseSieve(
        scriptIsActive: false,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const <String>{},
        inboxMatchCount: 0,
      );
      expect(findings, hasLength(3));
      expect(
        findings.every((f) => f.level == SieveFindingLevel.warning),
        isTrue,
      );
    });
  });
}
