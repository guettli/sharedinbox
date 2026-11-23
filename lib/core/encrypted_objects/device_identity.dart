import 'dart:convert';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';

/// deviceId plus its HLC and `seq` high-water marks
/// (`ENCRYPTED-OBJECTS.md` 5.3, 5.6).
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    this.hlcHigh,
    this.seqHigh = 0,
  });

  /// Throws [FormatException].
  factory DeviceIdentity.fromJson(Map<String, Object?> json) {
    final hlcHigh = json['hlcHigh'];
    final seqHigh = json['seqHigh'];
    if (hlcHigh != null && hlcHigh is! String) {
      throw const FormatException('hlcHigh must be a string');
    }
    if (seqHigh is! int) throw const FormatException('missing seqHigh');
    return DeviceIdentity(
      deviceId: readStringField(json, 'deviceId'),
      hlcHigh: hlcHigh == null ? null : Hlc.parse(hlcHigh as String),
      seqHigh: seqHigh,
    );
  }

  final String deviceId;

  /// The highest HLC this device has written, or null before its first write.
  final Hlc? hlcHigh;

  /// The highest event `seq` this device has written (0 = none).
  final int seqHigh;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'hlcHigh': hlcHigh?.encode(),
        'seqHigh': seqHigh,
      };

  /// True if a high-water mark of this is above the one of [other].
  bool isAheadOf(DeviceIdentity other) {
    if (seqHigh > other.seqHigh) return true;
    final mine = hlcHigh;
    if (mine == null) return false;
    final theirs = other.hlcHigh;
    return theirs == null || mine > theirs;
  }
}

/// The DB side of the device identity (one record per account).
abstract class DeviceIdentityDb {
  Future<DeviceIdentity?> load(String accountId);

  Future<void> save(String accountId, DeviceIdentity identity);
}

/// Resolves this install's deviceId for an account.
///
/// The identity is stored in the DB *and* in a secure-storage marker. A
/// missing or mismatching marker means the DB was restored (Android auto
/// backup) or the keychain survived a reinstall with a rolled-back DB: the
/// old deviceId may already have versions this DB does not know, so a new
/// deviceId is created.
class DeviceIdentityResolver {
  DeviceIdentityResolver(
    this._storage,
    this._db, {
    RandomBytes random = secureRandomBytes,
  }) : _random = random;

  final SecureStorage _storage;
  final DeviceIdentityDb _db;
  final RandomBytes _random;

  static const _access = SecureStorageAccess.afterFirstUnlockThisDevice;

  static String markerKey(String accountId) => 'enc-device-marker/$accountId';

  /// The identity to use. Creates (and stores) a new deviceId if the marker
  /// is missing or corrupt, there is no DB record, the deviceIds differ, or
  /// the marker's high-water marks are above the DB's (DB rolled back). A
  /// marker that lags behind the DB is fine.
  Future<DeviceIdentity> resolve(String accountId) async {
    final db = await _db.load(accountId);
    final marker = await _readMarker(accountId);
    if (db != null &&
        marker != null &&
        marker.deviceId == db.deviceId &&
        !marker.isAheadOf(db)) {
      return db;
    }
    final fresh = DeviceIdentity(deviceId: newDeviceId(random: _random));
    await recordHighWater(accountId, fresh);
    return fresh;
  }

  /// Stores [identity] after a write. DB first, then the marker, so a crash
  /// in between only leaves a lagging marker. Callers may debounce this.
  Future<void> recordHighWater(
    String accountId,
    DeviceIdentity identity,
  ) async {
    await _db.save(accountId, identity);
    await _storage.write(
      key: markerKey(accountId),
      value: jsonEncode(identity.toJson()),
      access: _access,
    );
  }

  Future<DeviceIdentity?> _readMarker(String accountId) async {
    final raw = await _storage.read(key: markerKey(accountId), access: _access);
    if (raw == null) return null;
    try {
      return DeviceIdentity.fromJson(decodeJsonObject(utf8.encode(raw)));
    } on FormatException {
      return null;
    }
  }
}
