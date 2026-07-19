import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/utils/linkify.dart';
import 'package:sharedinbox/di.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders plain [text] and turns any http(s) URL inside it into a tappable
/// hyperlink. Selection still works — the widget wraps a [Text.rich] in a
/// [SelectionArea] so long-press on mobile (or click-drag on desktop) selects
/// text without being swallowed by the link tap recognizers.
///
/// Tapping a link shows a confirmation dialog with the exact URL before
/// launching it in the platform browser, matching the safeguard used for
/// links inside HTML email bodies.
class LinkifiedText extends ConsumerStatefulWidget {
  const LinkifiedText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  ConsumerState<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends ConsumerState<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final baseStyle = widget.style ?? Theme.of(context).textTheme.bodyMedium;
    final linkStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );

    final matches = findUrls(widget.text);
    if (matches.isEmpty) {
      return SelectionArea(child: Text(widget.text, style: baseStyle));
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, m.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => unawaited(_openLink(m.url));
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(text: m.url, style: linkStyle, recognizer: recognizer),
      );
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return SelectionArea(
      child: Text.rich(TextSpan(style: baseStyle, children: spans)),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open link?'),
        content: SingleChildScrollView(
          child: SelectableText(
            url,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open in browser'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      unawaited(
        ref.read(appLoggerProvider).warn(
          'link.open_failed',
          'Browser refused to open link',
          data: {'url': url},
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open: $url')),
        );
      }
    }
  }
}
