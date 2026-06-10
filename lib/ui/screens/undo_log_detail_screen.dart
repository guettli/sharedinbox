import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

final _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

class UndoLogDetailScreen extends ConsumerWidget {
  const UndoLogDetailScreen({super.key, required this.action});

  final UndoAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    duration: Duration(seconds: 5),
                    content: Text('Action undone.'),
                  ),
                );
              }
            },
            child: const Text('Undo'),
          ),
        ],
      ),
      body: ListView(
        children: [
          _SectionHeader(text: 'Transaction', theme: theme),
          ListTile(
            leading: const Icon(Icons.account_circle),
            title: const Text('Account'),
            subtitle: Text(action.accountId),
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
            subtitle: Text(action.sourceMailboxPath),
          ),
          if (action.type == UndoType.move &&
              action.destinationMailboxPath != null)
            ListTile(
              leading: const Icon(Icons.drive_file_move),
              title: const Text('Destination'),
              subtitle: Text(action.destinationMailboxPath!),
            ),
          _SectionHeader(
            text: 'Emails (${action.emailIds.length})',
            theme: theme,
          ),
          if (action.originalEmails.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '${action.emailIds.length} email(s) — details not available',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ...action.originalEmails.map(
            (email) => _EmailTile(email: email, accountId: action.accountId),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
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
    final messenger = ScaffoldMessenger.of(context);
    if (messageId == null) {
      messenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('Cannot locate this email — no Message-ID.'),
        ),
      );
      return;
    }
    final found = await ref
        .read(emailRepositoryProvider)
        .findEmailByMessageId(accountId, messageId);
    if (!context.mounted) return;
    if (found == null) {
      messenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text(
            'Email no longer exists at its previous location. '
            'Use Undo to restore it.',
          ),
        ),
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
