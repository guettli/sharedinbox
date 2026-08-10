import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/folder_tree_picker.dart';

/// Compact button that opens a [showFolderTreePicker] and reports the pick.
///
/// Renders the currently-picked mailbox's human-readable [Mailbox.displayPath]
/// (never the raw JMAP path/opaque id) and, when the stored [value] no longer
/// matches any known mailbox, shows the fallback label in the error colour so
/// stale references are visible. Callers decide what to persist — see
/// [onPicked], which receives both the resolved [Mailbox] (may be null if the
/// pick doesn't match anything the stream returned) and the raw display path
/// the picker emitted.
///
/// The Sieve editor stores `fileinto` values as [Mailbox.displayPath]; the
/// advanced-search folder condition stores [Mailbox.path] so the LIKE against
/// `emails.mailbox_path` matches. Both are supported by [resolveMailbox],
/// which tries display-path and path in turn.
class MailboxPickerButton extends ConsumerWidget {
  const MailboxPickerButton({
    super.key,
    required this.accountId,
    required this.value,
    required this.onPicked,
    this.onCreate,
    this.placeholder = 'Select folder…',
  });

  /// Account whose mailboxes the picker should list. `null` opens the picker
  /// over all accounts — used by cross-account advanced search.
  final String? accountId;

  /// Currently persisted value; resolved via [resolveMailbox] to render a
  /// readable label. Empty string means "no folder picked yet".
  final String value;

  /// Fired after the user picks a folder. [picked] is the resolved mailbox
  /// (looked up by [displayPath]) or `null` if the stream doesn't contain a
  /// matching row. [displayPath] is the raw string [showFolderTreePicker]
  /// returned.
  final void Function(Mailbox? picked, String displayPath) onPicked;

  /// When non-null, the picker exposes an inline "new folder" affordance.
  final FolderCreateCallback? onCreate;

  /// Text shown when [value] is empty.
  final String placeholder;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(mailboxRepositoryProvider);
    final picked = await showFolderTreePicker(
      context,
      mailboxesStream: repo.observeMailboxes(accountId),
      initialPath: value.isEmpty ? null : value,
      onCreate: onCreate,
    );
    if (picked == null) return;
    final mailboxes = await repo.observeMailboxes(accountId).first;
    onPicked(resolveMailbox(mailboxes, picked), picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Mailbox>>(
      stream: ref.watch(mailboxRepositoryProvider).observeMailboxes(accountId),
      builder: (ctx, snap) {
        final mailboxes = snap.data ?? const <Mailbox>[];
        final match = resolveMailbox(mailboxes, value);
        final label =
            value.isEmpty ? placeholder : (match?.displayPath ?? value);
        final isUnknown = value.isNotEmpty && match == null;
        return OutlinedButton.icon(
          onPressed: mailboxes.isEmpty ? null : () => _pick(context, ref),
          icon: const Icon(Icons.folder_outlined, size: AppIconSize.sm),
          label: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style:
                  isUnknown ? TextStyle(color: theme.colorScheme.error) : null,
            ),
          ),
          style: OutlinedButton.styleFrom(
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
      },
    );
  }

  /// Looks up the [Mailbox] whose `displayPath` or `path` equals [value].
  /// Tries `displayPath` first so a match on the human-readable form wins
  /// over a legacy raw-path collision on IMAP accounts (where the two are
  /// equal anyway).
  static Mailbox? resolveMailbox(List<Mailbox> mailboxes, String value) {
    for (final m in mailboxes) {
      if (m.displayPath == value) return m;
    }
    for (final m in mailboxes) {
      if (m.path == value) return m;
    }
    return null;
  }
}
