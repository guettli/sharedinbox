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

    test('warns about a Delivered-To filter and suggests envelope (#701)', () {
      final rules = SieveParser().parse(
        'if header :is "Delivered-To" "postmaster@example.com" '
        '{ fileinto "postmaster"; }',
      );
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['postmaster'],
        existingFolderPaths: const {'postmaster'},
        inboxMatchCount: 0,
        rules: rules,
      );
      final delivery = findings.where(
        (f) => f.message.contains('Delivered-To'),
      );
      expect(delivery, hasLength(1));
      expect(delivery.single.message, contains('envelope'));
      // The misleading generic "no messages match" warning is suppressed.
      expect(
        findings.where((f) => f.message.contains('nothing to move yet')),
        isEmpty,
      );
    });

    test('does not claim zero matches for an unreadable header', () {
      final rules = SieveParser().parse(
        'if header :contains "X-Spam-Flag" "YES" { fileinto "Junk"; }',
      );
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Junk'],
        existingFolderPaths: const {'Junk'},
        inboxMatchCount: 0,
        rules: rules,
      );
      expect(
        findings.where((f) => f.message.contains('not meaningful')),
        hasLength(1),
      );
      expect(
        findings.where((f) => f.message.contains('nothing to move yet')),
        isEmpty,
      );
    });

    test('still reports zero matches for a filter it can evaluate', () {
      final rules = SieveParser().parse(
        'if header :contains "subject" "invoice" { fileinto "Invoices"; }',
      );
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['Invoices'],
        existingFolderPaths: const {'Invoices'},
        inboxMatchCount: 0,
        rules: rules,
      );
      expect(
        findings.where((f) => f.message.contains('nothing to move yet')),
        hasLength(1),
      );
    });

    test('address recipient test is treated as evaluable', () {
      final rules = SieveParser().parse(
        'if address :is "to" "postmaster@example.com" '
        '{ fileinto "postmaster"; }',
      );
      final findings = diagnoseSieve(
        scriptIsActive: true,
        fileIntoTargets: const ['postmaster'],
        existingFolderPaths: const {'postmaster'},
        inboxMatchCount: 0,
        rules: rules,
      );
      // No "cannot read" note — the preview can derive the To address.
      expect(
        findings.where((f) => f.message.contains('cannot read')),
        isEmpty,
      );
      // And a genuine zero count is reported normally.
      expect(
        findings.where((f) => f.message.contains('nothing to move yet')),
        hasLength(1),
      );
    });
  });
}
