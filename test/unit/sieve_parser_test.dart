import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';

SieveEmailContext _email({
  String subject = '',
  String from = '',
  String to = '',
  int size = 0,
}) {
  return SieveEmailContext(
    headers: {
      if (subject.isNotEmpty) 'subject': [subject],
      if (from.isNotEmpty) 'from': [from],
      if (to.isNotEmpty) 'to': [to],
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

  group('SieveParser — require', () {
    test('require is parsed without error', () {
      expect(
        () => parser.parse('require ["fileinto", "imap4flags"];'),
        returnsNormally,
      );
    });

    test('require produces no rules', () {
      final rules = parser.parse('require ["fileinto"];');
      expect(rules, isEmpty);
    });
  });

  group('SieveParser — basic if/discard', () {
    test('discard on subject :contains', () {
      const script = '''
require ["fileinto"];
if header :contains "Subject" "Spam" {
  discard;
}
''';
      var ctx = run(script, _email(subject: 'This is Spam!'));
      expect(ctx.isCancelled, isTrue);

      ctx = run(script, _email(subject: 'Hello'));
      expect(ctx.isCancelled, isFalse);
    });
  });

  group('SieveParser — fileinto + flag', () {
    test('flag and fileinto on :is match across multiple headers', () {
      const script = '''
require ["fileinto", "imap4flags"];
if header :is ["From", "Reply-To"] "boss@work.com" {
  flag ["\\\\Important"];
  fileinto "Work";
}
''';
      final ctx = run(script, _email(from: 'boss@work.com'));
      expect(ctx.targetFolders, contains('Work'));
      expect(ctx.keepInInbox, isFalse);
    });

    test('no match means inbox is kept', () {
      const script = '''
if header :is "From" "boss@work.com" {
  fileinto "Work";
}
''';
      final ctx = run(script, _email(from: 'other@example.com'));
      expect(ctx.targetFolders, isEmpty);
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('SieveParser — anyof', () {
    test('anyof fires when any sub-condition matches', () {
      const script = '''
if anyof (
  header :contains "Subject" "Newsletter",
  header :contains "Subject" "Promotion"
) {
  fileinto "Bulk";
}
''';
      var ctx = run(script, _email(subject: 'Weekly Newsletter'));
      expect(ctx.targetFolders, contains('Bulk'));

      ctx = run(script, _email(subject: 'Big Promotion Inside'));
      expect(ctx.targetFolders, contains('Bulk'));

      ctx = run(script, _email(subject: 'Normal message'));
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — allof', () {
    test('allof fires only when all conditions match', () {
      const script = '''
if allof (
  header :contains "From" "shop.com",
  header :contains "Subject" "deal"
) {
  fileinto "Deals";
}
''';
      var ctx = run(
        script,
        _email(from: 'offers@shop.com', subject: 'Hot deal today'),
      );
      expect(ctx.targetFolders, contains('Deals'));

      ctx = run(
        script,
        _email(from: 'friend@example.com', subject: 'Hot deal today'),
      );
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('SieveParser — size condition', () {
    test(':over with K suffix', () {
      const script = '''
if size :over 100K {
  fileinto "Large";
}
''';
      var ctx = run(script, _email(size: 200 * 1024));
      expect(ctx.targetFolders, contains('Large'));

      ctx = run(script, _email(size: 50 * 1024));
      expect(ctx.targetFolders, isEmpty);
    });

    test(':under fires for small messages', () {
      const script = '''
if size :under 1K {
  fileinto "Tiny";
}
''';
      final ctx = run(script, _email(size: 500));
      expect(ctx.targetFolders, contains('Tiny'));
    });
  });

  group('SieveParser — if/elsif/else', () {
    const script = '''
if header :contains "Subject" "Spam" {
  discard;
} elsif header :contains "Subject" "Work" {
  fileinto "Work";
} else {
  keep;
}
''';

    test('if branch fires', () {
      final ctx = run(script, _email(subject: 'Spam message'));
      expect(ctx.isCancelled, isTrue);
    });

    test('elsif branch fires when if does not match', () {
      final ctx = run(script, _email(subject: 'Work update'));
      expect(ctx.isCancelled, isFalse);
      expect(ctx.targetFolders, contains('Work'));
    });

    test('else branch fires when no condition matched', () {
      final ctx = run(script, _email(subject: 'Hello'));
      expect(ctx.isCancelled, isFalse);
      expect(ctx.targetFolders, isEmpty);
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('SieveParser — multiple independent if blocks', () {
    test('both fire independently', () {
      const script = '''
if header :contains "Subject" "invoice" {
  fileinto "Finance";
}
if header :contains "From" "boss@" {
  flag ["\\\\Important"];
}
''';
      final ctx = run(
        script,
        _email(subject: 'Invoice #42', from: 'boss@corp.com'),
      );
      expect(ctx.targetFolders, contains('Finance'));
      expect(ctx.flagsToAdd, contains(r'\Important'));
    });
  });

  group('SieveParser — setflag', () {
    test('setflag \\Flagged is parsed as StarMessageAction', () {
      const script = r'''
require ["imap4flags"];
if header :contains "Subject" "hi" {
  setflag "\\Flagged";
}
''';
      final rules = parser.parse(script);
      expect(rules, hasLength(1));
      expect(rules.first.actions.first, isA<StarMessageAction>());
    });

    test('setflag \\Flagged adds the \\Flagged flag when executed', () {
      const script = r'''
require ["imap4flags"];
if header :contains "Subject" "hi" {
  setflag "\\Flagged";
}
''';
      final ctx = run(script, _email(subject: 'hi there'));
      expect(ctx.flagsToAdd, contains(r'\Flagged'));
    });
  });

  group('SieveParser — keep and stop', () {
    test('keep action keeps inbox', () {
      const script = 'keep;';
      final ctx = run(script, _email());
      expect(ctx.keepInInbox, isTrue);
      expect(ctx.isCancelled, isFalse);
    });

    test('stop acts as implicit keep', () {
      const script = 'stop;';
      final ctx = run(script, _email());
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('SieveParser — comments', () {
    test('line comments are ignored', () {
      const script = '''
# This is a comment
if header :contains "Subject" "Spam" {
  discard; # inline comment
}
''';
      final ctx = run(script, _email(subject: 'Spam'));
      expect(ctx.isCancelled, isTrue);
    });

    test('block comments are ignored', () {
      const script = '''
/* block comment */
if /* inline block */ header :contains "Subject" "Spam" {
  discard;
}
''';
      final ctx = run(script, _email(subject: 'Spam'));
      expect(ctx.isCancelled, isTrue);
    });
  });

  group('SieveParser — exists test', () {
    test('exists fires when header is present and non-empty', () {
      const script = '''
if exists "X-Spam-Flag" {
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
  });

  group('SieveParser — rule model', () {
    test('simple if produces one rule with branchGroupId', () {
      final rules = parser.parse(
        'if header :contains "Subject" "x" { discard; }',
      );
      expect(rules, hasLength(1));
      expect(rules.first.branchGroupId, isNotNull);
      expect(rules.first.conditions, hasLength(1));
      expect(rules.first.actions, hasLength(1));
      expect(rules.first.actions.first, isA<DiscardAction>());
    });

    test('if/elsif produces two rules with the same branchGroupId', () {
      const script = '''
if header :contains "Subject" "a" { discard; }
elsif header :contains "Subject" "b" { keep; }
''';
      final rules = parser.parse(script);
      expect(rules, hasLength(2));
      expect(rules[0].branchGroupId, equals(rules[1].branchGroupId));
      expect(rules[0].isElseBranch, isFalse);
      expect(rules[1].isElseBranch, isFalse);
    });

    test('else rule has isElseBranch=true', () {
      const script = '''
if header :contains "Subject" "a" { discard; }
else { keep; }
''';
      final rules = parser.parse(script);
      expect(rules, hasLength(2));
      expect(rules.last.isElseBranch, isTrue);
    });

    test('HeaderCondition fields are populated', () {
      final rules = parser.parse(
        'if header :contains ["From","Reply-To"] "x@y.com" { keep; }',
      );
      final cond = rules.first.conditions.first as HeaderCondition;
      expect(cond.headers, containsAll(['From', 'Reply-To']));
      expect(cond.matchType, ':contains');
      expect(cond.keyList, contains('x@y.com'));
    });
  });
}
