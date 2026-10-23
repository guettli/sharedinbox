import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';

enum _MissingFolderChoice { chooseExisting, createNew }

/// Resolves a mailbox by role, prompting the user to choose or create one when
/// the role is not found.  Returns the target [Mailbox], or null if cancelled.
///
/// [folderKind] names the folder in the prompt ("No archive folder found").
/// [accountLabel] (the account's address), when given, replaces "found" with
/// the account ("No archive folder for alice@example.com") and heads the
/// folder picker, so each prompt of a multi-account batch says which account
/// it is about.
Future<Mailbox?> resolveMailboxByRole(
  BuildContext context,
  MailboxRepository mailboxRepo,
  String accountId,
  String currentMailboxPath,
  String role, {
  required String folderKind,
  required String createFolderName,
  String? accountLabel,
}) async {
  Mailbox? mailbox = await mailboxRepo.findMailboxByRole(accountId, role);
  if (!context.mounted) return null;
  if (mailbox != null) return mailbox;

  final dialogTitle = accountLabel == null
      ? 'No $folderKind folder found'
      : 'No $folderKind folder for $accountLabel';
  final choice = await showDialog<_MissingFolderChoice>(
    context: context,
    // Only an explicit answer counts: a stray tap beside the prompt used to
    // dismiss it, silently dropping this account from the batch.
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(dialogTitle),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
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
            ListTile(
              title: Text(
                accountLabel == null ? 'Move to…' : 'Move to… ($accountLabel)',
                style: const TextStyle(fontWeight: FontWeight.bold),
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
      folderKind: 'archive',
      createFolderName: 'Archive',
      notDoneLabel: 'Not archived',
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
      folderKind: 'spam',
      createFolderName: 'Junk',
      notDoneLabel: 'Not marked as spam',
    );

/// Moves every thread in [threads] back to its account's inbox. Backs the
/// "Not junk" / "Restore" batch actions shown while viewing the Junk or Trash
/// folder.
Future<void> batchMoveToInbox(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
}) =>
    _batchMoveToRole(
      context,
      ref,
      threads: threads,
      role: 'inbox',
      folderKind: 'inbox',
      createFolderName: 'Inbox',
      notDoneLabel: 'Not moved to Inbox',
    );

Future<void> _batchMoveToRole(
  BuildContext context,
  WidgetRef ref, {
  required List<EmailThread> threads,
  required String role,
  required String folderKind,
  required String createFolderName,
  required String notDoneLabel,
}) async {
  if (threads.isEmpty) return;
  final mailboxRepo = ref.read(mailboxRepositoryProvider);
  final accountRepo = ref.read(accountRepositoryProvider);
  final messenger = context.appMessenger();

  // Settle every account's destination before moving anything, so no row
  // leaves the list while a prompt for another account is still open, and
  // a cancelled account simply keeps its rows. "Create" makes the folder on
  // the server right away, even when a later account's prompt is cancelled;
  // an empty new folder is accepted for that.
  final moves = <(List<EmailThread>, Mailbox)>[];
  final skipped = <String>[];
  for (final MapEntry(key: accountId, value: accountThreads)
      in _groupByAccount(threads).entries) {
    if (!context.mounted) return;
    final account = await accountRepo.getAccount(accountId);
    if (!context.mounted) return;
    final label = account?.email ?? accountId;
    final mailbox = await resolveMailboxByRole(
      context,
      mailboxRepo,
      accountId,
      accountThreads.first.mailboxPath,
      role,
      folderKind: folderKind,
      createFolderName: createFolderName,
      accountLabel: label,
    );
    if (mailbox == null) {
      skipped.add(label);
    } else {
      moves.add((accountThreads, mailbox));
    }
  }

  for (final (accountThreads, mailbox) in moves) {
    await _moveThreadsTo(ref, accountThreads, mailbox.path, role: role);
  }

  // Never drop an account silently: its mail stays put, so say so.
  if (skipped.isNotEmpty) {
    messenger.show(
      '$notDoneLabel: ${skipped.join(', ')}',
      level: AppLogLevel.warn,
    );
  }
}

/// Deletes every thread in [threads]. Threads are grouped by
/// `(accountId, sourceMailboxPath)` so a batch produces one aggregated
/// undo entry per source folder — the shell's SnackBar then reports the
/// true count instead of just the last thread's message count (#289).
Future<void> batchDelete(
  WidgetRef ref, {
  required List<EmailThread> threads,
}) async {
  if (threads.isEmpty) return;
  // The mailbox each selected message is in right now. deleteEmails uses it to
  // refuse hard-deleting a message that has since moved — an accidental second
  // delete of a selection the first call already moved to Trash (#1010).
  final expectedMailbox = <String, String>{
    for (final t in threads)
      for (final id in t.emailIds) id: t.mailboxPath,
  };
  for (final accountThreads in _groupByAccount(threads).values) {
    await _pushGroupedUndo(
      ref,
      accountThreads,
      type: UndoType.delete,
      // One bulk call: a per-id deleteEmail loop made large selections
      // crawl (#917).
      apply: (repo, emailIds) => runZoned(
        () => repo.deleteEmails(emailIds),
        zoneValues: {deleteExpectedMailboxZoneKey: expectedMailbox},
      ),
    );
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

  await snoozeThreadsUntil(ref, threads: threads, until: until);
}

/// Snoozes every thread in [threads] until [until], pushing one aggregated
/// undo action per `(accountId, sourceMailboxPath)` group. Shared by the
/// [SnoozePicker]-driven [batchSnooze] and the swipe-tree numeric snooze
/// levels, which compute [until] directly from a day/week count.
Future<void> snoozeThreadsUntil(
  WidgetRef ref, {
  required List<EmailThread> threads,
  required DateTime until,
}) async {
  if (threads.isEmpty) return;
  for (final accountThreads in _groupByAccount(threads).values) {
    await _pushGroupedUndo(
      ref,
      accountThreads,
      type: UndoType.snooze,
      apply: (repo, emailIds) async {
        for (final id in emailIds) {
          await repo.snoozeEmail(id, until);
        }
        return null;
      },
    );
  }
}

/// Flags (stars) or unflags every email in every thread in [threads]. The
/// selection-mode bottom bar decides which direction to apply based on the
/// current thread flags: if any selected thread is unstarred we star all of
/// them, otherwise we unstar all.
Future<void> batchStar(
  WidgetRef ref, {
  required List<EmailThread> threads,
  required bool flagged,
}) async {
  if (threads.isEmpty) return;
  final repo = ref.read(emailRepositoryProvider);
  for (final t in threads) {
    for (final id in t.emailIds) {
      await repo.setFlag(id, flagged: flagged);
    }
  }
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

/// Groups [threads] by their [EmailThread.mailboxPath] so a batch action can
/// push one aggregated [UndoAction] per source folder. Undo can then restore
/// each group to its own original folder — search selections legitimately
/// span multiple folders.
Map<String, List<EmailThread>> _groupBySource(List<EmailThread> threads) {
  final bySource = <String, List<EmailThread>>{};
  for (final t in threads) {
    (bySource[t.mailboxPath] ??= []).add(t);
  }
  return bySource;
}

Future<void> _moveThreadsTo(
  WidgetRef ref,
  List<EmailThread> threads,
  String destPath, {
  String? role,
}) {
  // Callers hand us a single-account thread list; _pushGroupedUndo aggregates
  // by source folder so the UndoAction carries every message in that folder.
  return _pushGroupedUndo(
    ref,
    threads,
    type: UndoType.move,
    destinationMailboxRole: role,
    apply: (repo, emailIds) async {
      for (final id in emailIds) {
        await repo.moveEmail(id, destPath);
      }
      return destPath;
    },
  );
}

/// Moves every thread in [threads] to [destPath] (an account-specific mailbox
/// path), pushing one aggregated undo action per source folder. Used by the
/// swipe-tree `Move → folder` leaves, which already scope the folder list to a
/// single account.
Future<void> moveThreadsToPath(
  WidgetRef ref, {
  required List<EmailThread> threads,
  required String destPath,
}) async {
  if (threads.isEmpty) return;
  for (final accountThreads in _groupByAccount(threads).values) {
    await _moveThreadsTo(ref, accountThreads, destPath);
  }
}

/// Applies [apply] to every email in each source-folder group of [threads]
/// (a single-account list) and pushes one aggregated [UndoAction] of [type]
/// per group.
///
/// Grouping by source folder lets undo restore each folder's messages to their
/// own origin and makes the shell's SnackBar report the true batch count rather
/// than just the last thread's (#289). [apply] returns the destination mailbox
/// path recorded on the undo entry — the delete target for a delete, the folder
/// path for a move, or `null` when the action doesn't relocate mail.
Future<void> _pushGroupedUndo(
  WidgetRef ref,
  List<EmailThread> threads, {
  required UndoType type,
  required Future<String?> Function(EmailRepository, List<String>) apply,
  String? destinationMailboxRole,
}) async {
  final repo = ref.read(emailRepositoryProvider);
  for (final entry in _groupBySource(threads).entries) {
    final sourcePath = entry.key;
    final sourceThreads = entry.value;
    final allEmailIds = [for (final t in sourceThreads) ...t.emailIds];
    final originalEmails = await _fetchOriginals(repo, allEmailIds);

    final destPath = await apply(repo, allEmailIds);

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: sourceThreads.first.accountId,
      type: type,
      emailIds: allEmailIds,
      sourceMailboxPath: sourcePath,
      destinationMailboxPath: destPath,
      destinationMailboxRole: destinationMailboxRole,
      originalEmails: originalEmails,
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
  }
}
