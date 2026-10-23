import 'package:flutter/material.dart';

/// Wraps a [DropdownButton] (or [DropdownButtonFormField]) so screen readers
/// learn whether it can be used.
///
/// DropdownButton exposes no enabled state on its semantics node, and
/// Flutter's Linux accessibility bridge announces such a button as
/// "disabled" even though it opens fine (#1179, #1180). This merges an
/// explicit enabled flag into the button's node, derived the same way the
/// dropdown decides it itself, so a really disabled dropdown still reads as
/// disabled.
class AccessibleDropdown<T> extends StatelessWidget {
  /// Wraps a [DropdownButton]: enabled when it has an onChanged callback and
  /// at least one item, matching DropdownButton's own rule.
  AccessibleDropdown({super.key, required DropdownButton<T> child})
      : _enabled =
            child.onChanged != null && (child.items?.isNotEmpty ?? false),
        _child = child;

  /// Wraps a [DropdownButtonFormField]: enabled when it has an onChanged
  /// callback (the form field does not expose its items).
  AccessibleDropdown.formField({
    super.key,
    required DropdownButtonFormField<T> child,
  })  : _enabled = child.onChanged != null,
        _child = child;

  final bool _enabled;
  final Widget _child;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Semantics(enabled: _enabled, child: _child),
      );
}
