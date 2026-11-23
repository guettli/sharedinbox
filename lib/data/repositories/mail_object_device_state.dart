import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/device_state.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';

/// The collection of the device-state docs.
const deviceStateCollection = 'personal';

/// Device-state docs over a [MailObjectStore] (#1372, 5.4 item 4): this
/// device writes only its own doc (`device-state/<deviceId>`); a key's
/// effective value is the one with the highest HLC over all devices' docs,
/// read from the projection the store keeps ([MailObjectDeviceStates]).
class DeviceStateStore {
  DeviceStateStore(
    this.db,
    this.store, {
    this.collectionId = deviceStateCollection,
  });

  final AppDatabase db;
  final MailObjectStore store;
  final String collectionId;

  /// Sets [key] to [value] in this device's doc; null unsets it. Throws
  /// `NoWriteKeyException`.
  Future<void> set(String accountId, String key, Object? value) async {
    final clock = await store.clockFor(accountId);
    final itemId = deviceStateItemId(clock.deviceId);
    final hmac = await store.itemHmacOf(accountId, collectionId, itemId);
    final current = hmac == null ? null : await store.item(accountId, hmac);
    // Newer than every value of [key] seen here, so a write after reading
    // another device's value wins over it.
    for (final r
        in await (_query(accountId)..where((t) => t.key.equals(key))).get()) {
      if (_tryHlc(r.hlc) case final seen?) clock.receive(seen);
    }
    final hlc = clock.send();
    final doc = (current == null ? null : DeviceStateDoc.of(current.display)) ??
        DeviceStateDoc(device: clock.deviceId);
    final extra = doc.withValue(key, value, hlc).toExtra();
    if (current == null) {
      await store.put(
        accountId,
        InnerObject(
          head: ObjectHead(
            itemId: itemId,
            collectionId: collectionId,
            versionId: hlc,
            kind: deviceStateKind,
            extra: extra,
          ),
        ),
      );
      return;
    }
    await store.put(
      accountId,
      edit(
        base: current.display,
        merge: current.merge,
        clock: clock,
        fields: extra,
      ),
    );
  }

  /// The effective value of [key], or null when it is unset.
  Future<Object?> get(String accountId, String key) async =>
      (await _effective(accountId))[key];

  /// The effective map, updated with every merge.
  Stream<Map<String, Object?>> watch(String accountId) =>
      _query(accountId).watch().map(_toMap);

  Future<Map<String, Object?>> _effective(String accountId) =>
      _query(accountId).get().then(_toMap);

  SimpleSelectStatement<$MailObjectDeviceStatesTable, MailObjectDeviceStateRow>
      _query(String accountId) => db.select(db.mailObjectDeviceStates)
        ..where((t) => t.accountId.equals(accountId));

  static Map<String, Object?> _toMap(List<MailObjectDeviceStateRow> rows) {
    final byDevice = <String, Map<String, DeviceStateValue>>{};
    for (final r in rows) {
      final hlc = _tryHlc(r.hlc);
      if (hlc == null) continue;
      final json = r.valueJson;
      (byDevice[r.deviceId] ??= {})[r.key] =
          DeviceStateValue(json == null ? null : jsonDecode(json), hlc);
    }
    return effectiveDeviceState([
      for (final MapEntry(:key, :value) in byDevice.entries)
        DeviceStateDoc(device: key, values: value),
    ]);
  }

  static Hlc? _tryHlc(String encoded) {
    try {
      return Hlc.parse(encoded);
    } on FormatException {
      return null;
    }
  }
}
