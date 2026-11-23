import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/device_state.dart';

import 'db_test_helper.dart';
import 'helpers/mail_object_rig.dart';

void main() {
  setUpAll(configureSqliteForTests);

  for (final transport in ObjectTransport.values) {
    test(
        '${transport.name}: two devices converge to the value with the '
        'highest HLC per key, an unset included', () async {
      final rig = ObjectRig(transport);
      final a = await rig.device();
      final b = await rig.device();

      await a.state.set(a.accountId, 'theme', 'dark');
      await a.state.set(a.accountId, 'deck', 'd1');
      await a.store.waitForIdle();
      await b.listAndSync();
      // B's clock has seen A's versions: its writes are newer.
      await b.state.set(b.accountId, 'theme', 'light');
      await b.state.set(b.accountId, 'deck', null);
      await b.state.set(b.accountId, 'only-b', 1);
      await b.store.waitForIdle();
      await a.sync();
      await a.state.set(a.accountId, 'only-a', true);
      await a.store.waitForIdle();
      await b.sync();

      const expected = {'theme': 'light', 'only-b': 1, 'only-a': true};
      for (final d in [a, b]) {
        expect(await d.state.watch(d.accountId).first, expected);
        expect(await d.state.get(d.accountId, 'deck'), isNull);
      }
      // One doc per device, one version each.
      final docs = [
        for (final r in await a.rows())
          if (r.kind == deviceStateKind) r.itemId,
      ];
      expect(docs, hasLength(2));
      expect(docs.toSet(), hasLength(2));
    });
  }

  test('a value set again on the same device replaces the old one', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();

    await a.state.set(a.accountId, 'k', 1);
    await a.state.set(a.accountId, 'k', 2);
    await a.state.set(a.accountId, 'k', null);
    await a.state.set(a.accountId, 'k', 3);
    await a.store.waitForIdle();

    expect(await a.state.get(a.accountId, 'k'), 3);
    expect(rig.dataIds(), hasLength(1));
  });
}
