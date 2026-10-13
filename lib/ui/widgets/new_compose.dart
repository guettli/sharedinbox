import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/di.dart';

/// Opens compose for a new message from the Compose action (#1047).
///
/// Without saved new-message drafts this goes straight to a blank compose.
/// Otherwise the user picks in a dialog: resume one of the drafts (listed with
/// account, To and Subject) or create a new message. A draft is never loaded
/// silently, so new content can no longer merge into a stale draft.
///
/// [accountId] scopes both the drafts offered and the blank compose to one
/// account (an account inbox); null offers every account's drafts.
Future<void> openNewCompose(
  BuildContext context,
  WidgetRef ref, {
  String? accountId,
}) async {
  final drafts = await ref
      .read(draftRepositoryProvider)
      .listNewMessageDrafts(accountId: accountId);
  if (!context.mounted) return;
  if (drafts.isEmpty) {
    unawaited(context.push('/compose', extra: {'accountId': accountId}));
    return;
  }
  final accounts =
      await ref.read(accountRepositoryProvider).observeAccounts().first;
  if (!context.mounted) return;
  final choice = await showDialog<_ComposeChoice>(
    context: context,
    builder: (_) => _DraftChooserDialog(drafts: drafts, accounts: accounts),
  );
  if (choice == null || !context.mounted) return;
  final draft = choice.draft;
  if (draft == null) {
    unawaited(context.push('/compose', extra: {'accountId': accountId}));
    return;
  }
  unawaited(
    context.push(
      '/compose',
      extra: {'accountId': draft.accountId ?? accountId, 'draftId': draft.id},
    ),
  );
}

/// The dialog result: [draft] to resume, or null for a blank new message.
class _ComposeChoice {
  const _ComposeChoice(this.draft);

  final SavedDraft? draft;
}

class _DraftChooserDialog extends StatelessWidget {
  const _DraftChooserDialog({required this.drafts, required this.accounts});

  final List<SavedDraft> drafts;
  final List<Account> accounts;

  String _accountLabel(String? accountId) {
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) return '(no account)';
    return '${account.displayName} <${account.email}>';
  }

  @override
  Widget build(BuildContext context) {
    final title = drafts.length == 1
        ? 'You have an unsent draft'
        : 'You have ${drafts.length} unsent drafts';
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final d in drafts)
              ListTile(
                key: ValueKey('draft-${d.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  d.subjectText.isEmpty ? '(no subject)' : d.subjectText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'From: ${_accountLabel(d.accountId)}\n'
                  'To: ${d.toText.isEmpty ? '(no recipients)' : d.toText}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing: TextButton(
                  onPressed: () => Navigator.of(context).pop(_ComposeChoice(d)),
                  child: const Text('Open draft'),
                ),
                onTap: () => Navigator.of(context).pop(_ComposeChoice(d)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(const _ComposeChoice(null)),
          child: const Text('Create new message'),
        ),
      ],
    );
  }
}
