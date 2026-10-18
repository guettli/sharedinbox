import 'package:flutter/material.dart';

/// Asks for a piece of text in a dialog. Returns the trimmed text, or null
/// when the dialog is cancelled or the field is left empty.
///
/// Use this instead of a [TextEditingController] created next to
/// `showDialog`: `showDialog` returns as soon as the route is popped, while
/// the dialog's [TextField] is still on screen for the exit animation.
/// Disposing the controller at that point fails a framework assertion
/// (`_dependents.isEmpty`) and takes down the whole screen. Here the
/// controller lives in the dialog's own [State] and is disposed with it.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? hintText,
  String? labelText,
  int maxLines = 1,
  TextInputType? keyboardType,
  TextCapitalization textCapitalization = TextCapitalization.none,
}) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      confirmLabel: confirmLabel,
      hintText: hintText,
      labelText: labelText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
    ),
  );
  final trimmed = text?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.confirmLabel,
    required this.hintText,
    required this.labelText,
    required this.maxLines,
    required this.keyboardType,
    required this.textCapitalization,
  });

  final String title;
  final String confirmLabel;
  final String? hintText;
  final String? labelText;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.trim().isEmpty) return;
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.maxLines,
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        decoration: InputDecoration(
          hintText: widget.hintText,
          labelText: widget.labelText,
        ),
        onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
