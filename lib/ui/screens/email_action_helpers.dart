import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';

enum _MissingFolderChoice { chooseExisting, createNew }

/// Resolves a mailbox by role, prompting the user to choose or create one when
/// the role is not found.  Returns the target [Mailbox], or null if cancelled.
Future<Mailbox?> resolveMailboxByRole(
  BuildContext context,
  MailboxRepository mailboxRepo,
  String accountId,
  String currentMailboxPath,
  String role, {
  required String dialogTitle,
  required String createFolderName,
}) async {
  Mailbox? mailbox = await mailboxRepo.findMailboxByRole(accountId, role);
  if (!context.mounted) return null;
  if (mailbox != null) return mailbox;

  final choice = await showDialog<_MissingFolderChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(dialogTitle),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, _MissingFolderChoice.chooseExisting),
          child: const Text('Choose existing folder'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, _MissingFolderChoice.createNew),
          child: Text('Create "$createFolderName"'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return null;

  switch (choice) {
    case _MissingFolderChoice.chooseExisting:
      final mailboxes = await mailboxRepo.observeMailboxes(accountId).first;
      if (!context.mounted) return null;
      final chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Move to…',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final m in mailboxes.where(
              (m) => m.path != currentMailboxPath,
            ))
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(m.name),
                onTap: () => Navigator.pop(ctx, m.path),
              ),
          ],
        ),
      );
      if (chosen == null || !context.mounted) return null;
      mailbox = mailboxes.firstWhere((m) => m.path == chosen);
    case _MissingFolderChoice.createNew:
      mailbox = await mailboxRepo.createMailboxWithRole(
        accountId,
        createFolderName,
        role,
      );
      if (!context.mounted) return null;
  }

  return mailbox;
}

// ---------------------------------------------------------------------------
// Shared batch helpers
// ---------------------------------------------------------------------------
//
// Single source of truth for batch actions across every email-list surface
// (folder, combined inbox, search, address). Threads are grouped by
// accountId so a multi-account selection still produces correctly scoped
// repository calls and undo actions.

/// Archives every thread in [threads], grouping by account so each account's
/// archive folder is resolved once. Prompts the user when an account has no
/// archive folder.
Future<void> batchArchive(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
}) =>
    _batchMoveToRole(
      context,
      ref,
      threads: threads,
      role: 'archive',
      dialogTitle: 'No archive folder found',
      createFolderName: 'Archive',
    );

/// Moves every thread in [threads] to its account's junk folder.
Future<void> batchMarkSpam(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
}) =>
    _batchMoveToRole(
      context,
      ref,
      threads: threads,
      role: 'junk',
      dialogTitle: 'No spam folder found',
      createFolderName: 'Junk',
    );

Future<void> _batchMoveToRole(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
  required String role,
  required String dialogTitle,
  required String createFolderName,
}) async {
  if (threads.isEmpty) return;
  final mailboxRepo = ref.read(mailboxRepositoryProvider);

  final byAccount = _groupByAccount(threads);
  for (final entry in byAccount.entries) {
    if (!context.mounted) return;
    final accountId = entry.key;
    final accountThreads = entry.value;
    final mailbox = await resolveMailboxByRole(
      context,
      mailboxRepo,
      accountId,
      accountThreads.first.mailboxPath,
      role,
      dialogTitle: dialogTitle,
      createFolderName: createFolderName,
    );
    if (mailbox == null) continue;

    await _moveThreadsTo(ref, accountThreads, mailbox.path);
  }
}

