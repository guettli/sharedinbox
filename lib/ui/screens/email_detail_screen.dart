import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/core/utils/list_unsubscribe.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/email_headers_dialog.dart';
import 'package:sharedinbox/ui/widgets/error_boundary.dart';
import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';
import 'package:url_launcher/url_launcher.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId});
  final String emailId;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  bool _isFlagged = false;
  bool _loadRemoteImages = false;
  final Set<String> _downloading = {};
  bool _notesSynced = false;

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

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isMobile,
        actions: [
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_replyWithRecipientDialog(context, header, body));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Archive',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_archive(context, header));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () async {
              final nextEmailId = await _getNextEmailIdIfNeeded(header);
              final destPath = await repo.deleteEmail(widget.emailId);

              if (header != null) {
                await ref.read(undoServiceProvider.notifier).pushAction(
                      UndoAction(
                        id: DateTime.now().toIso8601String(),
                        accountId: header.accountId,
                        type: UndoType.delete,
                        emailIds: [widget.emailId],
                        sourceMailboxPath: header.mailboxPath,
                        destinationMailboxPath: destPath,
                        originalEmails: [header],
                      ),
                    );
              }

              if (context.mounted) _navigateTo(context, header, nextEmailId);
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
          IconButton(
            icon: const Icon(Icons.report_outlined),
            tooltip: 'Mark as spam',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_markAsSpam(context, header));
                  },
          ),
          PopupMenuButton<String>(
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'forward', child: Text('Forward')),
              const PopupMenuItem(value: 'move', child: Text('Move to folder')),
              const PopupMenuItem(value: 'snooze', child: Text('Snooze')),
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
              } else if (value == 'mark_unread') {
                final nextEmailId = await _getNextEmailIdIfNeeded(header);
                await repo.setFlag(widget.emailId, seen: false);
                if (context.mounted) _navigateTo(context, header, nextEmailId);
              } else if (value == 'headers' && body != null) {
                _showHeaders(context, body);
              } else if (value == 'structure' && body != null) {
                _showStructure(context, body);
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
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          final trusted =
              ref.watch(trustedImageSendersProvider).value ?? const <String>[];
          return _buildBody(context, d.$1, d.$2, trusted);
        },
      ),
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
          SelectableText(
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

  Future<String?> _getNextEmailIdIfNeeded(Email? header) async {
    if (header == null) return null;
    final prefs = ref.read(userPreferencesProvider).value;
    final action =
        prefs?.afterMailViewAction ?? AfterMailViewAction.nextMessage;
    if (action != AfterMailViewAction.nextMessage) return null;

    final threads = await ref
        .read(emailRepositoryProvider)
        .observeThreads(header.accountId, header.mailboxPath)
        .first;

    final currentIndex = threads.indexWhere(
      (t) => t.emailIds.contains(widget.emailId),
    );
    if (currentIndex >= 0 && currentIndex + 1 < threads.length) {
      return threads[currentIndex + 1].latestEmailId;
    }
    return null;
  }

  void _navigateTo(BuildContext context, Email? header, String? nextEmailId) {
    if (!context.mounted) return;
    if (nextEmailId != null && header != null) {
      context.go(
        '/accounts/${header.accountId}'
        '/mailboxes/${Uri.encodeComponent(header.mailboxPath)}'
        '/emails/${Uri.encodeComponent(nextEmailId)}',
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
    } catch (e) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          email.subject ?? '(no subject)',
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        if (email.from.isNotEmpty)
          Text(
            'From: ${email.from.first}',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        if (email.to.isNotEmpty)
          Text(
            'To: ${email.to.map((a) => a.toString()).join(', ')}',
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
            child: _UnsubscribeChip(header: email.listUnsubscribeHeader!),
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
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
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
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
  }

  Future<void> _markAsSpam(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
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
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
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
    final nextEmailId = await _getNextEmailIdIfNeeded(header);

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
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmailId);
  }

  Future<void> _snooze(BuildContext context, Email header) async {
    final nextEmailId = await _getNextEmailIdIfNeeded(header);
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
      _navigateTo(context, header, nextEmailId);
    }
  }

  Future<void> _showRaw(BuildContext context, Email? header) async {
    final String raw;
    try {
      raw = await ref
          .read(emailRepositoryProvider)
          .fetchRawRfc822(widget.emailId);
    } catch (e) {
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
      final dir = await getTemporaryDirectory();
      final subject = (header?.subject ?? 'email')
          .replaceAll(RegExp(r'[^\w\s-]'), '_')
          .trim();
      final filename = '$subject.eml';
      final file = File('${dir.path}/$filename');
      await file.writeAsString(raw);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved $filename'),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () => SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)]),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  void _showHeaders(BuildContext context, EmailBody body) {
    if (body.headers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('No headers available. Try re-syncing the email.'),
        ),
      );
      return;
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => EmailHeadersDialog(headers: body.headers),
      ),
    );
  }

  void _showStructure(BuildContext context, EmailBody body) {
    final tree = body.mimeTree;
    if (tree == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('Structure not available. Try re-syncing the email.'),
        ),
      );
      return;
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

class _UnsubscribeChip extends StatelessWidget {
  const _UnsubscribeChip({required this.header});
  final String header;

  Future<void> _onTap(BuildContext context, Uri uri) async {
    final isMailto = uri.scheme == 'mailto';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: Text(
          isMailto
              ? 'Send an unsubscribe email to:\n${uri.path}'
              : 'Open the unsubscribe page:\n$uri',
        ),
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
    if (confirmed != true) return;
    if (!context.mounted) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open unsubscribe link')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = parseListUnsubscribeUri(header);
    if (uri == null) return const SizedBox.shrink();
    return Tooltip(
      message: uri.toString(),
      child: ActionChip(
        avatar: const Icon(Icons.unsubscribe_outlined, size: AppIconSize.sm),
        label: const Text('Unsubscribe'),
        onPressed: () => _onTap(context, uri),
      ),
    );
  }
}
