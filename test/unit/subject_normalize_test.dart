import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/subject_normalize.dart';

void main() {
  group('normalizedSubject', () {
    test('returns empty for null', () {
      expect(normalizedSubject(null), '');
    });

    test('returns empty for whitespace-only', () {
      expect(normalizedSubject('   '), '');
    });

    test('lowercases and trims', () {
      expect(normalizedSubject('  Hello World  '), 'hello world');
    });

    test('strips a single Re: prefix', () {
      expect(normalizedSubject('Re: payment overdue'), 'payment overdue');
    });

    test('strips Re:, Fwd:, AW:, WG: case-insensitively', () {
      expect(normalizedSubject('RE: x'), 'x');
      expect(normalizedSubject('re: x'), 'x');
      expect(normalizedSubject('Fwd: x'), 'x');
      expect(normalizedSubject('Fw: x'), 'x');
      expect(normalizedSubject('AW: x'), 'x');
      expect(normalizedSubject('aw: x'), 'x');
      expect(normalizedSubject('WG: x'), 'x');
      expect(normalizedSubject('wg: x'), 'x');
    });

    test('strips stacked Re: Re: Fwd: prefixes', () {
      expect(
        normalizedSubject('Re: Re: Fwd: meeting notes'),
        'meeting notes',
      );
      expect(
        normalizedSubject('AW: WG: re: project update'),
        'project update',
      );
    });

    test('strips ticket-style #1234 tokens', () {
      expect(
        normalizedSubject('Bug #1234 — login broken'),
        'bug — login broken',
      );
    });

    test('strips bracketed and parenthesised tokens', () {
      expect(
        normalizedSubject('[ticket-42] payment overdue'),
        'payment overdue',
      );
      expect(
        normalizedSubject('payment (urgent) overdue'),
        'payment overdue',
      );
    });

    test('collapses interior whitespace', () {
      expect(normalizedSubject('hello   world\t\nfoo'), 'hello world foo');
    });

    test('two subjects with different ticket ids normalise the same', () {
      expect(
        normalizedSubject('Re: [TKT-100] Server down'),
        normalizedSubject('Fwd: [TKT-999] Server down'),
      );
    });
  });
}
