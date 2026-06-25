import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';

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
  final interp = SieveInterpreter();

  group('SieveInterpreter — no rules', () {
    test('empty rule list keeps inbox', () {
      final ctx = interp.execute([], _email());
      expect(ctx.keepInInbox, isTrue);
      expect(ctx.isCancelled, isFalse);
    });
  });

  group('HeaderCondition :contains', () {
    test('matches subject substring (case-insensitive)', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['spam']),
          ],
          actions: [DiscardAction()],
        ),
      ];

      final ctx = interp.execute(rules, _email(subject: 'This is SPAM!'));
      expect(ctx.isCancelled, isTrue);
      expect(ctx.keepInInbox, isFalse);
    });

    test('does not match unrelated subject', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['spam']),
          ],
          actions: [DiscardAction()],
        ),
      ];

      final ctx = interp.execute(rules, _email(subject: 'Meeting tomorrow'));
      expect(ctx.isCancelled, isFalse);
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('HeaderCondition :is', () {
    test('exact match on from header', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['from', 'reply-to'], ':is', ['boss@work.com']),
          ],
          actions: [
            FlagAction([r'\Important']),
            FileIntoAction('Work'),
          ],
        ),
      ];

      final ctx = interp.execute(rules, _email(from: 'boss@work.com'));
      expect(ctx.flagsToAdd, contains(r'\Important'));
      expect(ctx.targetFolders, contains('Work'));
      expect(ctx.keepInInbox, isFalse);
    });

    test('does not match partial from address', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['from'], ':is', ['boss@work.com']),
          ],
          actions: [FileIntoAction('Work')],
        ),
      ];

      final ctx = interp.execute(rules, _email(from: 'other-boss@work.com'));
      expect(ctx.targetFolders, isEmpty);
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('HeaderCondition :matches (glob)', () {
    test('* matches any substring', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':matches', ['*newsletter*']),
          ],
          actions: [FileIntoAction('Bulk')],
        ),
      ];

      final ctx = interp.execute(
        rules,
        _email(subject: 'Weekly Newsletter Issue'),
      );
      expect(ctx.targetFolders, contains('Bulk'));
    });
  });

  group('SizeCondition', () {
    test(':over threshold fires', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [SizeCondition(':over', 1024)],
          actions: [FileIntoAction('Large')],
        ),
      ];
      final ctx = interp.execute(rules, _email(size: 2048));
      expect(ctx.targetFolders, contains('Large'));
    });

    test(':under threshold fires', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [SizeCondition(':under', 500)],
          actions: [FileIntoAction('Small')],
        ),
      ];
      final ctx = interp.execute(rules, _email(size: 100));
      expect(ctx.targetFolders, contains('Small'));
    });

    test(':over threshold does not fire when size equals threshold', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [SizeCondition(':over', 1024)],
          actions: [DiscardAction()],
        ),
      ];
      final ctx = interp.execute(rules, _email(size: 1024));
      expect(ctx.isCancelled, isFalse);
    });
  });

  group('allof / anyof join types', () {
    test('allof fires only when all conditions match', () {
      final rules = [
        SieveRule(
          joinType: 'allof',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['deal']),
            HeaderCondition(['from'], ':contains', ['shop.com']),
          ],
          actions: [FileIntoAction('Deals')],
        ),
      ];

      // Both match.
      var ctx = interp.execute(
        rules,
        _email(subject: 'Big deal today', from: 'offers@shop.com'),
      );
      expect(ctx.targetFolders, contains('Deals'));

      // Only subject matches.
      ctx = interp.execute(
        rules,
        _email(subject: 'Big deal today', from: 'friend@example.com'),
      );
      expect(ctx.targetFolders, isEmpty);
    });

    test('anyof fires when any condition matches', () {
      final rules = [
        SieveRule(
          joinType: 'anyof',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['spam']),
            HeaderCondition(['subject'], ':contains', ['advertisement']),
          ],
          actions: [DiscardAction()],
        ),
      ];

      final ctx = interp.execute(rules, _email(subject: 'Huge advertisement!'));
      expect(ctx.isCancelled, isTrue);
    });
  });

  group('discard stops processing', () {
    test('rules after discard are skipped', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['spam']),
          ],
          actions: [DiscardAction()],
        ),
        SieveRule(
          joinType: 'single',
          conditions: const [],
          actions: [FileIntoAction('Inbox')],
        ),
      ];

      final ctx = interp.execute(rules, _email(subject: 'Spam'));
      expect(ctx.isCancelled, isTrue);
      expect(ctx.targetFolders, isEmpty);
    });
  });

  group('MarkAsSeenAction', () {
    test('adds \\Seen flag', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: const [],
          actions: [MarkAsSeenAction()],
        ),
      ];
      final ctx = interp.execute(rules, _email());
      expect(ctx.flagsToAdd, contains(r'\Seen'));
    });
  });

  group('StarMessageAction', () {
    test('adds \\Flagged flag', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: const [],
          actions: [StarMessageAction()],
        ),
      ];
      final ctx = interp.execute(rules, _email());
      expect(ctx.flagsToAdd, contains(r'\Flagged'));
    });
  });

  group('if/elsif/else branch groups', () {
    final rules = [
      SieveRule(
        joinType: 'single',
        conditions: [
          HeaderCondition(['subject'], ':contains', ['spam']),
        ],
        actions: [DiscardAction()],
        branchGroupId: 1,
      ),
      SieveRule(
        joinType: 'single',
        conditions: [
          HeaderCondition(['subject'], ':contains', ['work']),
        ],
        actions: [FileIntoAction('Work')],
        branchGroupId: 1,
      ),
      SieveRule(
        joinType: 'single',
        conditions: const [],
        actions: [KeepAction()],
        branchGroupId: 1,
        isElseBranch: true,
      ),
    ];

    test('first branch fires, subsequent branches are skipped', () {
      final ctx = interp.execute(rules, _email(subject: 'spam message'));
      expect(ctx.isCancelled, isTrue);
      expect(ctx.targetFolders, isEmpty);
    });

    test('second branch fires when first does not match', () {
      final ctx = interp.execute(rules, _email(subject: 'Work update'));
      expect(ctx.isCancelled, isFalse);
      expect(ctx.targetFolders, contains('Work'));
    });

    test('else branch fires when no branch matched', () {
      final ctx = interp.execute(rules, _email(subject: 'Hello'));
      expect(ctx.isCancelled, isFalse);
      expect(ctx.targetFolders, isEmpty);
      expect(ctx.keepInInbox, isTrue);
    });
  });

  group('multiple independent rules', () {
    test('both rules fire when conditions match', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['invoice']),
          ],
          actions: [FileIntoAction('Finance')],
        ),
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['from'], ':contains', ['boss@']),
          ],
          actions: [
            FlagAction([r'\Important']),
          ],
        ),
      ];

      final ctx = interp.execute(
        rules,
        _email(subject: 'Invoice #123', from: 'boss@corp.com'),
      );
      expect(ctx.targetFolders, contains('Finance'));
      expect(ctx.flagsToAdd, contains(r'\Important'));
    });
  });

  group('implicit keep', () {
    test('keepInInbox stays true when no action changes routing', () {
      final rules = [
        SieveRule(
          joinType: 'single',
          conditions: [
            HeaderCondition(['subject'], ':contains', ['nope']),
          ],
          actions: [DiscardAction()],
        ),
      ];
      final ctx = interp.execute(rules, _email(subject: 'Hi there'));
      expect(ctx.keepInInbox, isTrue);
      expect(ctx.isCancelled, isFalse);
    });
  });
}
