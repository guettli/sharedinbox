import 'package:flutter/material.dart';

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
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              okMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
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
