import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'package:sharedinbox/core/filter/similar_filter.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/platform/raw_email_downloader.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/core/utils/list_unsubscribe.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/email_headers_dialog.dart';
import 'package:sharedinbox/ui/widgets/error_boundary.dart';
import 'package:sharedinbox/ui/widgets/linkified_text.dart';
import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';
import 'package:url_launcher/url_launcher.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId, this.nav});
  final String emailId;

  /// Ordered list of sibling emails from the caller (mailbox list, search
  /// results, address filter, …). Powers the prev/next controls and the
  /// after-action "next message" hop. `null` for deep links / notifications
  /// — the screen falls back to walking the current mailbox's individual
  /// emails in that case.
  final EmailDetailNav? nav;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  bool _isFlagged = false;
  bool _loadRemoteImages = false;
  final Set<String> _downloading = {};
  bool _notesSynced = false;

  /// Fallback nav resolved from `observeEmails(mailbox)` when [widget.nav]
  /// is null (deep links, notifications). Cached per emailId so the buttons
  /// don't refetch on every rebuild.
  EmailDetailNav? _fallbackNav;
  String? _fallbackNavForEmailId;
  bool _fallbackNavLoading = false;

  @override
  void didUpdateWidget(covariant EmailDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emailId != widget.emailId) {
      // A different mail is now on screen — its neighbours differ, so drop
      // the cached fallback list. The provided [widget.nav] indexes by id,
      // so no invalidation needed for that path.
      _fallbackNav = null;
      _fallbackNavForEmailId = null;
    }
  }

  /// Returns the active nav — either the one handed in by the caller or a
  /// mailbox-scoped fallback fetched lazily from the repo. Returns null while
  /// the fallback is still in flight or when no header is available yet.
  EmailDetailNav? _activeNav(Email? header) {
    if (widget.nav != null) return widget.nav;
    if (header == null) return null;
    if (_fallbackNavForEmailId == widget.emailId && _fallbackNav != null) {
      return _fallbackNav;
    }
    if (!_fallbackNavLoading) {
      _fallbackNavLoading = true;
      unawaited(_loadFallbackNav(header));
    }
    return null;
  }

  Future<void> _loadFallbackNav(Email header) async {
    try {
      final emails = await ref
          .read(emailRepositoryProvider)
          .observeEmails(header.accountId, header.mailboxPath)
          .first;
      if (!mounted) return;
      setState(() {
        _fallbackNav = EmailDetailNav.fromEmails(emails);
        _fallbackNavForEmailId = widget.emailId;
        _fallbackNavLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _fallbackNavLoading = false);
    }
  }

  void _goToNeighbour(EmailDetailNavItem target) {
    if (!mounted) return;
    context.go(
      '/accounts/${target.accountId}'
      '/mailboxes/${Uri.encodeComponent(target.mailboxPath)}'
      '/emails/${Uri.encodeComponent(target.emailId)}',
      extra: widget.nav,
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final detail = ref.watch(emailDetailProvider(widget.emailId));

    ref.listen<AsyncValue<(Email?, EmailBody)>>(
      emailDetailProvider(widget.emailId),
      (_, next) {
        final email = next.value?.$1;
        if (email != null && mounted) {
          setState(() => _isFlagged = email.isFlagged);
        }
        if (!_notesSynced && email?.messageId != null) {
          _notesSynced = true;
          unawaited(
            ref.read(noteRepositoryProvider).syncNotes(
                  email!.accountId,
                  email.messageId!,
                ),
          );
        }
      },
    );

    final header = detail.value?.$1;
    final body = detail.value?.$2;

    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final activeNav = _activeNav(header);
    final prevItem = activeNav?.prevOf(widget.emailId);
    final nextItem = activeNav?.nextOf(widget.emailId);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isMobile,
        actions: [
          if (!isMobile) ...[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous message',
              onPressed:
                  prevItem == null ? null : () => _goToNeighbour(prevItem),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next message',
              onPressed:
                  nextItem == null ? null : () => _goToNeighbour(nextItem),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_replyWithRecipientDialog(context, header, body));
                  },
          ),
          _ActionMorphButton(
            icon: Icons.archive,
            tooltip: 'Archive',
            color: const Color(0xFF2E7D32),
            onPressed: header == null
                ? null
                : () {
                    unawaited(HapticFeedback.mediumImpact());
                    unawaited(_archive(context, header));
                  },
          ),
          _ActionMorphButton(
            icon: Icons.delete,
            tooltip: 'Delete',
            color: Theme.of(context).colorScheme.error,
            onPressed: () async {
              unawaited(HapticFeedback.heavyImpact());
              final nextEmail = await _getNextEmailIfNeeded(header);
              final destPath = await repo.deleteEmail(widget.emailId);

              if (header != null) {
                // Fire-and-forget so the state update (which is applied
                // synchronously inside pushAction) reaches UndoShell before
                // we start the route transition. Matches _archive / _markAsSpam.
                unawaited(
                  ref.read(undoServiceProvider.notifier).pushAction(
                        UndoAction(
                          id: DateTime.now().toIso8601String(),
                          accountId: header.accountId,
                          type: UndoType.delete,
                          emailIds: [widget.emailId],
                          sourceMailboxPath: header.mailboxPath,
                          destinationMailboxPath: destPath,
                          originalEmails: [header],
                        ),
                      ),
                );
              }

              if (context.mounted) _navigateTo(context, header, nextEmail);
            },
          ),
          IconButton(
            icon: Icon(
              _isFlagged ? Icons.star : Icons.star_border,
              color: _isFlagged ? Colors.amber : null,
            ),
            tooltip: _isFlagged ? 'Unflag' : 'Flag',
            onPressed: () async {
              final next = !_isFlagged;
              await repo.setFlag(widget.emailId, flagged: next);
              if (mounted) setState(() => _isFlagged = next);
            },
          ),
          _ActionMorphButton(
            icon: Icons.report_outlined,
            tooltip: 'Mark as spam',
            color: const Color(0xFFE65100),
            onPressed: header == null
                ? null
                : () {
                    unawaited(HapticFeedback.mediumImpact());
                    unawaited(_markAsSpam(context, header));
                  },
          ),
          PopupMenuButton<String>(
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'forward', child: Text('Forward')),
              const PopupMenuItem(value: 'move', child: Text('Move to folder')),
              const PopupMenuItem(value: 'snooze', child: Text('Snooze')),
              const PopupMenuItem(
                value: 'find_similar',
                child: Text('Find similar emails'),
              ),
              const PopupMenuItem(
                value: 'mark_unread',
                child: Text('Mark as unread'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'headers',
                child: Text('Show Mail Headers'),
              ),
              const PopupMenuItem(
                value: 'structure',
                child: Text('Show Mail Structure'),
              ),
              const PopupMenuItem(value: 'rfc', child: Text('Show Raw Email')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'bug_report',
                child: Text('Report a Bug'),
              ),
            ],
            onSelected: (value) async {
              if (value == 'forward' && header != null) {
                unawaited(_forward(context, header, body));
              } else if (value == 'move' && header != null) {
                unawaited(_moveTo(context, header));
              } else if (value == 'snooze' && header != null) {
                unawaited(_snooze(context, header));
              } else if (value == 'find_similar' && header != null) {
                unawaited(
                  context.push('/search', extra: similarFilterFor(header)),
                );
              } else if (value == 'mark_unread') {
                final nextEmail = await _getNextEmailIfNeeded(header);
                await repo.setFlag(widget.emailId, seen: false);
                if (context.mounted) _navigateTo(context, header, nextEmail);
              } else if (value == 'headers' && body != null && header != null) {
                unawaited(_showHeaders(context, body, header.accountId));
              } else if (value == 'structure' && body != null) {
                unawaited(_showStructure(context, body));
              } else if (value == 'rfc') {
                unawaited(_showRaw(context, header));
              } else if (value == 'bug_report') {
                unawaited(
                  context.push('/bug-report?emailId=${widget.emailId}'),
                );
              }
            },
          ),
        ],
      ),
      body: _wrapWithSwipe(
        isMobile: isMobile,
        prev: prevItem,
        next: nextItem,
        child: detail.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (d) {
            final trusted = ref.watch(trustedImageSendersProvider).value ??
                const <String>[];
            return _buildBody(context, d.$1, d.$2, trusted);
          },
        ),
      ),
    );
  }

  /// On mobile, wraps [child] in a horizontal drag detector so a fling left
  /// advances to the next message and a fling right returns to the previous
  /// one. Uses [HitTestBehavior.deferToChild] so vertical scrolls in the mail
  /// body remain unaffected (#292).
  Widget _wrapWithSwipe({
    required bool isMobile,
    required EmailDetailNavItem? prev,
    required EmailDetailNavItem? next,
    required Widget child,
  }) {
    if (!isMobile) return child;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        // Match the ~300 px/s threshold used elsewhere in the app so
        // accidental drift while scrolling never triggers navigation.
        if (velocity <= -300 && next != null) {
          unawaited(HapticFeedback.selectionClick());
          _goToNeighbour(next);
        } else if (velocity >= 300 && prev != null) {
          unawaited(HapticFeedback.selectionClick());
          _goToNeighbour(prev);
        }
      },
      child: child,
    );
  }

  Widget _buildBody(
    BuildContext ctx,
    Email? header,
    EmailBody body,
    List<String> trustedSenders,
  ) {
    final hasHtml = (body.htmlBody ?? '').trim().isNotEmpty;
    final senderEmail = header?.from.isNotEmpty == true
        ? header!.from.first.email.toLowerCase()
        : null;
    final isTrusted = senderEmail != null &&
        trustedSenders.any((p) => globMatch(senderEmail, p));
    final effectiveLoadImages = _loadRemoteImages || isTrusted;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (header != null) ...[_buildHeader(ctx, header), const Divider()],
        if (hasHtml) ...[
          if (!effectiveLoadImages)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: AppIconSize.sm),
                  label: const Text('Load remote images'),
                  onPressed: () {
                    setState(() => _loadRemoteImages = true);
                    if (senderEmail != null) {
                      unawaited(
                        ref
                            .read(userPreferencesRepositoryProvider)
                            .addTrustedImageSender(senderEmail),
                      );
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 3),
                          // SnackBar defaults to persist=true when an action
                          // is set, which disables the auto-dismiss timer.
                          // Explicitly opt back into duration-based dismiss.
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
              ),
            ),
          ErrorBoundary(
            label: 'Email body',
            child: SecureEmailWebView(
              htmlBody: body.htmlBody!,
              loadRemoteImages: effectiveLoadImages,
            ),
          ),
        ] else
          LinkifiedText(
            body.textBody ?? '',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        if (header?.messageId != null) _buildNotesSection(ctx, header!),
        if (body.attachments.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(
              'Attachments',
              style: Theme.of(ctx).textTheme.titleSmall,
            ),
          ),
          for (final att in body.attachments)
            ListTile(
              dense: true,
              leading: const Icon(Icons.attach_file),
              title: Text(att.filename),
              subtitle: Text('${att.contentType} • ${fmtSize(att.size)}'),
              trailing: _downloading.contains(att.filename)
                  ? const SizedBox(
                      width: AppIconSize.lg,
                      height: AppIconSize.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Download and open',
                      onPressed: () => _downloadAndOpen(att),
                    ),
            ),
        ],
      ],
    );
  }

  Future<EmailDetailNavItem?> _getNextEmailIfNeeded(Email? header) async {
    if (header == null) return null;
    final prefs = ref.read(userPreferencesProvider).value;
    final action =
        prefs?.afterMailViewAction ?? AfterMailViewAction.nextMessage;
    if (action != AfterMailViewAction.nextMessage) return null;

    // Prefer the caller-supplied nav so "next" respects the source list
    // (search results, address filter, …) and steps through individual mails
    // rather than jumping thread-by-thread across the whole mailbox (#292).
    final providedNav = widget.nav;
    if (providedNav != null) return providedNav.nextOf(widget.emailId);

    // Fallback for deep links: walk this mailbox's individual mails, keeping
    // the historical guard that limits the hop to the same folder — the
    // stream shouldn't leak cross-folder rows, but a client-side filter still
    // matters when a mailbox rename briefly overlaps (#293).
    final emails = (await ref
            .read(emailRepositoryProvider)
            .observeEmails(header.accountId, header.mailboxPath)
            .first)
        .where((e) => e.mailboxPath == header.mailboxPath)
        .toList();

    final idx = emails.indexWhere((e) => e.id == widget.emailId);
    if (idx >= 0 && idx + 1 < emails.length) {
      final n = emails[idx + 1];
      return EmailDetailNavItem(
        accountId: n.accountId,
        mailboxPath: n.mailboxPath,
        emailId: n.id,
      );
    }
    return null;
  }

  void _navigateTo(
    BuildContext context,
    Email? header,
    EmailDetailNavItem? next,
  ) {
    if (!context.mounted) return;
    if (next != null) {
      context.go(
        '/accounts/${next.accountId}'
        '/mailboxes/${Uri.encodeComponent(next.mailboxPath)}'
        '/emails/${Uri.encodeComponent(next.emailId)}',
        extra: widget.nav,
      );
    } else {
      context.pop();
    }
  }

  Future<void> _downloadAndOpen(EmailAttachment att) async {
    setState(() => _downloading.add(att.filename));
    try {
      final path = await ref
          .read(emailRepositoryProvider)
          .downloadAttachment(widget.emailId, att);
      await OpenFilex.open(path);
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'email.attachment.open_failed',
              'Opening attachment failed',
              emailId: widget.emailId,
              data: {'filename': att.filename},
              error: e,
              stack: stack,
            ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Opening file failed: $e')));
    } finally {
      if (mounted) setState(() => _downloading.remove(att.filename));
    }
  }

  Widget _buildNotesSection(BuildContext ctx, Email header) {
    final messageId = header.messageId!;
    final notes = ref.watch(notesProvider((header.accountId, messageId)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                'Notes',
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add, size: AppIconSize.sm),
              label: const Text('Add'),
              onPressed: () => unawaited(_addNoteDialog(ctx, header)),
            ),
          ],
        ),
        notes.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Text('Error loading notes: $e'),
          data: (list) {
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  'No notes yet.',
                  style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              );
            }
            return Column(
              children: [
                for (final note in list) _buildNoteRow(ctx, note),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildNoteRow(BuildContext ctx, EmailNote note) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(note.noteText),
      subtitle: Text(
        DateFormat('MMM d, HH:mm').format(note.createdAt),
        style: Theme.of(ctx).textTheme.bodySmall,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: AppIconSize.md),
        tooltip: 'Delete note',
        onPressed: () {
          unawaited(ref.read(noteRepositoryProvider).deleteNote(note.id));
        },
      ),
    );
  }

  Future<void> _addNoteDialog(BuildContext context, Email header) async {
    final messageId = header.messageId;
    if (messageId == null) return;

    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add note'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Type a note…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    final text = ctrl.text.trim();
    ctrl.dispose();
    if (confirmed != true || text.isEmpty) return;
    if (!context.mounted) return;

    await ref.read(noteRepositoryProvider).addNote(
          header.accountId,
          messageId,
          text,
        );
  }

  Widget _buildHeader(BuildContext ctx, Email email) {
    if (email.from.isEmpty || email.to.isEmpty) {
      unawaited(
        ref.read(appLoggerProvider).warn(
          'email.header.missing_addresses',
          'Email has empty from/to on open',
          accountId: email.accountId,
          emailId: email.id,
          data: {
            'fromEmpty': email.from.isEmpty,
            'toEmpty': email.to.isEmpty,
          },
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          email.subject ?? '(no subject)',
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          email.from.isNotEmpty
              ? 'From: ${email.from.first}'
              : 'From: (unknown)',
          style: Theme.of(ctx).textTheme.bodySmall,
        ),
        Text(
          email.to.isNotEmpty
              ? 'To: ${email.to.map((a) => a.toString()).join(', ')}'
              : 'To: (no recipients)',
          style: Theme.of(ctx).textTheme.bodySmall,
        ),
        if (email.sentAt != null)
          Text(
            _dateFmt.format(email.sentAt!),
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        if (email.listUnsubscribeHeader != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _UnsubscribeChip(email: email),
          ),
      ],
    );
  }

  Future<String> _quotedBody(Email header, EmailBody? body) async {
    final date = header.sentAt != null ? _dateFmt.format(header.sentAt!) : '';
    final from =
        header.from.isNotEmpty ? header.from.first.toString() : '(unknown)';
    final rawText = body?.textBody;
    final text = (rawText != null && rawText.isNotEmpty)
        ? rawText
        : await compute(htmlToPlain, body?.htmlBody ?? '');
    final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
    return '\n\n— On $date, $from wrote:\n$quoted';
  }

  Future<void> _replyWithRecipientDialog(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    final account =
        await ref.read(accountRepositoryProvider).getAccount(header.accountId);
    final ownEmail = account?.email.toLowerCase() ?? '';

    final seen = <String>{};
    final candidates = <_Candidate>[];

    void addIfNew(EmailAddress addr, _Placement defaultPlacement) {
      final key = addr.email.toLowerCase();
      if (key == ownEmail || seen.contains(key)) return;
      seen.add(key);
      candidates.add(_Candidate(addr, defaultPlacement));
    }

    for (final addr in header.from) {
      addIfNew(addr, _Placement.to);
    }
    for (final addr in header.to) {
      addIfNew(addr, _Placement.to);
    }
    for (final addr in header.cc) {
      addIfNew(addr, _Placement.cc);
    }

    if (!context.mounted) return;

    if (candidates.length <= 1) {
      final to = candidates
          .where((c) => c.placement == _Placement.to)
          .map((c) => c.address.email)
          .join(', ');
      final cc = candidates
          .where((c) => c.placement == _Placement.cc)
          .map((c) => c.address.email)
          .join(', ');
      await _composeReply(context, header, body, to: to, cc: cc);
      return;
    }

    final confirmed = await showDialog<List<_Candidate>>(
      context: context,
      builder: (ctx) => _ReplyAllDialog(candidates: candidates),
    );

    if (confirmed == null || !context.mounted) return;

    final to = confirmed
        .where((c) => c.placement == _Placement.to)
        .map((c) => c.address.email)
        .join(', ');
    final cc = confirmed
        .where((c) => c.placement == _Placement.cc)
        .map((c) => c.address.email)
        .join(', ');
    await _composeReply(context, header, body, to: to, cc: cc);
  }

  Future<void> _composeReply(
    BuildContext context,
    Email header,
    EmailBody? body, {
    required String to,
    required String cc,
  }) async {
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    final quoted = await _quotedBody(header, body);
    if (!context.mounted) return;
    unawaited(
      context.push(
        '/compose',
        extra: {
          'replyToEmailId': widget.emailId,
          'prefillTo': to,
          'prefillSubject': subject,
          'prefillBody': quoted,
          if (cc.isNotEmpty) 'prefillCc': cc,
        },
      ),
    );
  }

  Future<void> _archive(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'archive',
      dialogTitle: 'No archive folder found',
      createFolderName: 'Archive',
    );

    if (mailbox == null || !context.mounted) return;

    await ref
        .read(emailRepositoryProvider)
        .moveEmail(widget.emailId, mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
              destinationMailboxRole: 'archive',
              originalEmails: [header],
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  Future<void> _markAsSpam(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'junk',
      dialogTitle: 'No spam folder found',
      createFolderName: 'Junk',
    );

    if (mailbox == null || !context.mounted) return;

    await ref
        .read(emailRepositoryProvider)
        .moveEmail(widget.emailId, mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
              destinationMailboxRole: 'junk',
              originalEmails: [header],
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  Future<void> _forward(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    final subject = (header.subject?.startsWith('Fwd:') ?? false)
        ? header.subject!
        : 'Fwd: ${header.subject ?? ''}';
    final quoted = await _quotedBody(header, body);
    if (!context.mounted) return;
    unawaited(
      context.push(
        '/compose',
        extra: {'prefillSubject': subject, 'prefillBody': quoted},
      ),
    );
  }

  Future<String?> _promptNewFolderName(BuildContext context) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create new folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Folder name'),
            textCapitalization: TextCapitalization.words,
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(ctx, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) Navigator.pop(ctx, name);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _moveTo(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);

    final mailboxRepo = ref.read(mailboxRepositoryProvider);
    final mailboxes =
        await mailboxRepo.observeMailboxes(header.accountId).first;

    // Remove the current mailbox from the list.
    final destinations =
        mailboxes.where((m) => m.path != header.mailboxPath).toList();

    if (!context.mounted) return;

    const createNewSentinel = '__create_new__';

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              'Move to…',
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Create new folder…'),
            onTap: () => Navigator.pop(ctx, createNewSentinel),
          ),
        ],
      ),
    );

    if (chosen == null || !context.mounted) return;

    String destination = chosen;
    if (chosen == createNewSentinel) {
      final name = await _promptNewFolderName(context);
      if (name == null || !context.mounted) return;
      final mailbox = await mailboxRepo.createMailbox(header.accountId, name);
      destination = mailbox.path;
    }

    await ref
        .read(emailRepositoryProvider)
        .moveEmail(widget.emailId, destination);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: destination,
              originalEmails: [header],
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  Future<void> _snooze(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final until = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (ctx) => const SnoozePicker(),
    );
    if (until == null || !context.mounted) return;

    final repo = ref.read(emailRepositoryProvider);
    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: header.accountId,
      type: UndoType.snooze,
      emailIds: [widget.emailId],
      sourceMailboxPath: header.mailboxPath,
      originalEmails: [header],
    );
    unawaited(ref.read(undoServiceProvider.notifier).pushAction(action));
    await repo.snoozeEmail(widget.emailId, until);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            'Snoozed until ${DateFormat('MMM d, HH:mm').format(until)}',
          ),
        ),
      );
      _navigateTo(context, header, nextEmail);
    }
  }

  Future<void> _showRaw(BuildContext context, Email? header) async {
    final String raw;
    try {
      raw = await ref
          .read(emailRepositoryProvider)
          .fetchRawRfc822(widget.emailId);
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'email.raw.fetch_failed',
              'Failed to fetch raw email',
              accountId: header?.accountId,
              emailId: widget.emailId,
              error: e,
              stack: stack,
            ),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to fetch raw email: $e')));
      return;
    }

    if (!context.mounted) return;

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Raw Email'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fmtSize(raw.length),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      raw,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: raw));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                }
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () async {
                await _downloadRaw(ctx, header, raw);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Download'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadRaw(
    BuildContext context,
    Email? header,
    String raw,
  ) async {
    try {
      final filename = _rawEmailFilename(header?.subject);
      final saved = await saveRawEmail(filename: filename, content: raw);
      if (!context.mounted) return;
      // On platforms that wrote to a public, system-indexed location
      // (Android Downloads), offer "Open" — opening the file is what makes
      // it appear in the system file picker's "Recently used" list.
      // Elsewhere fall back to "Share" so the user can still hand the file
      // off to another app.
      final action = saved.isPublic
          ? SnackBarAction(
              label: 'Open',
              onPressed: () => OpenFilex.open(saved.path),
            )
          : SnackBarAction(
              label: 'Share',
              onPressed: () => SharePlus.instance.share(
                ShareParams(files: [XFile(saved.path)]),
              ),
            );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // SnackBar defaults to persist=true when an action is set, which
          // disables the auto-dismiss timer. Explicitly opt back into
          // duration-based dismiss so the "Saved" snack bar slides away on
          // its own while the Open/Share action button still works.
          persist: false,
          content: Text('Saved ${saved.displayLocation}'),
          action: action,
        ),
      );
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'email.raw.download_failed',
              'Saving raw email failed',
              accountId: header?.accountId,
              emailId: widget.emailId,
              error: e,
              stack: stack,
            ),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  static String _rawEmailFilename(String? subject) {
    final sanitized = (subject ?? 'email')
        .replaceAll(RegExp(r'[^\w\s-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    final base = sanitized.isEmpty ? 'email' : sanitized;
    final clipped = base.length > 120 ? base.substring(0, 120) : base;
    return '$clipped.eml';
  }

  /// Forces a fresh fetch of the body from the server, bypassing the local
  /// cache. Used when the cached row is missing fields (headers, mimeTree)
  /// that earlier sync versions did not store. Shows a progress snackbar
  /// while the fetch is in flight and returns null on error.
  Future<EmailBody?> _refetchBody(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = messenger.showSnackBar(
      const SnackBar(
        duration: Duration(minutes: 1),
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: AppSpacing.sm),
            Text('Fetching mail details…'),
          ],
        ),
      ),
    );
    try {
      return await ref
          .read(emailRepositoryProvider)
          .getEmailBody(widget.emailId, forceRefresh: true);
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'email.body.refetch_failed',
              'Failed to fetch mail details',
              emailId: widget.emailId,
              error: e,
              stack: stack,
            ),
      );
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to fetch mail details: $e')),
        );
      }
      return null;
    } finally {
      controller.close();
    }
  }

  Future<void> _showHeaders(
    BuildContext context,
    EmailBody body,
    String accountId,
  ) async {
    var effective = body;
    if (effective.headers.isEmpty) {
      effective = await _refetchBody(context) ?? effective;
      if (!context.mounted) return;
      if (effective.headers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 5),
            content: Text('Server did not return headers for this message.'),
          ),
        );
        return;
      }
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => EmailHeadersDialog(
          headers: effective.headers,
          accountId: accountId,
        ),
      ),
    );
  }

  Future<void> _showStructure(BuildContext context, EmailBody body) async {
    var effective = body;
    var tree = effective.mimeTree;
    if (tree == null) {
      effective = await _refetchBody(context) ?? effective;
      if (!context.mounted) return;
      tree = effective.mimeTree;
      if (tree == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: const Text(
              'Server did not return MIME structure for this message.',
            ),
            action: SnackBarAction(
              label: 'View raw email',
              onPressed: () {
                unawaited(_showRaw(context, null));
              },
            ),
          ),
        );
        return;
      }
    }

    final rows = <_MimeRow>[];
    _flattenMimeTree(tree, 0, rows);

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Mail Structure'),
              leading: const CloseButton(),
            ),
            body: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (ctx, i) {
                final row = rows[i];
                return Container(
                  color: i.isEven
                      ? Theme.of(ctx).colorScheme.surfaceContainerHighest
                      : Theme.of(ctx).colorScheme.surface,
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.xs,
                    horizontal: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: row.depth * AppSpacing.lg),
                      Expanded(
                        child: Text(
                          row.label,
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

enum _Placement { to, cc, skip }

class _Candidate {
  _Candidate(this.address, this.placement);
  final EmailAddress address;
  _Placement placement;
}

class _ReplyAllDialog extends StatefulWidget {
  const _ReplyAllDialog({required this.candidates});
  final List<_Candidate> candidates;

  @override
  State<_ReplyAllDialog> createState() => _ReplyAllDialogState();
}

class _ReplyAllDialogState extends State<_ReplyAllDialog> {
  late final List<_Candidate> _candidates;

  @override
  void initState() {
    super.initState();
    _candidates = [
      for (final c in widget.candidates) _Candidate(c.address, c.placement),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reply All'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in _candidates)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.address.toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SegmentedButton<_Placement>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _Placement.to, label: Text('To')),
                        ButtonSegment(value: _Placement.cc, label: Text('Cc')),
                        ButtonSegment(
                          value: _Placement.skip,
                          label: Text('Skip'),
                        ),
                      ],
                      selected: {c.placement},
                      onSelectionChanged: (s) =>
                          setState(() => c.placement = s.first),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _candidates),
          child: const Text('Reply'),
        ),
      ],
    );
  }
}

