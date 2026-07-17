import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/received_header.dart';
import 'package:sharedinbox/ui/router.dart' show SieveEditPrefill;
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Full-screen dialog for browsing email headers, organised into groups.
class EmailHeadersDialog extends StatelessWidget {
  const EmailHeadersDialog({
    super.key,
    required this.headers,
    required this.accountId,
  });
  final List<EmailHeader> headers;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mail Headers'),
          leading: const CloseButton(),
        ),
        body: _HeadersBody(headers: headers, accountId: accountId),
      ),
    );
  }
}

class _HeadersBody extends StatelessWidget {
  const _HeadersBody({required this.headers, required this.accountId});
  final List<EmailHeader> headers;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    final receivedHeaders = <EmailHeader>[];
    final listHeaders = <EmailHeader>[];
    final arcHeaders = <EmailHeader>[];
    final otherHeaders = <EmailHeader>[];
    // Maps X- prefix (e.g. "X-Google") → headers with that prefix.
    final xByPrefix = <String, List<EmailHeader>>{};

    for (final h in headers) {
      final lower = h.name.toLowerCase();
      if (lower == 'received') {
        receivedHeaders.add(h);
        continue;
      }
      if (lower.startsWith('list-')) {
        listHeaders.add(h);
        continue;
      }
      if (lower.startsWith('arc-')) {
        arcHeaders.add(h);
        continue;
      }
      if (lower.startsWith('x-')) {
        final parts = h.name.split('-');
        // "X-Foo-Bar-Baz" → prefix "X-Foo"; "X-Single" → prefix "X-Single".
        final prefix = parts.length >= 3 ? '${parts[0]}-${parts[1]}' : h.name;
        xByPrefix.putIfAbsent(prefix, () => []).add(h);
        continue;
      }
      otherHeaders.add(h);
    }

    final sections = <Widget>[];

    if (otherHeaders.isNotEmpty) {
      sections.add(
        _HeadersSection(
          title: 'Headers',
          headers: otherHeaders,
          accountId: accountId,
        ),
      );
    }
    if (listHeaders.isNotEmpty) {
      sections.add(
        _HeadersSection(
          title: 'List- Headers',
          headers: listHeaders,
          accountId: accountId,
        ),
      );
    }
    if (receivedHeaders.isNotEmpty) {
      sections.add(
        _ReceivedSection(headers: receivedHeaders, accountId: accountId),
      );
    }
    if (arcHeaders.isNotEmpty) {
      sections.add(
        _HeadersSection(
          title: 'ARC- Headers',
          headers: arcHeaders,
          accountId: accountId,
        ),
      );
    }

    // X- headers at bottom, each prefix in its own collapsible group.
    final sortedPrefixes = xByPrefix.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final prefix in sortedPrefixes) {
      sections.add(
        _HeadersSection(
          title: '$prefix Headers',
          headers: xByPrefix[prefix]!,
          accountId: accountId,
        ),
      );
    }

    return ListView(children: sections);
  }
}

class _HeadersSection extends StatelessWidget {
  const _HeadersSection({
    required this.title,
    required this.headers,
    required this.accountId,
  });

  final String title;
  final List<EmailHeader> headers;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('$title (${headers.length})'),
      children: [
        for (var i = 0; i < headers.length; i++)
          _HeaderRow(header: headers[i], index: i, accountId: accountId),
      ],
    );
  }
}

/// Received headers section — collapsed by default; shows inter-hop delays.
class _ReceivedSection extends StatelessWidget {
  const _ReceivedSection({required this.headers, required this.accountId});
  final List<EmailHeader> headers;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries(headers);
    return ExpansionTile(
      title: Text('Received (${headers.length})'),
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          _HeaderRow(
            header: entries[i].header,
            index: i,
            accountId: accountId,
          ),
          if (entries[i].delay != null) _DelayRow(delay: entries[i].delay!),
        ],
      ],
    );
  }

  static List<_ReceivedEntry> _buildEntries(List<EmailHeader> headers) {
    final timestamps =
        headers.map((h) => parseReceivedTimestamp(h.value)).toList();
    return [
      for (var i = 0; i < headers.length; i++)
        _ReceivedEntry(
          header: headers[i],
          delay: _computeDelay(timestamps, i),
        ),
    ];
  }

  static Duration? _computeDelay(List<DateTime?> timestamps, int i) {
    if (i >= timestamps.length - 1) return null;
    final current = timestamps[i];
    final next = timestamps[i + 1];
    if (current == null || next == null) return null;
    final d = current.difference(next);
    return d.isNegative ? Duration.zero : d;
  }
}

