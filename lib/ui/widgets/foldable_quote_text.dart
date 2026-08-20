import 'package:flutter/material.dart';
import 'package:sharedinbox/core/utils/quote_fold.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/linkified_text.dart';

/// Renders a plain-text email body, folding away a long trailing quote by
/// default so a short reply stays readable without the whole original message
/// pushed below it (issue #660).
///
/// When [splitTrailingQuote] finds no foldable quote — including inline/
/// interleaved quoting — the text is rendered as-is via [LinkifiedText].
class FoldableQuoteText extends StatefulWidget {
  const FoldableQuoteText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<FoldableQuoteText> createState() => _FoldableQuoteTextState();
}

class _FoldableQuoteTextState extends State<FoldableQuoteText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final split = splitTrailingQuote(widget.text);
    final quoted = split.quoted;
    if (quoted == null) {
      return LinkifiedText(widget.text, style: widget.style);
    }

    final quoteLines = '\n'.allMatches(quoted).length + 1;
    final mutedStyle = (widget.style ??
            Theme.of(context).textTheme.bodyMedium ??
            const TextStyle())
        .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinkifiedText(split.visible, style: widget.style),
        const SizedBox(height: AppSpacing.sm),
        if (!_expanded)
          OutlinedButton.icon(
            icon: const Icon(Icons.unfold_more, size: AppIconSize.sm),
            label: Text('Show quoted text ($quoteLines lines)'),
            onPressed: () => setState(() => _expanded = true),
          )
        else ...[
          Container(
            padding: const EdgeInsets.only(left: AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 2,
                ),
              ),
            ),
            child: LinkifiedText(quoted, style: mutedStyle),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            icon: const Icon(Icons.unfold_less, size: AppIconSize.sm),
            label: const Text('Hide quoted text'),
            onPressed: () => setState(() => _expanded = false),
          ),
        ],
      ],
    );
  }
}