class _MimeRow {
  const _MimeRow(this.depth, this.label);
  final int depth;
  final String label;
}

void _flattenMimeTree(MimePart part, int depth, List<_MimeRow> out) {
  final parts = <String>[part.contentType];
  if (part.filename != null) parts.add('"${part.filename}"');
  if (part.size != null) parts.add(fmtSize(part.size!));
  if (part.encoding != null) parts.add(part.encoding!);
  out.add(_MimeRow(depth, parts.join('  ')));
  for (final child in part.children) {
    _flattenMimeTree(child, depth + 1, out);
  }
}

class _UnsubscribeChip extends ConsumerStatefulWidget {
  const _UnsubscribeChip({required this.email});
  final Email email;

  @override
  ConsumerState<_UnsubscribeChip> createState() => _UnsubscribeChipState();
}

class _UnsubscribeChipState extends ConsumerState<_UnsubscribeChip> {
  bool _sending = false;

  Future<void> _onTap(BuildContext context, List<Uri> uris) async {
    final chosen = uris.length == 1
        ? await _confirmSingle(context, uris.single)
        : await _chooseFromMany(context, uris);
    if (chosen == null) return;
    if (!context.mounted) return;

    if (chosen.scheme == 'mailto') {
      await _sendUnsubscribeEmail(context, chosen);
      return;
    }

    final ok = await launchUrl(chosen, mode: LaunchMode.externalApplication);
    if (ok || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open unsubscribe link')),
    );
  }

