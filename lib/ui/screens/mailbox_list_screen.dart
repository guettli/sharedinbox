import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/folder_tree.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_drawer.dart';
import 'package:sharedinbox/ui/widgets/folder_tree_picker.dart';
import 'package:sharedinbox/ui/widgets/mailbox_count_label.dart';
import 'package:sharedinbox/ui/widgets/mailbox_role.dart';

class MailboxListScreen extends ConsumerWidget {
  const MailboxListScreen({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mailboxRepo = ref.watch(mailboxRepositoryProvider);
    final emailRepo = ref.watch(emailRepositoryProvider);
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    final prefs =
        ref.watch(userPreferencesProvider).value ?? const UserPreferences();
    final menuAtBottom = prefs.menuPosition == MenuPosition.bottom;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !menuAtBottom,
        title: const Text('Folders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search everywhere',
            onPressed: () => context.push('/accounts/$accountId/search'),
          ),
          accountAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (account) => Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Center(
                child: Text(
                  account?.displayName ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ],
      ),
      drawer: AppDrawer(current: AppDrawerSelection.account(accountId)),
      bottomNavigationBar: menuAtBottom
          ? BottomAppBar(
              child: Row(
                children: [
                  Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: 'Open folders',
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: Column(
        children: [
          // ── Failed-mutation banner ───────────────────────────────────────
          StreamBuilder<List<FailedMutation>>(
            stream: emailRepo.observeFailedMutations(accountId),
            builder: (ctx, snap) {
              final mutations = snap.data ?? [];
              if (mutations.isEmpty) return const SizedBox.shrink();
              return _FailedMutationBanner(
                mutations: mutations,
                emailRepo: emailRepo,
              );
            },
          ),
          // ── Mailbox list ─────────────────────────────────────────────────
          Expanded(
            child: StreamBuilder(
              stream: mailboxRepo.observeMailboxes(accountId),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final mailboxes = snap.data!;
                final byDisplayPath = {
                  for (final m in mailboxes) m.displayPath: m,
                };
                // Flatten the hierarchy (built by splitting each displayPath
                // on `/`) into a pre-order list of rows so the tree renders as
                // an indented, always-expanded list.
                final rows = _flattenTree(buildFolderTree(mailboxes));
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final node = row.node;
                    final indent = AppSpacing.lg + row.depth * AppSpacing.lg;
                    // Phantom parent: an intermediate path segment with no
                    // real mailbox of its own. Render a non-tappable header so
                    // the tree still reads correctly.
                    final mb = node.displayPath == null
                        ? null
                        : byDisplayPath[node.displayPath];
                    if (mb == null) {
                      return ListTile(
                        contentPadding: EdgeInsetsDirectional.only(
                          start: indent,
                          end: AppSpacing.lg,
                        ),
                        leading: Icon(
                          Icons.folder_open,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                        title: Text(
                          node.label,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    final hasUnread = mb.unreadCount > 0;
                    final roleLabel = mailboxRoleLabel(mb.role);
                    return ListTile(
                      contentPadding: EdgeInsetsDirectional.only(
                        start: indent,
                        end: AppSpacing.lg,
                      ),
                      leading: Icon(mailboxRoleIcon(mb.role)),
                      title: Text(
                        node.label,
                        style: hasUnread
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      ),
                      subtitle: roleLabel == null ? null : Text(roleLabel),
                      trailing: MailboxCountLabel(
                        unread: mb.unreadCount,
                        total: mb.totalCount,
                      ),
                      onTap: () => context.push(
                        '/accounts/$accountId/mailboxes/${Uri.encodeComponent(mb.path)}/emails',
                      ),
                      onLongPress: () => _showFolderActions(
                        context,
                        ref,
                        accountId,
                        mb,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Flattens [roots] into a pre-order list of `(node, depth)` rows, so the
/// folder hierarchy can be rendered as an always-expanded, indented list.
List<({FolderNode node, int depth})> _flattenTree(List<FolderNode> roots) {
  final rows = <({FolderNode node, int depth})>[];
  void visit(FolderNode node, int depth) {
    rows.add((node: node, depth: depth));
    for (final child in node.children) {
      visit(child, depth + 1);
    }
  }

  for (final root in roots) {
    visit(root, 0);
  }
  return rows;
}

/// Opens the long-press action sheet for [mailbox]: rename / move / delete.
Future<void> _showFolderActions(
  BuildContext context,
  WidgetRef ref,
  String accountId,
  Mailbox mailbox,
) async {
  final action = await showModalBottomSheet<_FolderAction>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              mailbox.displayPath,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            onTap: () => Navigator.pop(ctx, _FolderAction.rename),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Move'),
            onTap: () => Navigator.pop(ctx, _FolderAction.move),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Diagnose'),
            subtitle: const Text('Compare folder count with the server'),
            onTap: () => Navigator.pop(ctx, _FolderAction.diagnose),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(ctx).colorScheme.error,
            ),
            title: Text(
              'Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
            onTap: () => Navigator.pop(ctx, _FolderAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final repo = ref.read(mailboxRepositoryProvider);
  switch (action) {
    case _FolderAction.rename:
      await _promptRename(context, ref, repo, accountId, mailbox);
    case _FolderAction.move:
      await _promptMove(context, ref, repo, accountId, mailbox);
    case _FolderAction.diagnose:
      await context.push(
        '/accounts/$accountId/mailboxes/'
        '${Uri.encodeComponent(mailbox.path)}/diagnostics',
      );
    case _FolderAction.delete:
      await _promptDelete(context, ref, repo, accountId, mailbox);
  }
}

enum _FolderAction { rename, move, diagnose, delete }

Future<void> _promptRename(
  BuildContext context,
  WidgetRef ref,
  MailboxRepository repo,
  String accountId,
  Mailbox mailbox,
) async {
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => _RenameFolderDialog(currentName: mailbox.name),
  );
  if (newName == null || !context.mounted) return;
  try {
    await repo.renameMailbox(accountId, mailbox.path, newName);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Folder renamed to "$newName"')),
    );
  } catch (e, stack) {
    unawaited(
      ref.read(appLoggerProvider).error(
            'mailbox.rename_failed',
            'Failed to rename mailbox',
            accountId: accountId,
            mailboxPath: mailbox.path,
            data: {'newName': newName},
            error: e,
            stack: stack,
          ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not rename folder: $e')),
    );
  }
}

Future<void> _promptMove(
  BuildContext context,
  WidgetRef ref,
  MailboxRepository repo,
  String accountId,
  Mailbox mailbox,
) async {
  // Show the folder tree, filtered so the user can neither pick the folder
  // itself nor any of its descendants (both would create an invalid cycle).
  final filteredStream = repo.observeMailboxes(accountId).map((all) {
    return all.where((m) {
      if (m.path == mailbox.path) return false;
      if (m.displayPath == mailbox.displayPath) return false;
      if (m.displayPath.startsWith('${mailbox.displayPath}/')) return false;
      return true;
    }).toList();
  });
  final destination = await showFolderTreePicker(
    context,
    mailboxesStream: filteredStream,
  );
  if (!context.mounted) return;
  // The picker returns the chosen folder's displayPath, or null on cancel.
  // There is no way to pick "(top level)" from this widget yet, so cancel
  // means the user did not confirm a destination.
  if (destination == null) return;
  try {
    await repo.moveMailbox(
      accountId,
      mailbox.path,
      newParentDisplayPath: destination,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Folder moved under "$destination"')),
    );
  } catch (e, stack) {
    unawaited(
      ref.read(appLoggerProvider).error(
            'mailbox.move_failed',
            'Failed to move mailbox',
            accountId: accountId,
            mailboxPath: mailbox.path,
            data: {'destination': destination},
            error: e,
            stack: stack,
          ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not move folder: $e')),
    );
  }
}

Future<void> _promptDelete(
  BuildContext context,
  WidgetRef ref,
  MailboxRepository repo,
  String accountId,
  Mailbox mailbox,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete folder?'),
      content: Text(
        'Delete "${mailbox.displayPath}" and everything it contains? '
        'This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await repo.deleteMailbox(accountId, mailbox.path);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Folder "${mailbox.name}" deleted')),
    );
  } catch (e, stack) {
    unawaited(
      ref.read(appLoggerProvider).error(
            'mailbox.delete_failed',
            'Failed to delete mailbox',
            accountId: accountId,
            mailboxPath: mailbox.path,
            error: e,
            stack: stack,
          ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not delete folder: $e')),
    );
  }
}

class _RenameFolderDialog extends StatefulWidget {
  const _RenameFolderDialog({required this.currentName});
  final String currentName;

  @override
  State<_RenameFolderDialog> createState() => _RenameFolderDialogState();
}

class _RenameFolderDialogState extends State<_RenameFolderDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? raw) {
    final name = raw?.trim() ?? '';
    if (name.isEmpty) return 'Enter a name';
    if (name.contains('/')) return 'Name cannot contain "/"';
    if (name == widget.currentName) return 'Enter a different name';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename folder'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onFieldSubmitted: (_) => _submit(),
          validator: _validate,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
}

class _FailedMutationBanner extends StatelessWidget {
  const _FailedMutationBanner({
    required this.mutations,
    required this.emailRepo,
  });

  final List<FailedMutation> mutations;
  final EmailRepository emailRepo;

  String _label(FailedMutation m) {
    final noun = switch (m.changeType) {
      'flag_seen' || 'flag_flagged' => 'flag change',
      'move' => 'move',
      'delete' => 'deletion',
      _ => 'change',
    };
    return '${mutations.length} pending $noun${mutations.length > 1 ? 's' : ''} failed';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber,
              color: Theme.of(context).colorScheme.onErrorContainer,
              size: AppIconSize.md,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                _label(mutations.first),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                for (final m in mutations) {
                  await emailRepo.retryMutation(m.id);
                }
              },
              child: Text(
                'Retry',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                for (final m in mutations) {
                  await emailRepo.discardMutation(m.id);
                }
              },
              child: Text(
                'Discard',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