/// Deletes every thread in [threads]. Each thread becomes its own undo entry
/// so the destination path remains per-thread (e.g. each account's Trash).
Future<void> batchDelete(
  WidgetRef ref, {
  required List<EmailThread> threads,
}) async {
  if (threads.isEmpty) return;
  final repo = ref.read(emailRepositoryProvider);

  for (final t in threads) {
    final originalEmails = await _fetchOriginals(repo, t.emailIds);

    String? lastDestPath;
    for (final id in t.emailIds) {
      lastDestPath = await repo.deleteEmail(id);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: t.accountId,
      type: UndoType.delete,
      emailIds: t.emailIds,
      sourceMailboxPath: t.mailboxPath,
      destinationMailboxPath: lastDestPath,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
  }
}

/// Lets the user pick a destination folder and moves every thread there.
/// Cross-account selections show one picker per account; cancelled accounts
/// are skipped.
Future<void> batchMove(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
}) async {
  if (threads.isEmpty) return;
  final mailboxRepo = ref.read(mailboxRepositoryProvider);

  final byAccount = _groupByAccount(threads);
  for (final entry in byAccount.entries) {
    final accountId = entry.key;
    final accountThreads = entry.value;
    final currentPath = accountThreads.first.mailboxPath;

    final mailboxes = await mailboxRepo.observeMailboxes(accountId).first;
    if (!context.mounted) return;
    final destinations = mailboxes.where((m) => m.path != currentPath).toList();

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text(
              'Move to…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) continue;

    await _moveThreadsTo(ref, accountThreads, chosen);
  }
}

Future<void> batchSnooze(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
}) async {
  if (threads.isEmpty) return;
  final until = await showModalBottomSheet<DateTime>(
    context: context,
    builder: (ctx) => const SnoozePicker(),
  );
  if (until == null || !context.mounted) return;

  final repo = ref.read(emailRepositoryProvider);
  var totalCount = 0;

  for (final t in threads) {
    final originalEmails = await _fetchOriginals(repo, t.emailIds);

    for (final id in t.emailIds) {
      await repo.snoozeEmail(id, until);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: t.accountId,
      type: UndoType.snooze,
      emailIds: t.emailIds,
      sourceMailboxPath: t.mailboxPath,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
    totalCount += t.emailIds.length;
  }

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        'Snoozed $totalCount email${totalCount == 1 ? '' : 's'} until '
        '${DateFormat('MMM d, HH:mm').format(until)}',
      ),
    ),
  );
}

/// Handles a swipe-to-archive (start→end) or swipe-to-delete (end→start) on a
/// single [thread]. Shared between folder and combined inbox surfaces.
Future<void> swipeDismissThread(
  WidgetRef ref,
  EmailThread thread,
  DismissDirection direction,
) async {
  final repo = ref.read(emailRepositoryProvider);

  final originalEmails = await _fetchOriginals(repo, thread.emailIds);

  if (direction == DismissDirection.startToEnd) {
    final archive = await ref
        .read(mailboxRepositoryProvider)
        .findMailboxByRole(thread.accountId, 'archive');
    if (archive == null) return;
    for (final id in thread.emailIds) {
      await repo.moveEmail(id, archive.path);
    }
    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: thread.accountId,
      type: UndoType.move,
      emailIds: thread.emailIds,
      sourceMailboxPath: thread.mailboxPath,
      destinationMailboxPath: archive.path,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
    return;
  }

  String? lastDestPath;
  for (final id in thread.emailIds) {
    lastDestPath = await repo.deleteEmail(id);
  }
  final action = UndoAction(
    id: DateTime.now().toIso8601String(),
    accountId: thread.accountId,
    type: UndoType.delete,
    emailIds: thread.emailIds,
    sourceMailboxPath: thread.mailboxPath,
    destinationMailboxPath: lastDestPath,
    originalEmails: originalEmails,
  );
  unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
}

Future<List<Email>> _fetchOriginals(
  EmailRepository repo,
  Iterable<String> ids,
) async =>
    (await Future.wait(ids.map((id) => repo.getEmail(id))))
        .whereType<Email>()
        .toList();

Map<String, List<EmailThread>> _groupByAccount(List<EmailThread> threads) {
  final byAccount = <String, List<EmailThread>>{};
  for (final t in threads) {
    (byAccount[t.accountId] ??= []).add(t);
  }
  return byAccount;
}

Future<void> _moveThreadsTo(
  WidgetRef ref,
  List<EmailThread> threads,
  String destPath,
) async {
  final repo = ref.read(emailRepositoryProvider);
  for (final t in threads) {
    final originalEmails = await _fetchOriginals(repo, t.emailIds);

    for (final id in t.emailIds) {
      await repo.moveEmail(id, destPath);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: t.accountId,
      type: UndoType.move,
      emailIds: t.emailIds,
      sourceMailboxPath: t.mailboxPath,
      destinationMailboxPath: destPath,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
  }
}