  Future<Uri?> _confirmSingle(BuildContext context, Uri uri) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: Text(_describe(uri)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unsubscribe'),
          ),
        ],
      ),
    );
    return confirmed == true ? uri : null;
  }

  Future<Uri?> _chooseFromMany(BuildContext context, List<Uri> uris) {
    return showDialog<Uri>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final uri in uris)
                ListTile(
                  leading: Icon(_iconFor(uri)),
                  title: Text(_actionLabel(uri)),
                  subtitle: Text(_target(uri)),
                  onTap: () => Navigator.pop(ctx, uri),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  static String _describe(Uri uri) {
    return uri.scheme == 'mailto'
        ? 'Send an unsubscribe email to:\n${uri.path}'
        : 'Open the unsubscribe page:\n$uri';
  }

  static String _actionLabel(Uri uri) {
    return uri.scheme == 'mailto'
        ? 'Send unsubscribe email'
        : 'Open unsubscribe page';
  }

  static String _target(Uri uri) =>
      uri.scheme == 'mailto' ? uri.path : uri.toString();

  static IconData _iconFor(Uri uri) =>
      uri.scheme == 'mailto' ? Icons.email_outlined : Icons.open_in_new;

  Future<void> _sendUnsubscribeEmail(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      final accountId = widget.email.accountId;
      final account =
          await ref.read(accountRepositoryProvider).getAccount(accountId);
      if (account == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Account not found')),
        );
        return;
      }
      final recipients = uri.path
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map((e) => EmailAddress(email: e))
          .toList();
      final draft = EmailDraft(
        from: EmailAddress(name: account.displayName, email: account.email),
        to: recipients,
        cc: const [],
        subject: uri.queryParameters['subject'] ?? 'unsubscribe',
        body: uri.queryParameters['body'] ?? '',
      );
      await ref.read(emailRepositoryProvider).sendEmail(accountId, draft);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Unsubscribe email sent')),
      );
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'email.unsubscribe.send_failed',
              'Failed to send unsubscribe email',
              accountId: widget.email.accountId,
              emailId: widget.email.id,
              error: e,
              stack: stack,
            ),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to send unsubscribe: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uris = parseListUnsubscribeUris(widget.email.listUnsubscribeHeader);
    if (uris.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: uris.map((u) => u.toString()).join('\n'),
      child: ActionChip(
        avatar: _sending
            ? const SizedBox(
                width: AppIconSize.sm,
                height: AppIconSize.sm,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.unsubscribe_outlined, size: AppIconSize.sm),
        label: const Text('Unsubscribe'),
        onPressed: _sending ? null : () => _onTap(context, uris),
      ),
    );
  }
}

