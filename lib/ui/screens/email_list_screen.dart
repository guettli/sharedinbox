import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/account.dart';
import '../../core/models/email.dart';
import '../../core/repositories/email_repository.dart';
import '../../di.dart';
import '../widgets/folder_drawer.dart';

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
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  List<Email>? _searchResults;
  bool _searchLoading = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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

  void _closeSearch() {
    setState(() {
      _searching = false;
      _searchResults = null;
      _searchCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));
    return Scaffold(
      appBar: _searching ? _searchBar() : _normalBar(repo, accountAsync),
      drawer: _searching
          ? null
          : FolderDrawer(
              accountId: widget.accountId,
              currentMailboxPath: widget.mailboxPath,
            ),
      body: _searching ? _buildSearchBody() : _buildStreamBody(repo),
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
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => setState(() => _searching = true),
        ),
        IconButton(
          icon: const Icon(Icons.sync),
          onPressed: () =>
              emailRepo.syncEmails(widget.accountId, widget.mailboxPath),
        ),
        IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () => context.push(
            '/compose',
            extra: {'accountId': widget.accountId},
          ),
        ),
      ],
    );
  }

  AppBar _searchBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _closeSearch,
      ),
      title: TextField(
        controller: _searchCtrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search…',
          border: InputBorder.none,
        ),
        onSubmitted: _runSearch,
        textInputAction: TextInputAction.search,
      ),
      actions: [
        if (_searchCtrl.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              _searchCtrl.clear();
              setState(() => _searchResults = null);
            },
          ),
      ],
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
    return _buildList(_searchResults!);
  }

  Widget _buildStreamBody(EmailRepository emailRepo) {
    return StreamBuilder<List<Email>>(
      stream: emailRepo.observeEmails(widget.accountId, widget.mailboxPath),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final emails = snap.data!;
        if (emails.isEmpty) {
          return const Center(child: Text('No emails'));
        }
        return _buildList(emails);
      },
    );
  }

  Widget _buildList(List<Email> emails) {
    return ListView.builder(
      itemCount: emails.length,
      itemBuilder: (ctx, i) {
        final e = emails[i];
        final sender = e.from.isNotEmpty
            ? (e.from.first.name ?? e.from.first.email)
            : '(unknown)';
        return ListTile(
          leading: Icon(
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (e.isFlagged)
                const Icon(Icons.star, color: Colors.amber, size: 16),
              if (e.hasAttachment) const Icon(Icons.attach_file, size: 16),
              const SizedBox(width: 4),
              Text(
                e.sentAt != null ? _dateFmt.format(e.sentAt!) : '',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
          onTap: () => context.push(
            '/accounts/${widget.accountId}/mailboxes/${Uri.encodeComponent(widget.mailboxPath)}/emails/${Uri.encodeComponent(e.id)}',
          ),
        );
      },
    );
  }
}
