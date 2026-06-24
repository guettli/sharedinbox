import 'package:flutter/material.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/received_header.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Full-screen dialog for browsing email headers, organised into groups.
class EmailHeadersDialog extends StatelessWidget {
  const EmailHeadersDialog({super.key, required this.headers});
  final List<EmailHeader> headers;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mail Headers'),
          leading: const CloseButton(),
        ),
        body: _HeadersBody(headers: headers),
      ),
    );
  }
}

class _HeadersBody extends StatelessWidget {
  const _HeadersBody({required this.headers});
  final List<EmailHeader> headers;

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
      sections.add(_HeadersSection(title: 'Headers', headers: otherHeaders));
    }
    if (listHeaders.isNotEmpty) {
      sections.add(
        _HeadersSection(title: 'List- Headers', headers: listHeaders),
      );
    }
    if (receivedHeaders.isNotEmpty) {
      sections.add(_ReceivedSection(headers: receivedHeaders));
    }
    if (arcHeaders.isNotEmpty) {
      sections.add(
        _HeadersSection(title: 'ARC- Headers', headers: arcHeaders),
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
        ),
      );
    }

    return ListView(children: sections);
  }
}

class _HeadersSection extends StatelessWidget {
  const _HeadersSection({required this.title, required this.headers});

  final String title;
  final List<EmailHeader> headers;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('$title (${headers.length})'),
      children: [
        for (var i = 0; i < headers.length; i++)
          _HeaderRow(header: headers[i], index: i),
      ],
    );
  }
}

/// Received headers section — collapsed by default; shows inter-hop delays.
class _ReceivedSection extends StatelessWidget {
  const _ReceivedSection({required this.headers});
  final List<EmailHeader> headers;

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries(headers);
    return ExpansionTile(
      title: Text('Received (${headers.length})'),
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          _HeaderRow(header: entries[i].header, index: i),
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
  const _HeaderRow({required this.header, required this.index});
  final EmailHeader header;
  final int index;

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
