import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';

import 'helpers/stateful_fake_imap.dart';

/// EXPUNGE fails, as a server may refuse it.
class _FailingExpungeClient extends StatefulFakeImapClient {
  _FailingExpungeClient(super.server);

  @override
  Future<imap.Mailbox?> expunge() async =>
      throw imap.ImapException(this, 'NO expunge refused');
}

void main() {
  StatefulFakeImapServer serverWith({required bool uidPlus}) =>
      StatefulFakeImapServer(
        uidValidityByFolder: {'Trash': 7},
        uidPlus: uidPlus,
      );

  Future<StatefulFakeImapClient> select(
    StatefulFakeImapClient client,
  ) async {
    await client.selectMailboxByPath('Trash');
    return client;
  }

  bool isFlaggedDeleted(StatefulFakeImapServer server, String messageId) =>
      server.find(messageId)!.message.flags.contains(r'\Deleted');

  for (final uidPlus in [true, false]) {
    group('UIDPLUS=$uidPlus', () {
      test('expunges only the given message', () async {
        final server = serverWith(uidPlus: uidPlus);
        final mine = server.deliver('Trash', 'mine@test');
        server.deliver('Trash', 'kept@test');
        final client = await select(server.connect());

        await deleteAndExpungeUids(client, [mine.uid]);

        expect(server.find('mine@test'), isNull);
        expect(server.find('kept@test'), isNotNull);
      });

      test(
        'keeps a message another client flagged \\Deleted, flag and all',
        () async {
          final server = serverWith(uidPlus: uidPlus);
          final mine = server.deliver('Trash', 'mine@test');
          server.deliver('Trash', 'theirs@test', flags: [r'\Deleted']);
          final client = await select(server.connect());

          await deleteAndExpungeUids(client, [mine.uid]);

          expect(server.find('mine@test'), isNull);
          expect(server.find('theirs@test'), isNotNull);
          expect(isFlaggedDeleted(server, 'theirs@test'), isTrue);
        },
      );
    });
  }

  test('without UIDPLUS it never sends UID EXPUNGE', () async {
    final server = serverWith(uidPlus: false);
    final mine = server.deliver('Trash', 'mine@test');
    final client = await select(server.connect());

    // The fake answers UID EXPUNGE with BAD without UIDPLUS, as servers do.
    await expectLater(deleteAndExpungeUids(client, [mine.uid]), completes);
  });

  test(
    'a failed EXPUNGE gives the other message its \\Deleted flag back',
    () async {
      final server = serverWith(uidPlus: false);
      final mine = server.deliver('Trash', 'mine@test');
      server.deliver('Trash', 'theirs@test', flags: [r'\Deleted']);
      final client = await select(_FailingExpungeClient(server));

      await expectLater(
        deleteAndExpungeUids(client, [mine.uid]),
        throwsA(isA<imap.ImapException>()),
      );

      expect(isFlaggedDeleted(server, 'theirs@test'), isTrue);
      expect(server.find('mine@test'), isNotNull);
    },
  );
}