class _ReceivedEntry {
  const _ReceivedEntry({required this.header, this.delay});
  final EmailHeader header;
  final Duration? delay;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.header,
    required this.index,
    required this.accountId,
  });
  final EmailHeader header;
  final int index;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    final bg = index.isEven
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : Theme.of(context).colorScheme.surface;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.xs,
        horizontal: AppSpacing.sm,
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
          const SizedBox(width: AppSpacing.sm),
          Expanded(flex: 2, child: SelectableText(header.value)),
          IconButton(
            icon: const Icon(Icons.more_vert, size: AppIconSize.sm),
            tooltip: 'Actions for this header',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                _showHeaderActions(context, header, accountId: accountId),
          ),
        ],
      ),
    );
  }
}

class _DelayRow extends StatelessWidget {
  const _DelayRow({required this.delay});
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final color = _delayColor(delay);
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.arrow_downward, size: AppIconSize.sm, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(
            _formatDuration(delay),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: delay.inSeconds >= 30
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
          ),
        ],
      ),
    );
  }
}

/// Opens a bottom sheet offering the three actions described in issue #254:
/// search mails with this exact header/value, or create a remote / local
/// mail filter pre-populated with a matching `header :is` condition.
Future<void> _showHeaderActions(
  BuildContext context,
  EmailHeader header, {
  required String accountId,
}) async {
  final choice = await showModalBottomSheet<_HeaderAction>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text(
              header.name,
              style: Theme.of(ctx).textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Search mails with this header'),
            onTap: () => Navigator.pop(ctx, _HeaderAction.search),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Create remote filter'),
            onTap: () => Navigator.pop(ctx, _HeaderAction.remoteFilter),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('Create local filter'),
            onTap: () => Navigator.pop(ctx, _HeaderAction.localFilter),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  final filter = FilterGroup(
    operator: FilterOperator.and_,
    children: [
      FilterLeaf(
        field: FilterField.header,
        comparison: FilterComparison.is_,
        value: header.value,
        headerName: header.name,
      ),
    ],
  );
  final suggestedName = _suggestFilterName(header);

  // Close the fullscreen headers dialog first so the destination screen
  // isn't rendered underneath it — the dialog sits on the imperative
  // navigator stack above go_router's declarative pages (see #269). Look
  // up the router before popping because `context` is deactivated once
  // the dialog route is gone.
  final router = GoRouter.of(context);
  Navigator.of(context).pop();

  switch (choice) {
    case _HeaderAction.search:
      unawaited(router.push('/accounts/$accountId/search', extra: filter));
    case _HeaderAction.remoteFilter:
      unawaited(
        router.push(
          '/accounts/$accountId/sieve/edit',
          extra: SieveEditPrefill(filter: filter, name: suggestedName),
        ),
      );
    case _HeaderAction.localFilter:
      unawaited(
        router.push(
          '/accounts/$accountId/sieve/local/edit',
          extra: SieveEditPrefill(filter: filter, name: suggestedName),
        ),
      );
  }
}

String _suggestFilterName(EmailHeader h) {
  final v = h.value.replaceAll(RegExp(r'\s+'), ' ').trim();
  final shortV = v.length > 40 ? '${v.substring(0, 40)}…' : v;
  return '${h.name}: $shortV';
}

enum _HeaderAction { search, remoteFilter, localFilter }

String _formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
}

Color _delayColor(Duration d) {
  if (d.inSeconds < 30) return Colors.green;
  if (d.inSeconds < 300) return Colors.orange;
  return Colors.red;
}