/// Action button used for destructive top-bar actions (archive / delete /
/// spam). Always visible: a tinted, coloured circular badge that identifies
/// the action at rest, so a mis-tap between the three neighbouring icons is
/// obvious even before the SnackBar / banner appears.
///
/// On tap the badge saturates to full colour, the icon inverts to white,
/// and the whole button scales up ~1.6× with an ease-out bounce before
/// settling back — a much more emphatic pulse than the old 1.4× tint-only
/// animation (#233).
class _ActionMorphButton extends StatefulWidget {
  const _ActionMorphButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  State<_ActionMorphButton> createState() => _ActionMorphButtonState();
}

class _ActionMorphButtonState extends State<_ActionMorphButton> {
  static const _pulseDuration = Duration(milliseconds: 320);

  bool _pulsing = false;
  Timer? _pulseTimer;

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _handle() {
    final onPressed = widget.onPressed;
    if (onPressed == null) return;
    setState(() => _pulsing = true);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(_pulseDuration, () {
      if (mounted) setState(() => _pulsing = false);
    });
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final restBackground =
        widget.color.withValues(alpha: enabled ? 0.18 : 0.08);
    final firingBackground = widget.color;
    final restForeground =
        enabled ? widget.color : widget.color.withValues(alpha: 0.5);
    const firingForeground = Colors.white;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox(
          width: 48,
          height: 48,
          child: InkResponse(
            onTap: enabled ? _handle : null,
            radius: 28,
            child: Center(
              child: AnimatedScale(
                scale: _pulsing ? 1.6 : 1.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _pulsing ? firingBackground : restBackground,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: _pulsing ? firingForeground : restForeground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
