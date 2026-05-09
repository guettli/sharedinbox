import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/folder_drawer.dart';

final _dateFmt = DateFormat('MMM d');

class EmailListScreen extends ConsumerStatefulWidget {
  const EmailListScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
  });

  final String accountId;
  final String mailboxPath;

  @override
  ConsumerState<EmailListScreen> createState() => _EmailListScreenState();
}

class _EmailListScreenState extends ConsumerState<EmailListScreen> {
  final _searchController = SearchController();
  List<Email>? _searchResults;
  bool _searchLoading = false;
  bool get _searching => _searchController.text.isNotEmpty;

  // Thread-level selection (key = threadId).
  final Set<String> _selectedThreadIds = {};
  // Last-emitted thread list, used to resolve emailIds for batch operations.
  List<EmailThread> _currentThreads = [];
  // Individual email selection used in search results.
  final Set<String> _selectedSearchIds = {};
  bool get _selecting =>
      _selectedThreadIds.isNotEmpty || _selectedSearchIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (_searchController.text.isEmpty) {
        setState(() {
          _searchResults = null;
          _searchLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleThreadSelection(EmailThread thread) {
    setState(() {
      if (_selectedThreadIds.contains(thread.threadId)) {
        _selectedThreadIds.remove(thread.threadId);
      } else {
        _selectedThreadIds.add(thread.threadId);
      }
    });
  }

  void _clearSelection() => setState(() {
        _selectedThreadIds.clear();
        _selectedSearchIds.clear();
      });

  void _toggleSearchSelection(String emailId) {
    setState(() {
      if (_selectedSearchIds.contains(emailId)) {
        _selectedSearchIds.remove(emailId);
      } else {
        _selectedSearchIds.add(emailId);
      }
    });
  }

  // All email IDs for the current selection context.
  List<String> get _selectedEmailIds {
    if (_searching) return _selectedSearchIds.toList();
    return _currentThreads
        .where((t) => _selectedThreadIds.contains(t.threadId))
        .expand((t) => t.emailIds)
        .toList();
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    setState(() => _searchLoading = true);
    try {
      final results = await ref.read(emailRepositoryProvider).searchEmails(
            widget.accountId,
            widget.mailboxPath,
            query.trim(),
          );
      if (mounted) setState(() => _searchResults = results);
    } finally {
      if (mounted) setState(() => _searchLoading = false);
    }
  }

  void _onSearchChanged(String value) {
    if (value.trim().isNotEmpty) unawaited(_runSearch(value.trim()));
  }

  void _showUndoSnackbar(UndoAction action) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          action.type == UndoType.delete
              ? '${action.emailIds.length} email(s) moved to Trash'
              : '${action.emailIds.length} email(s) moved',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => ref.read(undoServiceProvider.notifier).undo(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));

    ref.listen<UndoAction?>(undoServiceProvider, (previous, next) {
      if (next != null && previous?.id != next.id) {
        _showUndoSnackbar(next);
      }
    });

    return Scaffold(
      appBar: _selecting ? _selectionBar() : _normalBar(repo, accountAsync),
      drawer: _selecting
          ? null
          : FolderDrawer(
              accountId: widget.accountId,
              currentMailboxPath: widget.mailboxPath,
            ),
      bottomNavigationBar: _selecting ? _selectionBottomBar() : null,
      body: (_searchResults != null || _searchLoading)
          ? _buildSearchBody()
          : _buildStreamBody(repo),
    );
  }

  AppBar _normalBar(
    EmailRepository emailRepo,
    AsyncValue<Account?> accountAsync,
  ) {
    return AppBar(
      title: Text(widget.mailboxPath),
      actions: [
        accountAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (account) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                account?.displayName ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.sync),
          onPressed: () async {
            try {
              await emailRepo.syncEmails(
                widget.accountId,
                widget.mailboxPath,
              );
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sync failed: $e')),
              );
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () => context.push(
            '/compose',
            extra: {'accountId': widget.accountId},
          ),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: SearchBar(
            controller: _searchController,
            hintText: 'Search…',
            leading: const Icon(Icons.search),
            trailing: [
              if (_searchController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => _searchController.clear(),
                ),
            ],
            onChanged: _onSearchChanged,
            onSubmitted: _runSearch,
            textInputAction: TextInputAction.search,
          ),
        ),
      ),
    );
  }

