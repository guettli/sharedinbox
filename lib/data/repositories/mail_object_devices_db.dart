import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/data/db/database.dart';

/// [DeviceIdentityDb] on the `mail_object_devices` table (#1370).
class MailObjectDevicesDb implements DeviceIdentityDb {
  MailObjectDevicesDb(this._db);

  final AppDatabase _db;

  @override
  Future<DeviceIdentity?> load(String accountId) async {
    final row = await (_db.select(_db.mailObjectDevices)
          ..where((t) => t.accountId.equals(accountId)))
        .getSingleOrNull();
    if (row == null) return null;
    final high = row.hlcHigh;
    try {
      return DeviceIdentity(
        deviceId: row.deviceId,
        hlcHigh: high == null ? null : Hlc.parse(high),
        seqHigh: row.seqHigh,
      );
    } on FormatException {
      // A corrupt record is no record: the resolver makes a new deviceId.
      return null;
    }
  }

  @override
  Future<void> save(String accountId, DeviceIdentity identity) =>
      _db.into(_db.mailObjectDevices).insertOnConflictUpdate(
            MailObjectDevicesCompanion.insert(
              accountId: accountId,
              deviceId: identity.deviceId,
              hlcHigh: Value(identity.hlcHigh?.encode()),
              seqHigh: Value(identity.seqHigh),
            ),
          );
}
