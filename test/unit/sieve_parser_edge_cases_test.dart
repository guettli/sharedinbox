import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';

SieveEmailContext _email({
  String subject = '',
  String from = '',
  String to = '',
  int size = 0,
  Map<String, List<String>> extra = const {},
}) {
  return SieveEmailContext(
    headers: {
      if (subject.isNotEmpty) 'subject': [subject],
      if (from.isNotEmpty) 'from': [from],
      if (to.isNotEmpty) 'to': [to],
      ...extra,
    },
    sizeBytes: size,
  );
}

void main() {
  final parser = SieveParser();
  final interp = SieveInterpreter();

  SieveExecutionContext run(String script, SieveEmailContext email) {
    return interp.execute(parser.parse(script), email);
  }

  group('SieveParser — quoted string escapes', () {
    test('escaped double-quote produces a literal quote in the key', () {
      // Script: if header :is "Subject" "say \"hi\"" { discard; }
      const script = '''
if header :is "Subject" "say \\"hi\\"" {
  discard;
}
''';
      var ctx = run(script, _email(subject: 'say "hi"'));
      expect(ctx.isCancelled, isTrue);

      ctx = run(script, _email(subject: 'say hi'));
      expect(ctx.isCancelled, isFalse);
    });

    test('escaped backslash produces a single literal backslash', () {
      // Script: if header :is "Subject" "a\\b" { discard; }
      const script = '''
if header :is "Subject" "a\\\\b" {
  discard;
}
''';
      var ctx = run(script, _email(subject: r'a\b'));
      expect(ctx.isCancelled, isTrue);

      ctx = run(script, _email(subject: 'ab'));
      expect(ctx.isCancelled, isFalse);
    });

    test('unknown escape sequence strips the backslash and keeps next char',
        () {
      // Script: if header :is "Subject" "a\nb" { discard; }
      // Parser current behavior: "\n" becomes literal "n", not a newline.
      const script = '''
if header :is "Subject" "a\\nb" {
  discard;
}
''';
      var ctx = run(script, _email(subject: 'anb'));
      expect(ctx.isCancelled, isTrue);

      ctx = run(script, _email(subject: 'a\nb'));
      expect(ctx.isCancelled, isFalse);
    });

    test('empty key under :contains matches any header value', () {
      const script = '''
if header :contains "Subject" "" {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'anything'));
      expect(ctx.isCancelled, isTrue);
    });

    test('unterminated quoted string throws SieveParseException', () {
      const script = '''
if header :contains "Subject" "oops
{ discard; }
''';
      expect(() => parser.parse(script), throwsA(isA<SieveParseException>()));
    });
  });

  group('SieveParser — :matches glob', () {
    test('? matches exactly one character', () {
      const script = '''
if header :matches "Subject" "foo?bar" {
  fileinto "Match";
}
''';
      var ctx = run(script, _email(subject: 'foo-bar'));
      expect(ctx.targetFolders, contains('Match'));

      // No char between foo and bar — should not match.
      ctx = run(script, _email(subject: 'foobar'));
      expect(ctx.targetFolders, isEmpty);
    });

    test('mixed prefix/glob/suffix pattern', () {
      const script = '''
if header :matches "Subject" "prefix-*-suffix" {
  fileinto "Match";
}
''';
      var ctx = run(script, _email(subject: 'prefix-foo-suffix'));
      expect(ctx.targetFolders, contains('Match'));

      ctx = run(script, _email(subject: 'prefix-suffix'));
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — not test (best-effort behavior)', () {
    // The flat rule model does not represent negation; `_parseSingleTest`
    // currently returns the inner condition unchanged. This test pins the
    // current best-effort behavior so a real-negation implementation surfaces
    // as an intentional change.
    test('not is parsed but does not actually negate', () {
      const script = '''
if not header :contains "Subject" "spam" {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'this is spam'));
      expect(ctx.isCancelled, isTrue);
    });
  });

  group('SieveParser — nested anyof/allof', () {
    // Current behavior: an inner test list inside `anyof`/`allof` is flattened
    // into the outer join, and the inner join type is dropped. So the outer
    // `allof(anyof(a,b), c)` collapses to `allof(a, b, c)`.
    test('nested join types are flattened; inner join type is dropped', () {
      const script = '''
if allof (
  anyof (
    header :contains "Subject" "foo",
    header :contains "Subject" "bar"
  ),
  header :contains "From" "baz"
) {
  fileinto "Nested";
}
''';
      // All three conditions present → rule fires.
      var ctx = run(
        script,
        _email(subject: 'foo and bar', from: 'baz@example.com'),
      );
      expect(ctx.targetFolders, contains('Nested'));

      // Only two of the three present → does not fire (flattened allof).
      ctx = run(
        script,
        _email(subject: 'foo', from: 'baz@example.com'),
      );
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — size suffixes', () {
    test(':over with M suffix', () {
      const script = '''
if size :over 1M {
  fileinto "Big";
}
''';
      var ctx = run(script, _email(size: 2 * 1024 * 1024));
      expect(ctx.targetFolders, contains('Big'));

      ctx = run(script, _email(size: 512 * 1024));
      expect(ctx.targetFolders, isEmpty);
    });

    test(':over with G suffix', () {
      const script = '''
if size :over 1G {
  fileinto "Huge";
}
''';
      final ctx = run(script, _email(size: 2 * 1024 * 1024 * 1024));
      expect(ctx.targetFolders, contains('Huge'));
    });

    test(':over with no suffix is interpreted as bytes', () {
      const script = '''
if size :over 1024 {
  fileinto "OverBytes";
}
''';
      var ctx = run(script, _email(size: 2048));
      expect(ctx.targetFolders, contains('OverBytes'));

      // Equal to threshold is NOT "over".
      ctx = run(script, _email(size: 1024));
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — unknown/unsupported commands', () {
    test('unknown top-level command produces no rules and does not throw', () {
      const script = '''
redirect "ignored@example.com";
''';
      expect(() => parser.parse(script), returnsNormally);
      expect(parser.parse(script), isEmpty);
    });

    test('unknown command between valid ifs does not break parsing', () {
      const script = '''
if header :contains "Subject" "alpha" {
  fileinto "A";
}
redirect "ignored@example.com";
if header :contains "Subject" "beta" {
  fileinto "B";
}
''';
      final rules = parser.parse(script);
      // Two `if` blocks → two rules.
      expect(rules, hasLength(2));

      var ctx = run(script, _email(subject: 'alpha'));
      expect(ctx.targetFolders, contains('A'));

      ctx = run(script, _email(subject: 'beta'));
      expect(ctx.targetFolders, contains('B'));
    });

    test('vacation command with multiple args is skipped silently', () {
      const script = '''
vacation :days 7 "out of office";
if header :contains "Subject" "ping" {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'ping'));
      expect(ctx.isCancelled, isTrue);
    });
  });

  group('SieveParser — comments in odd positions', () {
    test('block comment between :contains and the header list', () {
      const script = '''
if header :contains /* between tag and header */ "Subject" "spam" {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'spam'));
      expect(ctx.isCancelled, isTrue);
    });

    test('line comment immediately before closing brace', () {
      const script = '''
if header :contains "Subject" "spam" {
  discard;
  # trailing
}
''';
      final ctx = run(script, _email(subject: 'spam'));
      expect(ctx.isCancelled, isTrue);
    });

    test('multi-line block comment inside an if body', () {
      const script = '''
if header :contains "Subject" "spam" {
  /*
   * Multi-line
   * comment.
   */
  discard;
}
''';
      final ctx = run(script, _email(subject: 'spam'));
      expect(ctx.isCancelled, isTrue);
    });
  });

  group('SieveParser — exists with multiple headers', () {
    test('matches when any of the listed headers is present', () {
      const script = '''
if exists ["X-Marketing", "X-Spam-Flag"] {
  discard;
}
''';
      const email = SieveEmailContext(
        headers: {
          'x-spam-flag': ['YES'],
        },
      );
      final ctx = interp.execute(parser.parse(script), email);
      expect(ctx.isCancelled, isTrue);
    });

    test('does not match when none of the listed headers are present', () {
      const script = '''
if exists ["X-Marketing", "X-Spam-Flag"] {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'hello'));
      expect(ctx.isCancelled, isFalse);
    });
  });

  group('SieveParser — header lookup is case-insensitive', () {
    test('uppercase FROM in script resolves to lowercased from header', () {
      const script = '''
if header :is "FROM" "alice@example.com" {
  fileinto "FromAlice";
}
''';
      final ctx = run(script, _email(from: 'alice@example.com'));
      expect(ctx.targetFolders, contains('FromAlice'));
    });
  });

  group('SieveParser — default match type', () {
    test('header test without a match-type tag defaults to :is', () {
      const script = '''
if header "Subject" "exact" {
  fileinto "Exact";
}
''';
      var ctx = run(script, _email(subject: 'exact'));
      expect(ctx.targetFolders, contains('Exact'));

      // Not an exact match → no fire (rules out :contains fallback).
      ctx = run(script, _email(subject: 'exactly'));
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — multiple require statements', () {
    test('two require lines back-to-back produce no rules', () {
      const script = '''
require ["fileinto"];
require ["imap4flags"];
''';
      expect(parser.parse(script), isEmpty);
    });

    test('require with a single string (non-list form) is accepted', () {
      const script = '''
require "fileinto";
''';
      expect(() => parser.parse(script), returnsNormally);
      expect(parser.parse(script), isEmpty);
    });
  });
}