  AppBar _selectionBar() {
    final count =
        _searching ? _selectedSearchIds.length : _selectedThreadIds.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('$count selected'),
    );
  }

  Widget _selectionBottomBar() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Archive',
            onPressed: _batchArchive,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: _batchDelete,
          ),
          IconButton(
            icon: const Icon(Icons.report),
            tooltip: 'Mark as spam',
            onPressed: _batchMarkSpam,
          ),
          IconButton(
            icon: const Icon(Icons.drive_file_move),
            tooltip: 'Move to folder',
            onPressed: _batchMove,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBody() {
    if (_searchLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults == null) {
      return const Center(child: Text('Type a query and press Enter'));
    }
    if (_searchResults!.isEmpty) {
      return const Center(child: Text('No results'));
    }
    return _buildEmailList(_searchResults!);
  }

  Widget _buildStreamBody(EmailRepository emailRepo) {
    return RefreshIndicator(
      onRefresh: () async {
        // Trigger a background sync cycle immediately.
        ref.read(syncManagerProvider).syncNow(widget.accountId);
        // Also wait for this specific mailbox to sync for immediate feedback.
        await emailRepo.syncEmails(widget.accountId, widget.mailboxPath);
      },
      child: StreamBuilder<List<EmailThread>>(
        stream: emailRepo.observeThreads(widget.accountId, widget.mailboxPath),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final threads = snap.data!;
          _currentThreads = threads;
          if (threads.isEmpty) {
            return ListView(
              children: const [
                SizedBox(
                  height: 300,
                  child: Center(child: Text('No emails')),
                ),
              ],
            );
          }
          return _buildThreadList(threads);
        },
      ),
    );
  }

  Future<void> _batchMoveToRole(String role, String notFoundMessage) async {
    final ids = _selectedEmailIds;
    _clearSelection();
    final mailbox = await ref
        .read(mailboxRepositoryProvider)
        .findMailboxByRole(widget.accountId, role);
    if (!mounted) return;
    if (mailbox == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(notFoundMessage)),
      );
      return;
    }
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.moveEmail(id, mailbox.path);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: widget.accountId,
      type: UndoType.move,
      emailIds: ids,
      sourceMailboxPath: widget.mailboxPath,
      destinationMailboxPath: mailbox.path,
    );
    ref.read(undoServiceProvider.notifier).pushAction(action);
  }

  Future<void> _batchArchive() =>
      _batchMoveToRole('archive', 'No archive folder found');

  Future<void> _batchDelete() async {
    final ids = _selectedEmailIds;
    final count = ids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete emails'),
        content: Text('Move $count email${count == 1 ? '' : 's'} to Trash?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _clearSelection();
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.deleteEmail(id);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: widget.accountId,
      type: UndoType.delete,
      emailIds: ids,
      sourceMailboxPath: widget.mailboxPath,
    );
    ref.read(undoServiceProvider.notifier).pushAction(action);
  }

  Future<void> _batchMarkSpam() =>
      _batchMoveToRole('junk', 'No spam folder found');

  Future<void> _batchMove() async {
    final ids = _selectedEmailIds;
    final mailboxes = await ref
        .read(mailboxRepositoryProvider)
        .observeMailboxes(widget.accountId)
        .first;
    final destinations =
        mailboxes.where((m) => m.path != widget.mailboxPath).toList();

    if (!mounted) return;

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

    if (chosen == null || !mounted) return;
    _clearSelection();
    final repo = ref.read(emailRepositoryProvider);
    for (final id in ids) {
      await repo.moveEmail(id, chosen);
    }

    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: widget.accountId,
      type: UndoType.move,
      emailIds: ids,
      sourceMailboxPath: widget.mailboxPath,
      destinationMailboxPath: chosen,
    );
    ref.read(undoServiceProvider.notifier).pushAction(action);
  }

  Widget _buildThreadList(List<EmailThread> threads) {
    return ListView.builder(
      itemCount: threads.length,
      itemBuilder: (ctx, i) {
        final t = threads[i];
        final isSelected = _selectedThreadIds.contains(t.threadId);
        final senderNames =
            t.participants.map((a) => a.name ?? a.email).take(3).join(', ');

        final tile = ListTile(
          leading: _selecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleThreadSelection(t),
                )
              : Icon(
                  t.hasUnread ? Icons.mail : Icons.mail_outline,
                  color: t.hasUnread ? Theme.of(ctx).colorScheme.primary : null,
                ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  senderNames.isEmpty ? '(unknown)' : senderNames,
                  style: t.hasUnread
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (t.messageCount > 1)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '[${t.messageCount}]',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.subject ?? '(no subject)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.hasUnread
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
              if (t.preview != null && t.preview!.isNotEmpty)
                Text(
                  t.preview!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
            ],
          ),
          selected: isSelected,
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.isFlagged)
                      const Icon(Icons.star, color: Colors.amber, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      _dateFmt.format(t.latestDate),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
          onTap: _selecting
              ? () => _toggleThreadSelection(t)
              : t.messageCount > 1
                  ? () => context.push(
                        '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/threads/${Uri.encodeComponent(t.threadId)}',
                      )
                  : () => context.push(
                        '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(t.latestEmailId)}',
                      ),
          onLongPress: () => _toggleThreadSelection(t),
        );

        if (_selecting) return tile;

        // For swipe actions on threads, operate on the latest email only
        // (single-email threads) or the whole thread.
        return Dismissible(
          key: ValueKey(t.threadId),
          background: _swipeBackground(
            alignment: Alignment.centerLeft,
            color: Colors.green,
            icon: Icons.archive,
            label: 'Archive',
          ),
          secondaryBackground: _swipeBackground(
            alignment: Alignment.centerRight,
            color: Colors.red,
            icon: Icons.delete,
            label: 'Delete',
          ),
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.endToStart) {
              return showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete email'),
                  content: const Text('Move this email to Trash?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
            }
            return true;
          },
          onDismissed: (direction) async {
            final repo = ref.read(emailRepositoryProvider);
            final type = direction == DismissDirection.startToEnd
                ? UndoType.move
                : UndoType.delete;

            if (direction == DismissDirection.startToEnd) {
              final archive = await ref
                  .read(mailboxRepositoryProvider)
                  .findMailboxByRole(widget.accountId, 'archive');
              if (!mounted || archive == null) return;
              for (final id in t.emailIds) {
                await repo.moveEmail(id, archive.path);
              }

              final action = UndoAction(
                id: DateTime.now().toIso8601String(),
                accountId: widget.accountId,
                type: type,
                emailIds: t.emailIds,
                sourceMailboxPath: widget.mailboxPath,
                destinationMailboxPath: archive.path,
              );
              ref.read(undoServiceProvider.notifier).pushAction(action);
            } else {
              for (final id in t.emailIds) {
                await repo.deleteEmail(id);
              }

              final action = UndoAction(
                id: DateTime.now().toIso8601String(),
                accountId: widget.accountId,
                type: type,
                emailIds: t.emailIds,
                sourceMailboxPath: widget.mailboxPath,
              );
              ref.read(undoServiceProvider.notifier).pushAction(action);
            }
          },
          child: tile,
        );
      },
    );
  }

  // Used for search results, which are individual emails.
  Widget _buildEmailList(List<Email> emails) {
    return ListView.builder(
      itemCount: emails.length,
      itemBuilder: (ctx, i) {
        final e = emails[i];
        final isSelected = _selectedSearchIds.contains(e.id);
        final sender = e.from.isNotEmpty
            ? (e.from.first.name ?? e.from.first.email)
            : '(unknown)';
        return ListTile(
          leading: _selecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleSearchSelection(e.id),
                )
              : Icon(
                  e.isSeen ? Icons.mail_outline : Icons.mail,
                  color: e.isSeen ? null : Theme.of(ctx).colorScheme.primary,
                ),
          title: Text(
            sender,
            style:
                e.isSeen ? null : const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            e.subject ?? '(no subject)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          selected: isSelected,
          trailing: _selecting
              ? null
              : Text(
                  e.sentAt != null ? _dateFmt.format(e.sentAt!) : '',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
          onTap: _selecting
              ? () => _toggleSearchSelection(e.id)
              : () => context.push(
                    '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(e.id)}',
                  ),
          onLongPress: () => _toggleSearchSelection(e.id),
        );
      },
    );
  }

  Widget _swipeBackground({
    required AlignmentGeometry alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
