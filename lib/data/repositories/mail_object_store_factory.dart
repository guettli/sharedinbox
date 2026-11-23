import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_jmap.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_router.dart';
import 'package:sharedinbox/data/repositories/review_log_projector.dart';

/// The [MailObjectStore] of the app: a [MailObjectStoreRouter] over an IMAP
/// and a JMAP store that open and write with the keys of [ring] and write
/// the same projections (#1373, #1379, #1380). The app and the WorkManager isolate
/// both build their store here, so the two cannot diverge.
MailObjectStore buildMailObjectStore(
  AppDatabase db,
  AccountRepository accounts,
  MailboxRepository mailboxes,
  SecureStorage storage, {
  required KeyRing ring,
  ImapConnectFn imapConnect = connectImap,
  http.Client? httpClient,
  AppLogger? appLogger,
  bool pushPending = true,
}) {
  final projectors = <MailObjectProjector>[
    EntryProjector(db),
    CardDocProjector(db),
    CardBatchProjector(db),
    DeckProjector(db),
    ReviewLogProjector(db),
  ];
  return MailObjectStoreRouter(
    accounts,
    imap: MailObjectStoreImap(
      db,
      accounts,
      mailboxes,
      storage,
      imapConnect: imapConnect,
      keyLookup: ring.lookup,
      writeKey: ring.writeKey,
      keepVanishedKeyMail: ring.keepVanishedKeyMail,
      appLogger: appLogger,
      pushPending: pushPending,
      projectors: projectors,
    ),
    jmap: MailObjectStoreJmap(
      db,
      accounts,
      mailboxes,
      storage,
      httpClient: httpClient,
      keyLookup: ring.lookup,
      writeKey: ring.writeKey,
      keepVanishedKeyMail: ring.keepVanishedKeyMail,
      appLogger: appLogger,
      pushPending: pushPending,
      projectors: projectors,
    ),
  );
}
