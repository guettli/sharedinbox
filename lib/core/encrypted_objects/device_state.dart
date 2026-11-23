import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Device-state documents (`ENCRYPTED-OBJECTS.md` 5.4 item 4, #1372): one
/// document per device, a key → value map with an HLC per key. The
/// effective value of a key is the one with the highest HLC across all
/// devices' docs; a value `null` means unset.

const deviceStateKind = 'device-state';

/// The fixed itemId of the device-state doc of [deviceId]; only that device
/// writes versions of it.
String deviceStateItemId(String deviceId) => 'device-state/$deviceId';

/// One key of a device-state doc: [value] (null = unset) as of [hlc].
class DeviceStateValue {
  const DeviceStateValue(this.value, this.hlc);

  final Object? value;
  final Hlc hlc;

  Map<String, Object?> toJson() => {'v': value, 'h': hlc.encode()};
}

/// The kind fields of a device-state head: `{device, values: {key: {v, h}}}`.
class DeviceStateDoc {
  DeviceStateDoc({
    required this.device,
    Map<String, DeviceStateValue> values = const {},
  }) : values = Map.unmodifiable(values);

  /// Reads the kind fields of a head; throws [FormatException].
  factory DeviceStateDoc.fromExtra(Map<String, Object?> extra) {
    final values = extra['values'];
    if (values is! Map) throw const FormatException('bad device-state values');
    return DeviceStateDoc(
      device: readStringField(extra, 'device'),
      values: {
        for (final MapEntry(:key, :value) in values.entries)
          key as String: _readValue(value),
      },
    );
  }

  static DeviceStateValue _readValue(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('bad device-state value');
    }
    return DeviceStateValue(json['v'], Hlc.parse(readStringField(json, 'h')));
  }

  /// The doc of [object]; null when it is no live device-state doc or is
  /// malformed.
  static DeviceStateDoc? of(InnerObject object) {
    if (object.head.kind != deviceStateKind || object.head.deleted) {
      return null;
    }
    try {
      return DeviceStateDoc.fromExtra(object.head.extra);
    } on FormatException {
      return null;
    }
  }

  final String device;
  final Map<String, DeviceStateValue> values;

  /// This doc with [key] set to [value] (null: unset) as of [hlc].
  DeviceStateDoc withValue(String key, Object? value, Hlc hlc) =>
      DeviceStateDoc(
        device: device,
        values: {...values, key: DeviceStateValue(value, hlc)},
      );

  Map<String, Object?> toExtra() => {
        'device': device,
        'values': {
          for (final MapEntry(:key, :value) in values.entries)
            key: value.toJson(),
        },
      };
}

/// The value of every key with the highest HLC across [docs]; keys whose
/// winner is `null` (unset) are left out.
Map<String, Object?> effectiveDeviceState(Iterable<DeviceStateDoc> docs) {
  final best = <String, DeviceStateValue>{};
  for (final doc in docs) {
    for (final MapEntry(:key, :value) in doc.values.entries) {
      final seen = best[key];
      if (seen == null || value.hlc > seen.hlc) best[key] = value;
    }
  }
  return {
    for (final MapEntry(:key, :value) in best.entries)
      if (value.value != null) key: value.value,
  };
}
