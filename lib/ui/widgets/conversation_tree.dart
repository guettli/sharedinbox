import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/conversation_tree.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

final _lineFmt = DateFormat('EEE, MMM d, HH:mm');

/// Reply tree for the conversation [email] belongs to, gathered across every
/// folder of the account (#754). Each message is one line naming its sender
/// ("From me" for the account's own messages), indented under the message it
/// replies to, with a folder badge so cross-folder copies (Inbox / Sent /
/// Archive) are distinguishable. The current message is highlighted;
/// tapping another opens it. Hidden when the conversation has fewer than two
/// messages.
class ConversationTree extends ConsumerWidget {
  const ConversationTree({
    super.key,
    required this.email,
    required this.onTapEmail,
  });

  final Email email;
  final void Function(EmailDetailNavItem) onTapEmail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadId = email.threadId;
    if (threadId == null) return const SizedBox.shrink();

    final emails =
        ref.watch(threadEmailsProvider((email.accountId, threadId))).value ??
            const <Email>[];
    if (emails.length < 2) return const SizedBox.shrink();

    final ownEmail = ref
        .watch(accountByIdProvider(email.accountId))
        .value
        ?.email
        .toLowerCase();

    final nodes = buildConversationTree(emails);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final node in _flatten(nodes))
            _line(context, ref, node, ownEmail),
        ],
      ),
    );
  }

  /// Pre-order flatten so indentation reflects reply depth.
  List<ConversationNode> _flatten(List<ConversationNode> nodes) {
    final out = <ConversationNode>[];
    void visit(List<ConversationNode> level) {
      for (final n in level) {
        out.add(n);
        visit(n.children);
      }
    }

    visit(nodes);
    return out;
  }

  Widget _line(
    BuildContext ctx,
    WidgetRef ref,
    ConversationNode node,
    String? ownEmail,
  ) {
    final m = node.email;
    final isCurrent = m.id == email.id;
    final sender = m.from.isNotEmpty ? m.from.first : null;
    final fromMe = ownEmail != null && sender?.email.toLowerCase() == ownEmail;
    // Name the sender, not the direction: in a conversation with several
    // people, or a shared mailbox where the mail was not addressed to this
    // account at all, "To me" told neither who wrote it nor the truth.
    final from = fromMe ? 'me' : (sender?.name ?? sender?.email ?? 'unknown');
    final date = m.sentAt != null ? _lineFmt.format(m.sentAt!) : '';
    final label = 'From $from · $date';
    final theme = Theme.of(ctx);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
      color: isCurrent ? theme.colorScheme.primary : null,
    );

    // Cap the visual indent so a pathologically deep chain stays readable.
    final indent = node.depth.clamp(0, 8) * AppSpacing.md;

    // A node of its own, so assistive tech can tell the lines apart and
    // activate one; otherwise the first line merges into the mail header.
    // `enabled` must be explicit: without it the Linux accessibility bridge
    // reports the button as disabled and refuses to activate it.
    return Semantics(
      container: true,
      button: !isCurrent,
      enabled: !isCurrent,
      selected: isCurrent,
      child: InkWell(
        onTap: isCurrent
            ? null
            : () => onTapEmail(
                  EmailDetailNavItem(
                    accountId: m.accountId,
                    mailboxPath: m.mailboxPath,
                    emailId: m.id,
                  ),
                ),
        child: Padding(
          padding: EdgeInsets.only(
            left: indent,
            top: AppSpacing.xs,
            bottom: AppSpacing.xs,
          ),
          child: Row(
            children: [
              Flexible(
                child:
                    Text(label, style: style, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: AppSpacing.sm),
              _FolderBadge(accountId: m.accountId, mailboxPath: m.mailboxPath),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small chip naming the folder a message lives in, so cross-folder copies of
/// the same conversation can be told apart at a glance.
class _FolderBadge extends ConsumerWidget {
  const _FolderBadge({required this.accountId, required this.mailboxPath});

  final String accountId;
  final String mailboxPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mailbox =
        ref.watch(mailboxByPathProvider((accountId, mailboxPath))).value;
    final label = mailbox?.displayPath ?? mailboxPath;
    if (label.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
