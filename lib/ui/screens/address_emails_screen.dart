import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

class AddressEmailsScreen extends ConsumerStatefulWidget {
  const AddressEmailsScreen({
    super.key,
    required this.accountId,
    required this.address,
  });

  final String accountId;
  final String address;

  @override
  ConsumerState<AddressEmailsScreen> createState() =>
      _AddressEmailsScreenState();
}

class _AddressEmailsScreenState extends ConsumerState<AddressEmailsScreen> {
  List<Email>? _emails;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final emails = await ref
        .read(emailRepositoryProvider)
        .getEmailsByAddress(widget.accountId, widget.address);
    if (mounted) {
      setState(() {
        _emails = emails;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.address)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _emails!.isEmpty
          ? const Center(child: Text('No emails'))
          : ListView.builder(
              itemCount: _emails!.length,
              itemBuilder: (ctx, i) {
                final e = _emails![i];
                final sender = e.from.isNotEmpty
                    ? (e.from.first.name ?? e.from.first.email)
                    : '(unknown)';
                return ListTile(
                  leading: Icon(
                    e.isSeen ? Icons.mail_outline : Icons.mail,
                    color: e.isSeen ? null : Theme.of(ctx).colorScheme.primary,
                  ),
                  title: Text(sender),
                  subtitle: Text(
                    e.subject ?? '(no subject)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    e.mailboxPath,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  onTap: () => context.push(
                    '/accounts/${widget.accountId}/mailboxes'
                    '/${Uri.encodeComponent(e.mailboxPath)}'
                    '/emails/${Uri.encodeComponent(e.id)}',
                  ),
                );
              },
            ),
    );
  }
}
