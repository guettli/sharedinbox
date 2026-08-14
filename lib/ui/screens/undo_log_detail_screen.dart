import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

final _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

class UndoLogDetailScreen extends ConsumerWidget {
  const UndoLogDetailScreen({super.key, required this.action});

  final UndoAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final account = ref.watch(accountByIdProvider(action.accountId)).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Undo Log Detail'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref
                  .read(undoServiceProvider.notifier)
                  .undo(actionId: action.id);
              if (context.mounted) {
                Navigator.of(context).pop();
                context.showAppSnackBar(
                  'Action undone.',
                  duration: const Duration(seconds: 5),
                );
              }
            },
            child: const Text('Undo'),
          ),
        ],
      ),
      body: StreamBuilder<List<Mailbox>>(
        stream: ref
            .watch(mailboxRepositoryProvider)
            .observeMailboxes(action.accountId),
        builder: (ctx, snap) {
          final mailboxes = snap.data ?? const <Mailbox>[];
          return ListView(
            children: [
              _SectionHeader(text: 'Transaction', theme: theme),
              ListTile(
                leading: const Icon(Icons.account_circle),
                title: const Text('Account'),
                subtitle: Text(accountDisplayLabel(account, action.accountId)),
              ),
              ListTile(
                leading: Icon(
                  action.type == UndoType.delete
                      ? Icons.delete_outline
                      : (action.type == UndoType.snooze
                          ? Icons.access_time
                          : Icons.move_to_inbox),
                  color: action.type == UndoType.delete
                      ? Colors.redAccent
                      : (action.type == UndoType.snooze
                          ? Colors.orangeAccent
                          : Colors.blueAccent),
                ),
                title: const Text('Action'),
                subtitle: Text(action.type.name.toUpperCase()),
              ),
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Timestamp'),
                subtitle: Text(_dateTimeFmt.format(action.timestamp.toLocal())),
              ),
              _SectionHeader(text: 'Folders', theme: theme),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Source'),
                subtitle: Text(
                  resolveMailboxDisplayPath(
                    mailboxes,
                    action.sourceMailboxPath,
                  ),
                ),
              ),
              if (action.type == UndoType.move &&
                  action.destinationMailboxPath != null)
                ListTile(
                  leading: const Icon(Icons.drive_file_move),
                  title: const Text('Destination'),
                  subtitle: Text(
                    resolveMailboxDisplayPath(
                      mailboxes,
                      action.destinationMailboxPath!,
                    ),
                  ),
                ),
              _SectionHeader(
                text: 'Emails (${action.emailIds.length})',
                theme: theme,
              ),
              _EmailsSection(action: action),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Emails section for an undo action. When [UndoAction.originalEmails] is
/// populated (the common case for actions taken by the current build), those
/// are rendered directly. Otherwise the tile falls back to
/// [EmailRepository.getEmail] so legacy actions already persisted before the
/// helpers started snapshotting headers still show a subject — no migration
/// needed.
class _EmailsSection extends ConsumerWidget {
  const _EmailsSection({required this.action});

  final UndoAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (action.originalEmails.isNotEmpty) {
      return Column(
        children: [
          for (final email in action.originalEmails)
            _EmailTile(email: email, accountId: action.accountId),
        ],
      );
    }
    return FutureBuilder<List<Email>>(
      future: _fetchEmails(ref, action.emailIds),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final emails = snap.data ?? const <Email>[];
        if (emails.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '${action.emailIds.length} email(s) — details not available',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          );
        }
        return Column(
          children: [
            for (final email in emails)
              _EmailTile(email: email, accountId: action.accountId),
          ],
        );
      },
    );
  }

  Future<List<Email>> _fetchEmails(WidgetRef ref, List<String> ids) async {
    final repo = ref.read(emailRepositoryProvider);
    final results = await Future.wait(ids.map(repo.getEmail));
    return results.whereType<Email>().toList();
  }
}

class _EmailTile extends ConsumerWidget {
  const _EmailTile({required this.email, required this.accountId});

  final Email email;
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sender = email.from.isNotEmpty
        ? (email.from.first.name ?? email.from.first.email)
        : '(Unknown Sender)';
    return ListTile(
      leading: const Icon(Icons.email_outlined),
      title: Text(email.subject ?? '(No Subject)'),
      subtitle: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openEmail(context, ref),
    );
  }

  Future<void> _openEmail(BuildContext context, WidgetRef ref) async {
    final messageId = email.messageId;
    final messenger = context.appMessenger();
    if (messageId == null) {
      messenger.show(
        'Cannot locate this email — no Message-ID.',
        level: AppLogLevel.warn,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    final found = await ref
        .read(emailRepositoryProvider)
        .findEmailByMessageId(accountId, messageId);
    if (!context.mounted) return;
    if (found == null) {
      messenger.show(
        'Email no longer exists at its previous location. '
        'Use Undo to restore it.',
        level: AppLogLevel.warn,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    context.go(
      '/accounts/$accountId'
      '/mailboxes/${Uri.encodeComponent(found.mailboxPath)}'
      '/emails/${Uri.encodeComponent(found.id)}',
    );
  }
}
