import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';

/// All per-account actions surfaced from the long-press menu on
/// [AccountListScreen] and from the account home screen. Kept in one place so
/// both entry points navigate identically.
enum AccountAction {
  syncLog,
  verifySync,
  forceSync,
  edit,
  emailFiltersRemote,
  emailFiltersLocal,
  send,
  delete,
}

/// Whether to surface the "Remote email filters" (Sieve) entry for [account].
///
/// JMAP accounts always show it (Sieve over JMAP, no separate probe).
/// IMAP accounts hide it only when a previous ManageSieve probe failed
/// (manageSieveAvailable == false). Null means "not yet probed" — we
/// optimistically show it and let the menu disappear once the probe lands.
bool sieveSupported(Account account) {
  if (account.type == AccountType.jmap) return true;
  return account.manageSieveAvailable != false;
}

/// Runs [action] for [account]. Shows confirmation dialogs and snackbars
/// inline where the action requires them, so callers only need to dispatch.
Future<void> runAccountAction(
  BuildContext context,
  WidgetRef ref,
  Account account,
  AccountAction action,
) async {
  switch (action) {
    case AccountAction.syncLog:
      await context.push('/accounts/${account.id}/sync-log');
      break;
    case AccountAction.verifySync:
      unawaited(ref.read(reliabilityRunnerProvider).checkNow());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 5),
            content: Text('Starting sync verification...'),
          ),
        );
      }
      break;
    case AccountAction.forceSync:
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Force full re-sync?'),
          content: const Text(
            'This clears all locally-cached email metadata and mailboxes for '
            'this account, then re-syncs everything from the server. '
            'Previously downloaded email bodies and attachments are kept — '
            'only the metadata is re-fetched.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Force re-sync'),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        await context.push('/accounts/${account.id}/force-resync');
      }
      break;
    case AccountAction.edit:
      await context.push('/accounts/${account.id}/edit');
      break;
    case AccountAction.emailFiltersRemote:
      await context.push('/accounts/${account.id}/sieve');
      break;
    case AccountAction.emailFiltersLocal:
      await context.push('/accounts/${account.id}/sieve/local');
      break;
    case AccountAction.send:
      await context.push('/accounts/send');
      break;
    case AccountAction.delete:
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete account'),
          content: Text(
            'Remove "${account.displayName}" (${account.email})? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if ((confirmed ?? false) && context.mounted) {
        await ref.read(accountRepositoryProvider).removeAccount(account.id);
      }
      break;
  }
}

/// Navigates to a one-on-one account comparison view.
Future<void> openAccountCompare(
  BuildContext context,
  String accountId,
  String otherAccountId,
) {
  return context.push('/accounts/$accountId/compare/$otherAccountId');
}
