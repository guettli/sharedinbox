import 'package:sharedinbox/core/encrypted_objects/device_state.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  test('the effective value of a key is the one with the highest HLC', () {
    final a = DeviceStateDoc(device: 'devA')
        .withValue('theme', 'dark', hlcAt(10))
        .withValue('deck', 'd1', hlcAt(10))
        .withValue('only-a', 1, hlcAt(5));
    final b = DeviceStateDoc(device: 'devB')
        .withValue('theme', 'light', hlcAt(20, 'devB'))
        // A null with a higher HLC unsets the key.
        .withValue('deck', null, hlcAt(30, 'devB'))
        .withValue('only-b', null, hlcAt(1, 'devB'));

    expect(effectiveDeviceState([a, b]), {'theme': 'light', 'only-a': 1});
    expect(effectiveDeviceState([b, a]), {'theme': 'light', 'only-a': 1});
    expect(effectiveDeviceState(const []), isEmpty);
  });

  test('a doc round-trips through its head fields', () {
    final doc = DeviceStateDoc(device: 'devA')
        .withValue('k', {'nested': true}, hlcAt(3))
        .withValue('gone', null, hlcAt(4));
    final object = InnerObject(
      head: ObjectHead(
        itemId: deviceStateItemId('devA'),
        collectionId: 'personal',
        versionId: hlcAt(5),
        kind: deviceStateKind,
        extra: doc.toExtra(),
      ),
    );

    final read = DeviceStateDoc.of(object)!;
    expect(read.device, 'devA');
    expect(read.values['k']!.value, {'nested': true});
    expect(read.values['gone']!.value, isNull);
    expect(read.values['gone']!.hlc, hlcAt(4));
    expect(deviceStateItemId('devA'), 'device-state/devA');
    expect(DeviceStateDoc.of(testObject()), isNull);
    expect(
      () => DeviceStateDoc.fromExtra(const {'device': 'x', 'values': 1}),
      throwsFormatException,
    );
  });
}
