import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';
import 'package:sharedinbox/ui/screens/sent_queue_screen.dart';

import 'helpers.dart';

/// An outbox whose list stream re-emits when a row is taken for edit, so the
/// test can see the row disappear.
class _LiveOutbox extends FakeOutboxRepository {
  final _changes = StreamController<List<OutboxMessage>>.broadcast();

  /// When set, [takeForEdit] fails as if a flush were sending the row.
  bool inFlight = false;

  @override
  Stream<List<OutboxMessage>> observeAllOutbox() async* {
    yield List.of(messages);
    yield* _changes.stream;
  }

  @override
  Future<T?> takeForEdit<T>(
    int id,
    Future<T> Function(OutboxJob job) handOff,
  ) async {
    if (inFlight) throw OutboxRowInFlightException(id);
    final result = await super.takeForEdit(id, handOff);
    _changes.add(List.of(messages));
    return result;
  }
}

const _rowId = 5;

/// The finding this covers: a permanent rejection of a mistyped address.
_LiveOutbox _failedOutbox({
  required List<String> attachments,
  String status = 'failed',
}) {
  final outbox = _LiveOutbox();
  outbox.messages.add(
    OutboxMessage(
      id: _rowId,
      accountId: kTestAccount.id,
      subject: 'Lunch?',
      to: const ['carol@example.com'],
      cc: const ['dave@example.com'],
      bcc: const ['erin@example.com'],
      createdAt: DateTime.utc(2026, 10, 24, 9),
      attempts: 1,
      status: status,
      lastError: 'SMTP rejected: 5.1.2 Mailbox does not exist.',
    ),
  );
  outbox.jobs[_rowId] = OutboxJob(
    id: _rowId,
    accountId: kTestAccount.id,
    draft: EmailDraft(
      from: const EmailAddress(name: 'Alice', email: 'alice@example.com'),
      to: const [EmailAddress(name: 'Carol', email: 'carol@example.com')],
      cc: const [EmailAddress(email: 'dave@example.com')],
      bcc: const [EmailAddress(email: 'erin@example.com')],
      subject: 'Lunch?',
      body: 'Tomorrow at noon?',
      attachmentFilePaths: attachments,
      inReplyTo: 'parent@example.com',
      references: const ['parent@example.com'],
    ),
    mimeBytes: const [],
    attempts: 1,
    createdAt: DateTime.utc(2026, 10, 24, 9),
  );
  return outbox;
}

Future<void> _pumpQueue(
  WidgetTester tester, {
  required _LiveOutbox outbox,
  required FakeDraftRepository drafts,
}) async {
  final router = GoRouter(
    initialLocation: '/sent-queue',
    routes: [
      GoRoute(
        path: '/sent-queue',
        builder: (ctx, state) => const SentQueueScreen(),
      ),
      GoRoute(
        path: '/compose',
        builder: (ctx, state) => ComposeScreen.fromExtra(
          state.extra as Map<String, dynamic>?,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(const [kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
        draftRepositoryProvider.overrideWithValue(drafts),
        outboxRepositoryProvider.overrideWithValue(outbox),
        // SnackBars are mirrored into the app log; keep that off the real DB.
        appLogRepositoryProvider.overrideWithValue(
          const NoOpAppLogRepository(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets Compose's real file-system checks on its attachments complete: each
/// `stat` finishes on the real event loop, and the next one only starts once
/// the fake-async test zone has run the previous one's continuation. Edit
/// stats each file twice: once to save the draft, once to restore it.
Future<void> _settleFileIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void _expectComposeFilled() {
  expect(find.text('Compose'), findsOneWidget);
  expect(
    find.widgetWithText(TextFormField, 'Carol <carol@example.com>'),
    findsOneWidget,
  );
  expect(
    find.widgetWithText(TextFormField, 'dave@example.com'),
    findsOneWidget,
  );
  expect(
    find.widgetWithText(TextFormField, 'erin@example.com'),
    findsOneWidget,
    reason: 'Bcc is opened for a message that has Bcc recipients',
  );
  expect(find.widgetWithText(TextFormField, 'Lunch?'), findsOneWidget);
  expect(
    find.widgetWithText(TextFormField, 'Tomorrow at noon?'),
    findsOneWidget,
  );
}

void main() {
  testWidgets(
      'Edit on a failed row opens Compose filled in, saves a draft and '
      'removes the row', (tester) async {
    // Tall enough that Compose's attachment list, below the body, is built.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('outbox_edit'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final kept = File('${dir.path}/plan.pdf');
    await tester.runAsync(() => kept.writeAsString('pdf'));
    final photo = File('${dir.path}/photo.jpg');
    await tester.runAsync(() => photo.writeAsString('jpg'));
    final outbox = _failedOutbox(
      attachments: [kept.path, photo.path, '${dir.path}/gone.png'],
    );
    final drafts = FakeDraftRepository();
    await _pumpQueue(tester, outbox: outbox, drafts: drafts);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await _settleFileIo(tester);

    _expectComposeFilled();
    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(
      find.text('Attachment no longer available: gone.png'),
      findsOneWidget,
    );

    final draft = (await drafts.getDraft(drafts.savedIds.single))!;
    expect(draft.accountId, kTestAccount.id);
    expect(draft.toText, 'Carol <carol@example.com>');
    expect(draft.ccText, 'dave@example.com');
    expect(draft.bccText, 'erin@example.com');
    expect(draft.subjectText, 'Lunch?');
    expect(draft.bodyText, 'Tomorrow at noon?');
    // The draft holds the attachments (#955), so leaving loses nothing.
    expect(
      draft.attachments.map((a) => a.filename),
      ['plan.pdf', 'photo.jpg', 'gone.png'],
    );
    expect(draft.attachments.first.contentType, 'application/pdf');
    expect(outbox.messages, isEmpty);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await _settleFileIo(tester);

    // Straight back on the queue, the row is gone.
    expect(find.text('Discard attachments?'), findsNothing);
    expect(find.text('No messages waiting to be sent.'), findsOneWidget);
    expect(await tester.runAsync(kept.exists), isTrue);
  });

  testWidgets('a pending row offers no Edit', (tester) async {
    final outbox = _failedOutbox(attachments: const [], status: 'pending');
    await _pumpQueue(tester, outbox: outbox, drafts: FakeDraftRepository());

    expect(find.byTooltip('Edit'), findsNothing);
    await tester.tap(find.textContaining('5.1.2 Mailbox does not exist'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
  });

  testWidgets('the error details dialog offers Edit too', (tester) async {
    final outbox = _failedOutbox(attachments: const []);
    final drafts = FakeDraftRepository();
    await _pumpQueue(tester, outbox: outbox, drafts: drafts);

    await tester.tap(find.textContaining('5.1.2 Mailbox does not exist'));
    await tester.pumpAndSettle();
    expect(find.text('Send failed'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();

    _expectComposeFilled();
    expect(drafts.savedIds, hasLength(1));
    expect(outbox.messages, isEmpty);
  });

  testWidgets('Edit while the row is being sent leaves it queued', (
    tester,
  ) async {
    final outbox = _failedOutbox(attachments: const [])..inFlight = true;
    final drafts = FakeDraftRepository();
    await _pumpQueue(tester, outbox: outbox, drafts: drafts);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Compose'), findsNothing);
    expect(
      find.text('This message is being sent right now — try again in a '
          'moment'),
      findsOneWidget,
    );
    expect(drafts.savedIds, isEmpty);
    expect(outbox.messages, hasLength(1));
  });
}
