import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders the Markdown body of an entry (#1376).
///
/// Task-list checkboxes call [onToggleTask] with their index in document
/// order (see `markdown_tasks.dart`); without it they are read-only. Images
/// are never fetched: `si-img:` blobs and every other URL show a placeholder
/// (resolving `si-img:` is #1377), so encrypted notes load no remote content.
class EntryMarkdown extends StatelessWidget {
  const EntryMarkdown({super.key, required this.body, this.onToggleTask});

  final String body;
  final ValueChanged<int>? onToggleTask;

  @override
  Widget build(BuildContext context) {
    // The checkbox builder runs once per checkbox, in document order, each
    // time the body is parsed.
    var next = 0;
    return MarkdownBody(
      data: body,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      onTapLink: (text, href, title) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri == null) return;
        if (uri.scheme != 'http' && uri.scheme != 'https') return;
        unawaited(_launch(context, uri));
      },
      checkboxBuilder: (checked) {
        final index = next++;
        final onToggle = onToggleTask;
        return Checkbox(
          key: Key('entryTask_$index'),
          value: checked,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: onToggle == null ? null : (_) => onToggle(index),
        );
      },
      imageBuilder: (uri, title, alt) => _ImagePlaceholder(
        alt: alt ?? title ?? '',
      ),
    );
  }

  Future<void> _launch(BuildContext context, Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      if (!context.mounted) return;
      context.showAppSnackBar('Could not open browser.');
    } catch (e) {
      if (!context.mounted) return;
      context.showAppSnackBar('Error: ${userErrorMessage(e)}');
    }
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.alt});

  final String alt;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('entryImagePlaceholder'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.image_outlined),
        if (alt.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: Text(alt)),
        ],
      ],
    );
  }
}
