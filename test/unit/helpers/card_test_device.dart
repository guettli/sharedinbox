// One install with the card projections over a StatefulFakeImapServer,
// shared by the card repository (#1379) and the card importer (#1383)
// tests.

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_repository_impl.dart';

import 'fake_object_account.dart';
import 'shared_keys_device.dart';
import 'stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;

/// One install with the card projections, talking to the shared fake
/// [server]; [keys] are made on demand when a deck is created.
class CardTestDevice extends SharedKeysDevice {
  CardTestDevice(super.server, super.keys);

  @override
  late final List<MailObjectProjector> projectors = [
    CardDocProjector(db),
    CardBatchProjector(db),
    DeckProjector(db),
  ];

  late final repo = CardRepositoryImpl(
    db,
    store,
    ensureCollection: (_, collectionId) async {
      keys.byCollection[collectionId] ??= CollectionKey.generate(collectionId);
    },
  );

  static Future<CardTestDevice> open(
    StatefulFakeImapServer server,
    SharedCollectionKeys keys,
  ) =>
      CardTestDevice(server, keys).init();

  Future<List<FlashCard>> cards(String deckId) =>
      repo.observeCards(_acc, deckId).first;

  Future<Map<String, String>> fronts(String deckId) async =>
      {for (final c in await cards(deckId)) c.cardId: c.front};

  Future<List<MailObject>> heads(String kind) => store.rowsOfKind(_acc, kind);
}
