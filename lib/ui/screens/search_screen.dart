import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/email.dart';
import '../../core/models/mailbox.dart';
import '../../core/utils/logger.dart';
import '../../di.dart';
import '../widgets/folder_drawer.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, required this.accountId});
  final String accountId;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  _SearchResults? _results;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _search(value.trim()),
    );
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final emailRepo = ref.read(emailRepositoryProvider);
      final mailboxRepo = ref.read(mailboxRepositoryProvider);
      final ql = query.toLowerCase();

      final (allMailboxes, emails, addressEmails) = await (
        mailboxRepo.observeMailboxes(widget.accountId).first,
        emailRepo.searchEmailsGlobal(widget.accountId, query),
        emailRepo.getEmailsByAddress(widget.accountId, query),
      ).wait;

      final matchedMailboxes = allMailboxes
          .where((m) => m.name.toLowerCase().contains(ql))
          .toList()
        ..sort(compareMailboxes);

      // Collect unique addresses from address-search results where the
      // email or display name contains the query.
      final seen = <String>{};
      final addresses = <(EmailAddress, int)>[];
      for (final email in addressEmails) {
        for (final addr in [...email.from, ...email.to, ...email.cc]) {
          if (seen.contains(addr.email)) continue;
          final matchesEmail = addr.email.toLowerCase().contains(ql);
          final matchesName = addr.name?.toLowerCase().contains(ql) ?? false;
          if (!matchesEmail && !matchesName) continue;
          seen.add(addr.email);
          final addrEmail = addr.email;
          final count = addressEmails
              .where(
                (e) => [...e.from, ...e.to, ...e.cc]
                    .any((a) => a.email == addrEmail),
              )
              .length;
          addresses.add((addr, count));
        }
      }

      if (mounted) {
        setState(() {
          _results = _SearchResults(
            mailboxes: matchedMailboxes,
            addresses: addresses,
            emails: emails,
          );
          _loading = false;
        });
      }
    } catch (e) {
      log('Search failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search folders, addresses, emails…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _ctrl.clear();
                setState(() => _results = null);
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_results == null) {
      return const Center(child: Text('Type 3+ characters to search'));
    }
    final r = _results!;
    if (r.isEmpty) return const Center(child: Text('No results'));
    return ListView(
      children: [
        if (r.mailboxes.isNotEmpty) ...[
          const _SectionHeader('Folders'),
          for (final mb in r.mailboxes)
            _FolderTile(mb: mb, accountId: widget.accountId),
        ],
        if (r.addresses.isNotEmpty) ...[
          const _SectionHeader('Addresses'),
          for (final (addr, count) in r.addresses)
            _AddressTile(
              addr: addr,
              count: count,
              accountId: widget.accountId,
            ),
        ],
        if (r.emails.isNotEmpty) ...[
          const _SectionHeader('Messages'),
          for (final e in r.emails)
            _EmailTile(email: e, accountId: widget.accountId),
        ],
      ],
    );
  }
}

class _SearchResults {
  const _SearchResults({
    required this.mailboxes,
    required this.addresses,
    required this.emails,
  });

  final List<Mailbox> mailboxes;
  final List<(EmailAddress, int)> addresses;
  final List<Email> emails;

  bool get isEmpty => mailboxes.isEmpty && addresses.isEmpty && emails.isEmpty;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.mb, required this.accountId});
  final Mailbox mb;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(
        mb.name,
        style: mb.unreadCount > 0
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
      trailing:
          mb.unreadCount > 0 ? Badge(label: Text('${mb.unreadCount}')) : null,
      onTap: () => context.go(
        '/accounts/$accountId/mailboxes'
        '/${Uri.encodeComponent(mb.path)}/emails',
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.addr,
    required this.count,
    required this.accountId,
  });

  final EmailAddress addr;
  final int count;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.person),
      title: Text(addr.name ?? addr.email),
      subtitle: addr.name != null ? Text(addr.email) : null,
      trailing: Text('$count mail${count == 1 ? '' : 's'}'),
      onTap: () => context.push(
        '/accounts/$accountId/emails/by-address'
        '/${Uri.encodeComponent(addr.email)}',
      ),
    );
  }
}

class _EmailTile extends StatelessWidget {
  const _EmailTile({required this.email, required this.accountId});
  final Email email;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    final sender = email.from.isNotEmpty
        ? (email.from.first.name ?? email.from.first.email)
        : '(unknown)';
    return ListTile(
      leading: Icon(
        email.isSeen ? Icons.mail_outline : Icons.mail,
        color: email.isSeen ? null : Theme.of(context).colorScheme.primary,
      ),
      title: Text(sender),
      subtitle: Text(
        email.subject ?? '(no subject)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        email.mailboxPath,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => context.push(
        '/accounts/$accountId/mailboxes'
        '/${Uri.encodeComponent(email.mailboxPath)}'
        '/emails/${Uri.encodeComponent(email.id)}',
      ),
    );
  }
}
