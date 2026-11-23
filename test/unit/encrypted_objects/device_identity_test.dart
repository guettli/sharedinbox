import 'dart:convert';

import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:test/test.dart';

import '../helpers/fake_secure_storage.dart';
import 'test_helpers.dart';

void main() {
  late FakeSecureStorage storage;
  late FakeDeviceIdentityDb db;
  late DeviceIdentityResolver resolver;
  const marker = 'enc-device-marker/acc-1';

  setUp(() {
    storage = FakeSecureStorage();
    db = FakeDeviceIdentityDb();
    resolver = DeviceIdentityResolver(storage, db, random: counterRandom());
  });

  Future<DeviceIdentity> markerValue() async => DeviceIdentity.fromJson(
        jsonDecode(
          (await storage.read(
            key: marker,
            access: SecureStorageAccess.afterFirstUnlockThisDevice,
          ))!,
        ) as Map<String, Object?>,
      );

  test('marker key is enc-device-marker/<accountId>', () {
    expect(DeviceIdentityResolver.markerKey('acc-1'), marker);
  });

  test('a fresh install gets a new deviceId in DB and marker', () async {
    final identity = await resolver.resolve('acc-1');
    expect(identity.deviceId, hasLength(22));
    expect(identity.hlcHigh, isNull);
    expect(identity.seqHigh, 0);
    expect(db.records['acc-1']!.deviceId, identity.deviceId);
    expect((await markerValue()).deviceId, identity.deviceId);
    expect(
      storage.accessLog[marker],
      everyElement(
        SecureStorageAccess.afterFirstUnlockThisDevice,
      ),
    );
  });

  test('a matching marker keeps the deviceId', () async {
    final first = await resolver.resolve('acc-1');
    final written = DeviceIdentity(
      deviceId: first.deviceId,
      hlcHigh: hlcAt(5000, first.deviceId),
      seqHigh: 3,
    );
    await resolver.recordHighWater('acc-1', written);
    final again = await resolver.resolve('acc-1');
    expect(again.deviceId, first.deviceId);
    expect(again.hlcHigh, written.hlcHigh);
    expect(again.seqHigh, 3);
  });

  test('a marker lagging behind the DB keeps the deviceId', () async {
    final first = await resolver.resolve('acc-1');
    db.records['acc-1'] = DeviceIdentity(
      deviceId: first.deviceId,
      hlcHigh: hlcAt(5000, first.deviceId),
      seqHigh: 2,
    );
    expect((await resolver.resolve('acc-1')).deviceId, first.deviceId);
  });

  test('a missing marker gives a new deviceId', () async {
    final first = await resolver.resolve('acc-1');
    await storage.delete(key: marker);
    final next = await resolver.resolve('acc-1');
    expect(next.deviceId, isNot(first.deviceId));
    expect(db.records['acc-1']!.deviceId, next.deviceId);
    expect((await markerValue()).deviceId, next.deviceId);
  });

  test('a corrupt marker gives a new deviceId', () async {
    final first = await resolver.resolve('acc-1');
    await storage.write(key: marker, value: '{"deviceId": 1}');
    expect((await resolver.resolve('acc-1')).deviceId, isNot(first.deviceId));
  });

  test('a mismatching marker gives a new deviceId', () async {
    final first = await resolver.resolve('acc-1');
    await storage.write(
      key: marker,
      value: jsonEncode(const DeviceIdentity(deviceId: 'other').toJson()),
    );
    expect((await resolver.resolve('acc-1')).deviceId, isNot(first.deviceId));
  });

  test('a missing DB record gives a new deviceId', () async {
    final first = await resolver.resolve('acc-1');
    db.records.clear();
    expect((await resolver.resolve('acc-1')).deviceId, isNot(first.deviceId));
  });

  test('a restored DB (marker HLC above the DB) gives a new deviceId',
      () async {
    final first = await resolver.resolve('acc-1');
    final before = DeviceIdentity(
      deviceId: first.deviceId,
      hlcHigh: hlcAt(1000, first.deviceId),
    );
    await resolver.recordHighWater('acc-1', before);
    await resolver.recordHighWater(
      'acc-1',
      DeviceIdentity(
        deviceId: first.deviceId,
        hlcHigh: hlcAt(2000, first.deviceId),
      ),
    );
    db.records['acc-1'] = before; // the backup is restored
    final next = await resolver.resolve('acc-1');
    expect(next.deviceId, isNot(first.deviceId));
  });

  test('a restored DB (marker seq above the DB) gives a new deviceId',
      () async {
    final first = await resolver.resolve('acc-1');
    await resolver.recordHighWater(
      'acc-1',
      DeviceIdentity(deviceId: first.deviceId, seqHigh: 9),
    );
    db.records['acc-1'] = DeviceIdentity(deviceId: first.deviceId, seqHigh: 8);
    expect((await resolver.resolve('acc-1')).deviceId, isNot(first.deviceId));
  });

  test('isAheadOf compares both high-water marks', () {
    const none = DeviceIdentity(deviceId: 'd');
    final hlc = DeviceIdentity(deviceId: 'd', hlcHigh: hlcAt(1, 'd'));
    expect(none.isAheadOf(none), isFalse);
    expect(hlc.isAheadOf(none), isTrue);
    expect(none.isAheadOf(hlc), isFalse);
    expect(hlc.isAheadOf(hlc), isFalse);
  });

  test('fromJson rejects malformed values', () {
    expect(
      () => DeviceIdentity.fromJson(
        {'deviceId': 'd', 'hlcHigh': 1, 'seqHigh': 0},
      ),
      throwsFormatException,
    );
    expect(
      () => DeviceIdentity.fromJson({'deviceId': 'd'}),
      throwsFormatException,
    );
  });
}
