import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/email.dart';
import '../../core/repositories/email_repository.dart';
import '../../di.dart';

class MailboxListScreen extends ConsumerWidget {
  const MailboxListScreen({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mailboxRepo = ref.watch(mailboxRepositoryProvider);
    final emailRepo = ref.watch(emailRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mailboxes')),
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
                return ListView.builder(
                  itemCount: mailboxes.length,
                  itemBuilder: (ctx, i) {
                    final mb = mailboxes[i];
                    return ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(mb.name),
                      trailing: mb.unreadCount > 0
                          ? Badge(label: Text('${mb.unreadCount}'))
                          : null,
                      onTap: () => context.push(
                        '/accounts/$accountId/mailboxes/${Uri.encodeComponent(mb.path)}/emails',
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber,
              color: Theme.of(context).colorScheme.onErrorContainer,
              size: 20,
            ),
            const SizedBox(width: 8),
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
