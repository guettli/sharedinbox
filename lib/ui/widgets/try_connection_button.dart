import 'package:flutter/material.dart';

import 'package:sharedinbox/ui/theme/spacing.dart';

/// Renders the "Try connection" button together with its success/error result.
///
/// The parent manages [testing], [okMessage], [errorMessage], and [onPressed]
/// state; this widget is purely presentational.
class TryConnectionButton extends StatelessWidget {
  const TryConnectionButton({
    super.key,
    required this.testing,
    required this.onPressed,
    this.okMessage,
    this.errorMessage,
    this.buttonKey,
  });

  final bool testing;
  final VoidCallback? onPressed;
  final String? okMessage;
  final String? errorMessage;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (okMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _ResultRow(
              icon: Icons.check_circle,
              color: Colors.green.shade600,
              message: okMessage!,
              semanticLabel: 'Connection succeeded',
            ),
          ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _ResultRow(
              icon: Icons.error,
              color: Theme.of(context).colorScheme.error,
              message: errorMessage!,
              semanticLabel: 'Connection failed',
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton(
          key: buttonKey,
          onPressed: testing ? null : onPressed,
          child: testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Try connection'),
        ),
      ],
    );
  }
}

/// A status icon next to a coloured message, used to make connection
/// success and failure easy to tell apart at a glance.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.icon,
    required this.color,
    required this.message,
    required this.semanticLabel,
  });

  final IconData icon;
  final Color color;
  final String message;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20, semanticLabel: semanticLabel),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(message, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}
