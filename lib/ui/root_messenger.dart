import 'package:flutter/material.dart';

/// Global key attached to the root [MaterialApp.router]'s [ScaffoldMessenger].
///
/// Used by [UndoShell] so its post-action SnackBar is dispatched through the
/// top-level messenger rather than whatever route context happens to be active.
/// Without this, on Android, the SnackBar fired from `ref.listen` during a
/// concurrent `context.pop()` transition was being dropped as the intermediate
/// route messenger unmounted.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
