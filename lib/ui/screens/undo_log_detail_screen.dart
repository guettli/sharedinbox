import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

final _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

class UndoLogDetailScreen extends ConsumerWidget {
  const UndoLogDetailScreen({super.key, required this.action});

  final UndoAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mailboxRepo = ref.watch(mailboxRepositoryProvider);

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
      body: StreamBuilder<List<Mailbox>>(
        stream: mailboxRepo.observeMailboxes(action.accountId),
        builder: (context, snapshot) {
          final mailboxes = snapshot.data ?? const <Mailbox>[];
          String display(String path) =>
              mailboxDisplayForPath(mailboxes, path);
          return ListView(
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
                subtitle: Text(display(action.sourceMailboxPath)),
              ),
              if (action.type == UndoType.move &&
                  action.destinationMailboxPath != null)
                ListTile(
                  leading: const Icon(Icons.drive_file_move),
                  title: const Text('Destination'),
                  subtitle: Text(display(action.destinationMailboxPath!)),
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

/// Resolves a stored mailbox [path] (which for JMAP is an opaque server ID
/// like `a`) to something readable. Prefers [Mailbox.displayPath] so the
/// hierarchical folder name shows, and falls back to the raw path when the
/// mailbox is no longer in the cache (e.g. the account was removed or the
/// folder was deleted after the action was recorded).
String mailboxDisplayForPath(List<Mailbox> mailboxes, String path) {
  for (final m in mailboxes) {
    if (m.path == path) return m.displayPath;
  }
  return path;
}

/// Renders the "Emails" section of the detail screen. When
/// [UndoAction.originalEmails] is empty (legacy entries, or actions pushed
/// before we started snapshotting the headers) we fetch them from the local
/// email cache by id so the subject/sender still show instead of a blunt
/// "details not available".
class _EmailsSection extends ConsumerStatefulWidget {
  const _EmailsSection({required this.action});

  final UndoAction action;

  @override
  ConsumerState<_EmailsSection> createState() => _EmailsSectionState();
}

class _EmailsSectionState extends ConsumerState<_EmailsSection> {
  Future<List<Email>>? _fetched;

  @override
  void initState() {
    super.initState();
    if (widget.action.originalEmails.isEmpty &&
        widget.action.emailIds.isNotEmpty) {
      final repo = ref.read(emailRepositoryProvider);
      _fetched = Future.wait(widget.action.emailIds.map(repo.getEmail))
          .then((list) => list.whereType<Email>().toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.action.originalEmails.isNotEmpty) {
      return Column(
        children: [
          for (final email in widget.action.originalEmails)
            _EmailTile(email: email, accountId: widget.action.accountId),
        ],
      );
    }
    if (_fetched == null) {
      return _missingDetails(context);
    }
    return FutureBuilder<List<Email>>(
      future: _fetched,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final emails = snapshot.data ?? const <Email>[];
        if (emails.isEmpty) {
          return _missingDetails(context);
        }
        return Column(
          children: [
            for (final email in emails)
              _EmailTile(email: email, accountId: widget.action.accountId),
          ],
        );
      },
    );
  }

  Widget _missingDetails(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        '${widget.action.emailIds.length} email(s) — details not available',
        style: Theme.of(context).textTheme.bodySmall,
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
