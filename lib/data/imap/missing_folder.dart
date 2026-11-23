import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;

import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';

/// Whether the app folder [path] is gone for sure after opening it failed
/// with [error] ([confirmImapMailboxGone]). When it is not, logs [event] at
/// warn level with [message] (the local data is kept and the sync fails,
/// tried again later). Shared by the notes and the encrypted-object store:
/// only a definite answer may drop or re-upload what they cached (#1312).
Future<bool> appFolderGone(
  imap.ImapClient client,
  String path,
  Object error, {
  required String accountId,
  required String event,
  required String message,
  AppLogger? appLogger,
}) async {
  if (await confirmImapMailboxGone(client, path, error)) return true;
  unawaited(
    appLogger?.warn(
      event,
      message,
      accountId: accountId,
      error: error,
    ),
  );
  return false;
}
