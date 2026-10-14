import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/account_comparison_provider.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/account_compare_screen.dart';

Email _row({
  required String id,
  required String accountId,
  String mailboxPath = 'INBOX',
  String? subject = 'Hello',
  String? messageId = '<m1@example.com>',
  bool isSeen = false,
}) =>
    Email(
      id: id,
      accountId: accountId,
      mailboxPath: mailboxPath,
      uid: 0,
      subject: subject,
      sentAt: DateTime.utc(2026, 1, 1, 12),
      receivedAt: DateTime.utc(2026, 1, 1, 12),
      fromJson: '[]',
      toAddresses: '[]',
      ccJson: '[]',
      replyToJson: '[]',
      isSeen: isSeen,
      isFlagged: false,
      hasAttachment: false,
      messageId: messageId,
      isLocal: false,
    );

AccountComparisonResult _resultWith(List<EmailDiff> emails) =>
    AccountComparisonResult(
      accountIdA: 'a',
      accountIdB: 'b',
      mailboxes: const [],
      emails: emails,
      bodies: const [],
      unmatchable: const [],
    );

Future<void> _pump(
  WidgetTester tester,
  AccountComparisonResult result, {
  Account? accountA,
  Account? accountB,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountComparisonProvider(('a', 'b'))
            .overrideWith((ref) => Future.value(result)),
        accountByIdProvider('a').overrideWith((ref) => Stream.value(accountA)),
        accountByIdProvider('b').overrideWith((ref) => Stream.value(accountB)),
      ],
      child: const MaterialApp(
        home: AccountCompareScreen(accountIdA: 'a', accountIdB: 'b'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Regression for the row-overflow class fixed in #965: this banner paired a
  // fixed-size icon with an unconstrained label, so at accessibility text
  // scales the label took its intrinsic width and overflowed the row instead
  // of wrapping beside the icon. The default 800x600 test surface is wide
  // enough to hide it, so the surface is narrowed to a compact phone here.
  testWidgets('identical banner does not overflow at large text scale',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400); // 360x800 logical
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pump(tester, _resultWith([]));

    // Prove the scale actually reached the widget, otherwise this passes
    // against the bug. The bound is loose on purpose: the effective scale
    // observed inside the app tree has not always matched the raw factor, so
    // this asserts only that the override arrived and is not identity.
    final scaler = MediaQuery.textScalerOf(
      tester.element(find.text('Local DBs are identical')),
    );
    expect(scaler.scale(14), greaterThan(16));

    expect(tester.takeException(), isNull);
  });

  testWidgets('collapses equal fields to a single "(equal)" row',
      (tester) async {
    // A and B agree on everything except the seen flag.
    final diff = EmailDiff(
      kind: EmailDiffKind.fieldMismatch,
      mailboxKey: 'role:inbox',
      folderName: 'Inbox',
      messageId: '<m1@example.com>',
      a: _row(id: 'a:1', accountId: 'a'),
      b: _row(id: 'b:1', accountId: 'b', isSeen: true),
      fields: const [EmailFieldMismatch.seen],
    );

    await _pump(tester, _resultWith([diff]));
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();

    // Equal fields (subject, folder, …) collapse to one "(equal)" row each.
    expect(find.text('(equal)'), findsWidgets);
    // The differing flag field is shown for both sides.
    expect(find.text('A · flags'), findsOneWidget);
    expect(find.text('B · flags'), findsOneWidget);
    // The folder shows the friendly name, never a raw path.
    expect(find.text('Inbox'), findsWidgets);
  });

  testWidgets('shows open buttons only for the sides that exist',
      (tester) async {
    final present = EmailDiff(
      kind: EmailDiffKind.fieldMismatch,
      mailboxKey: 'role:inbox',
      folderName: 'Inbox',
      messageId: '<m1@example.com>',
      a: _row(id: 'a:1', accountId: 'a'),
      b: _row(id: 'b:1', accountId: 'b', isSeen: true),
      fields: const [EmailFieldMismatch.seen],
    );
    final missingB = EmailDiff(
      kind: EmailDiffKind.missingInB,
      mailboxKey: 'role:inbox',
      folderName: 'Inbox',
      messageId: '<m2@example.com>',
      a: _row(id: 'a:2', accountId: 'a', messageId: '<m2@example.com>'),
      b: null,
    );

    await _pump(tester, _resultWith([present, missingB]));
    for (final tile in find.byType(ExpansionTile).evaluate().toList()) {
      await tester.tap(find.byWidget(tile.widget));
      await tester.pumpAndSettle();
    }

    // The matched pair offers both sides; the missing-in-B one only offers A.
    expect(find.text('Open in A'), findsNWidgets(2));
    expect(find.text('Open in B'), findsOneWidget);
  });

  testWidgets('body-diff legend names the accounts on each side',
      (tester) async {
    final body = BodyDiff(
      messageId: '<m1@example.com>',
      folderName: 'Inbox',
      a: _row(id: 'a:1', accountId: 'a'),
      b: _row(id: 'b:1', accountId: 'b'),
    );
    final result = AccountComparisonResult(
      accountIdA: 'a',
      accountIdB: 'b',
      mailboxes: const [],
      emails: const [],
      bodies: [body],
      unmatchable: const [],
    );

    await _pump(
      tester,
      result,
      accountA: const Account(id: 'a', displayName: 'Work', email: 'w@x.com'),
      accountB: const Account(
        id: 'b',
        displayName: 'Personal',
        email: 'p@x.com',
        type: AccountType.jmap,
      ),
    );
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();

    // The legend spells out which account is A (−) and which is B (+).
    expect(
      find.text('A (Work (IMAP)) = −, B (Personal (JMAP)) = +'),
      findsOneWidget,
    );
  });
}
