import 'package:flutter/material.dart';

import 'package:sharedinbox/ui/theme/spacing.dart';

/// The text of a quick-add [controller], which is cleared; null when blank.
String? takeQuickAddText(TextEditingController controller) {
  final text = controller.text;
  if (text.trim().isEmpty) return null;
  controller.clear();
  return text;
}

/// A one-line field with a send button that adds an item (entries, todos).
class QuickAddField extends StatelessWidget {
  const QuickAddField({
    super.key,
    required this.fieldKey,
    required this.sendKey,
    required this.controller,
    required this.hintText,
    required this.onAdd,
  });

  final Key fieldKey;
  final Key sendKey;
  final TextEditingController controller;
  final String hintText;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: controller,
                decoration: InputDecoration(hintText: hintText),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onAdd(),
              ),
            ),
            IconButton(
              key: sendKey,
              icon: const Icon(Icons.send),
              tooltip: 'Add',
              onPressed: onAdd,
            ),
          ],
        ),
      );
}
