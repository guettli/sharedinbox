import 'package:flutter/material.dart';

import 'package:sharedinbox/core/utils/text_diff.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// A [computeContextDiff] result in monospace: `-` lines in the error
/// colour, `+` lines in green, [emptyText] when there are none.
class TextDiffView extends StatelessWidget {
  const TextDiffView({super.key, required this.lines, required this.emptyText});

  final List<DiffLine> lines;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          emptyText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.3,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            SelectableText(
              _prefixed(line),
              style: mono?.copyWith(color: _colorFor(line.kind, theme)),
            ),
        ],
      ),
    );
  }

  String _prefixed(DiffLine line) {
    switch (line.kind) {
      case DiffLineKind.added:
        return '+ ${line.text}';
      case DiffLineKind.removed:
        return '- ${line.text}';
      case DiffLineKind.gap:
        return line.text;
      case DiffLineKind.context:
        return '  ${line.text}';
    }
  }

  Color? _colorFor(DiffLineKind kind, ThemeData theme) {
    switch (kind) {
      case DiffLineKind.added:
        return Colors.green.shade700;
      case DiffLineKind.removed:
        return theme.colorScheme.error;
      case DiffLineKind.gap:
      case DiffLineKind.context:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}
