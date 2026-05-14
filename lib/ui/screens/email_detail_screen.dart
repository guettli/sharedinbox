import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';
import 'package:url_launcher/url_launcher.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

void _openLink(String? url, Map<String, String> attrs, dynamic _) {
  if (url == null) return;
  final uri = Uri.tryParse(url);
  if (uri != null) {
    unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
  }
}

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

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(emailRepositoryProvider);
    final detail = ref.watch(emailDetailProvider(widget.emailId));

    ref.listen<AsyncValue<(Email?, EmailBody)>>(
      emailDetailProvider(widget.emailId),
      (_, next) {
        final email = next.valueOrNull?.$1;
        if (email != null && mounted) {
          setState(() => _isFlagged = email.isFlagged);
        }
      },
    );

    final header = detail.valueOrNull?.$1;
    final body = detail.valueOrNull?.$2;

    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isMobile,
        title: Text(
          header?.subject ?? '(loading…)',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.reply),
            tooltip: 'Reply',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_reply(context, header, body, replyAll: false));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.reply_all),
            tooltip: 'Reply all',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_reply(context, header, body, replyAll: true));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.forward),
            tooltip: 'Forward',
            onPressed: header == null
                ? null
                : () {
                    unawaited(_forward(context, header, body));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.mark_email_unread_outlined),
            tooltip: 'Mark as unread',
            onPressed: () async {
              await repo.setFlag(widget.emailId, seen: false);
              if (context.mounted) context.pop();
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
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Move to folder',
            onPressed: header == null ? null : () => _moveTo(context, header),
          ),
          IconButton(
            icon: const Icon(Icons.access_time),
            tooltip: 'Snooze',
            onPressed: header == null ? null : () => _snooze(context, header),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () async {
              final destPath = await repo.deleteEmail(widget.emailId);

              if (header != null) {
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

              if (context.mounted) context.pop();
            },
          ),
          PopupMenuButton<String>(
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'headers',
                child: Text('Show Mail Headers'),
              ),
            ],
            onSelected: (value) {
              if (value == 'headers' && body != null) {
                _showHeaders(context, body);
              }
            },
          ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) => _buildBody(context, d.$1, d.$2),
      ),
    );
  }

  Widget _buildBody(BuildContext ctx, Email? header, EmailBody body) {
    final hasHtml = (body.htmlBody ?? '').trim().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (header != null) ...[_buildHeader(ctx, header), const Divider()],
        if (hasHtml) ...[
          if (!_loadRemoteImages)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Load remote images'),
                  onPressed: () => setState(() => _loadRemoteImages = true),
                ),
              ),
            ),
          _SafeHtml(
            data: body.htmlBody!,
            extensions: [if (!_loadRemoteImages) _BlockRemoteImagesExtension()],
          ),
        ] else
          SelectableText(
            body.textBody ?? '',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        if (body.attachments.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
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
                      width: 24,
                      height: 24,
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

  Widget _buildHeader(BuildContext ctx, Email email) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          email.subject ?? '(no subject)',
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
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
            padding: const EdgeInsets.only(top: 8),
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

  Future<void> _reply(
    BuildContext context,
    Email header,
    EmailBody? body, {
    required bool replyAll,
  }) async {
    final to = header.from.isNotEmpty ? header.from.first.email : '';
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    final cc = replyAll ? header.to.map((a) => a.email).join(', ') : '';
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
        extra: {
          'prefillSubject': subject,
          'prefillBody': quoted,
        },
      ),
    );
  }

  Future<void> _moveTo(BuildContext context, Email header) async {
    final mailboxRepo = ref.read(mailboxRepositoryProvider);
    final mailboxes =
        await mailboxRepo.observeMailboxes(header.accountId).first;

    // Remove the current mailbox from the list.
    final destinations =
        mailboxes.where((m) => m.path != header.mailboxPath).toList();

    if (!context.mounted) return;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text(
              'Move to…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
        ],
      ),
    );

    if (chosen == null || !context.mounted) return;

    await ref.read(emailRepositoryProvider).moveEmail(widget.emailId, chosen);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: chosen,
            ),
          ),
    );

    if (context.mounted) context.pop();
  }

  Future<void> _snooze(BuildContext context, Email header) async {
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
          content: Text(
            'Snoozed until ${DateFormat('MMM d, HH:mm').format(until)}',
          ),
        ),
      );
      context.pop();
    }
  }

  void _showHeaders(BuildContext context, EmailBody body) {
    if (body.headers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No headers available. Try re-syncing the email.'),
        ),
      );
      return;
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mail Headers'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: body.headers.length,
              itemBuilder: (ctx, i) {
                final header = body.headers[i];
                return Container(
                  color: i.isEven
                      ? Theme.of(ctx).colorScheme.surfaceContainerHighest
                      : Theme.of(ctx).colorScheme.surface,
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          header.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: SelectableText(header.value)),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Parses a List-Unsubscribe header and returns the first usable URI.
/// Prefers mailto: so unsubscribing sends an email; falls back to https:.
Uri? _parseUnsubscribeUri(String header) {
  final matches = RegExp(r'<([^>]+)>').allMatches(header);
  Uri? fallback;
  for (final m in matches) {
    final raw = m.group(1)!.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    if (uri.scheme == 'mailto') return uri;
    if ((uri.scheme == 'https' || uri.scheme == 'http') && fallback == null) {
      fallback = uri;
    }
  }
  return fallback;
}

class _UnsubscribeChip extends StatelessWidget {
  const _UnsubscribeChip({required this.header});
  final String header;

  @override
  Widget build(BuildContext context) {
    final uri = _parseUnsubscribeUri(header);
    if (uri == null) return const SizedBox.shrink();
    return ActionChip(
      avatar: const Icon(Icons.unsubscribe_outlined, size: 16),
      label: const Text('Unsubscribe'),
      onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication),
    );
  }
}

/// Renders [Html] and falls back to an error message if the widget throws
/// during build, preventing a malformed body from crashing the whole screen.
class _SafeHtml extends StatefulWidget {
  const _SafeHtml({required this.data, required this.extensions});
  final String data;
  final List<HtmlExtension> extensions;

  @override
  State<_SafeHtml> createState() => _SafeHtmlState();
}

class _SafeHtmlState extends State<_SafeHtml> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_outlined,
              color: Theme.of(context).colorScheme.error,
              size: 16,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('Message body could not be rendered.')),
          ],
        ),
      );
    }

    // Intercept any build-phase throw from flutter_html for this subtree.
    // We save/restore via postFrameCallback so other widgets are unaffected.
    final prev = ErrorWidget.builder;
    ErrorWidget.builder = (FlutterErrorDetails details) {
      ErrorWidget.builder = prev;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _failed = true);
      });
      return const SizedBox.shrink();
    };
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ErrorWidget.builder = prev,
    );

    return Html(
      data: widget.data,
      extensions: widget.extensions,
      onLinkTap: _openLink,
    );
  }
}

class _BlockRemoteImagesExtension extends HtmlExtension {
  @override
  Set<String> get supportedTags => {'img'};

  @override
  bool matches(ExtensionContext context) {
    if (context.elementName != 'img') return false;
    final src = context.attributes['src'] ?? '';
    return src.startsWith('http://') || src.startsWith('https://');
  }

  @override
  InlineSpan build(ExtensionContext context) =>
      const WidgetSpan(child: SizedBox.shrink());
}
