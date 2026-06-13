import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';

final _dateFmt = DateFormat('EEE, MMM d, HH:mm');

class ThreadDetailScreen extends ConsumerWidget {
  const ThreadDetailScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
    required this.threadId,
  });

  final String accountId;
  final String mailboxPath;
  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(emailRepositoryProvider);
    final prefs =
        ref.watch(userPreferencesProvider).value ?? const UserPreferences();
    final buttonAtBottom = prefs.mailViewButtonPosition == MenuPosition.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread'),
        automaticallyImplyLeading: !buttonAtBottom,
      ),
      bottomNavigationBar: buttonAtBottom ? _buildBackButtonBar(context) : null,
      body: StreamBuilder<List<Email>>(
        stream: repo.observeEmailsInThread(accountId, mailboxPath, threadId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final emails = snapshot.data ?? [];
          if (emails.isEmpty) {
            return const Center(child: Text('Thread not found or empty'));
          }

          return ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.sm),
            itemCount: emails.length,
            itemBuilder: (context, index) {
              final email = emails[index];
              return _EmailMessageCard(
                email: email,
                isLatest: index == emails.length - 1,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildBackButtonBar(BuildContext context) {
    return BottomAppBar(
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: () => context.pop(),
          ),
        ],
      ),
    );
  }
}

class _EmailMessageCard extends ConsumerStatefulWidget {
  const _EmailMessageCard({required this.email, required this.isLatest});
  final Email email;
  final bool isLatest;

  @override
  ConsumerState<_EmailMessageCard> createState() => _EmailMessageCardState();
}

class _EmailMessageCardState extends ConsumerState<_EmailMessageCard> {
  late Future<EmailBody> _bodyFuture;
  bool _expanded = false;
  bool _loadRemoteImages = false;

  @override
  void initState() {
    super.initState();
    _bodyFuture =
        ref.read(emailRepositoryProvider).getEmailBody(widget.email.id);
    _expanded = widget.isLatest;
    if (widget.email.isSeen == false) {
      unawaited(
        ref.read(emailRepositoryProvider).setFlag(widget.email.id, seen: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final trustedSenders =
        ref.watch(trustedImageSendersProvider).value ?? const <String>[];
    final senderEmail = widget.email.from.isNotEmpty
        ? widget.email.from.first.email.toLowerCase()
        : null;
    final isTrusted = senderEmail != null &&
        trustedSenders.any((p) => globMatch(senderEmail, p));

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            leading: CircleAvatar(
              child: Text(
                widget.email.from.isNotEmpty
                    ? widget.email.from.first.email[0].toUpperCase()
                    : '?',
              ),
            ),
            title: Text(
              widget.email.from.isNotEmpty
                  ? widget.email.from.first.toString()
                  : '(unknown)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              widget.email.sentAt != null
                  ? _dateFmt.format(widget.email.sentAt!)
                  : '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.email.isFlagged)
                  const Icon(
                    Icons.star,
                    color: Colors.amber,
                    size: AppIconSize.md,
                  ),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
          if (_expanded) _buildExpandedBody(isTrusted, senderEmail),
        ],
      ),
    );
  }

  Widget _buildExpandedBody(bool isTrusted, String? senderEmail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          FutureBuilder<EmailBody>(
            future: _bodyFuture,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'Failed to load email: ${snapshot.error}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final body = snapshot.data!;
              final hasHtml = (body.htmlBody ?? '').trim().isNotEmpty;
              final effectiveLoadImages = _loadRemoteImages || isTrusted;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasHtml) ...[
                    if (!effectiveLoadImages)
                      TextButton.icon(
                        icon: const Icon(
                          Icons.image_outlined,
                          size: AppIconSize.sm,
                        ),
                        label: const Text('Load remote images'),
                        onPressed: () {
                          setState(() => _loadRemoteImages = true);
                          if (senderEmail != null) {
                            unawaited(
                              ref
                                  .read(userPreferencesRepositoryProvider)
                                  .addTrustedImageSender(senderEmail),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                duration: const Duration(seconds: 3),
                                // SnackBar defaults to persist=true when an
                                // action is set, which disables auto-dismiss.
                                // Explicitly opt into duration-based dismiss.
                                persist: false,
                                content: const Text(
                                  'Images will be loaded automatically for this sender.',
                                ),
                                action: SnackBarAction(
                                  label: 'View',
                                  onPressed: () {
                                    if (mounted) {
                                      unawaited(
                                        context.push(
                                          '/accounts/trusted-senders',
                                          extra: senderEmail,
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    SecureEmailWebView(
                      htmlBody: body.htmlBody!,
                      loadRemoteImages: effectiveLoadImages,
                    ),
                  ] else
                    SelectableText(
                      body.textBody ?? '(no body text)',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.reply),
                        tooltip: 'Reply',
                        onPressed: () => _reply(context, body, replyAll: false),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: _delete,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void _reply(BuildContext context, EmailBody body, {required bool replyAll}) {
    final to =
        widget.email.from.isNotEmpty ? widget.email.from.first.email : '';
    final subject = (widget.email.subject?.startsWith('Re:') ?? false)
        ? widget.email.subject!
        : 'Re: ${widget.email.subject ?? ''}';

    unawaited(
      context.push(
        '/compose',
        extra: {
          'accountId': widget.email.accountId,
          'replyToEmailId': widget.email.id,
          'prefillTo': to,
          'prefillSubject': subject,
          'prefillBody': _quotedBody(body),
        },
      ),
    );
  }

  String _quotedBody(EmailBody body) {
    final date = widget.email.sentAt != null
        ? _dateFmt.format(widget.email.sentAt!)
        : '';
    final from = widget.email.from.isNotEmpty
        ? widget.email.from.first.toString()
        : '(unknown)';
    final text = body.textBody ?? htmlToPlain(body.htmlBody ?? '');
    final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
    return '\n\n— On $date, $from wrote:\n$quoted';
  }

  Future<void> _delete() async {
    final repo = ref.read(emailRepositoryProvider);
    // Fetch data first for IMAP undo support
    final original = await repo.getEmail(widget.email.id);

    final destPath = await repo.deleteEmail(widget.email.id);

    if (!mounted) return;
    if (original != null) {
      unawaited(
        ref.read(undoServiceProvider.notifier).pushAction(
              UndoAction(
                id: DateTime.now().toIso8601String(),
                accountId: widget.email.accountId,
                type: UndoType.delete,
                emailIds: [widget.email.id],
                sourceMailboxPath: widget.email.mailboxPath,
                destinationMailboxPath: destPath,
                originalEmails: [original],
              ),
            ),
      );
    }
  }
}
