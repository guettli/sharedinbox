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
        rules: const [],
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
        rules: const [],
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
        rules: const [],
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
        rules: SieveParser().parse(
          'if header :contains "subject" "x" { fileinto "Work"; }',
        ),
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
        rules: const [],
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
        rules: SieveParser().parse(
          'if header :contains "subject" "x" { fileinto "Work"; }',
        ),
      );
      expect(findings, hasLength(3));
      expect(
        findings.every((f) => f.level == SieveFindingLevel.warning),
        isTrue,
      );
    });

    test('warns that a Delivered-To header test is unreliable server-side', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['postmaster'],
        existingFolderPaths: const {'postmaster'},
        inboxMatchCount: 0,
        rules: SieveParser().parse(
          'if header :is "Delivered-To" "postmaster@thomas-guettler.de" '
          '{ fileinto "postmaster"; }',
        ),
      );
      final warning = findings.firstWhere(
        (f) => f.message.contains('delivering the message'),
      );
      expect(warning.level, SieveFindingLevel.warning);
      expect(warning.message, contains('"delivered-to"'));
      expect(warning.message, contains('envelope :is "to"'));
    });

    test('explains a 0 count for a header the preview cannot read', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['postmaster'],
        existingFolderPaths: const {'postmaster'},
        inboxMatchCount: 0,
        rules: SieveParser().parse(
          'if header :is "Delivered-To" "x@y" { fileinto "postmaster"; }',
        ),
      );
      // The misleading "nothing matches" finding must NOT be produced.
      expect(
        findings.where((f) => f.message.contains('match this filter')),
        isEmpty,
      );
      expect(
        findings.where((f) => f.message.contains('preview cannot read')),
        hasLength(1),
      );
    });

    test('does not warn about delivery headers when using envelope', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['postmaster'],
        existingFolderPaths: const {'postmaster'},
        inboxMatchCount: 1,
        rules: SieveParser().parse(
          'require ["fileinto", "envelope"];\n'
          'if envelope :is "to" "postmaster@x" { fileinto "postmaster"; }',
        ),
      );
      expect(findings, hasLength(1));
      expect(findings.single.level, SieveFindingLevel.ok);
    });

    test('a 0 count over a previewable header still reads as no match', () {
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Work'],
        existingFolderPaths: const {'Work'},
        inboxMatchCount: 0,
        rules: SieveParser().parse(
          'if header :contains "subject" "invoice" { fileinto "Work"; }',
        ),
      );
      expect(
        findings.where((f) => f.message.contains('match this filter')),
        hasLength(1),
      );
    });
  });
}
