import 'dart:io' show SocketException;

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';

import 'helpers/stateful_fake_imap.dart';

/// EXPUNGE fails with [error] (the connection dropped), or without one is
/// refused by the server; [restores] counts the `\Deleted` re-flags tried afterwards.
class _FailingExpungeClient extends StatefulFakeImapClient {
  _FailingExpungeClient(super.server, [this.error]);

  final Object? error;
  int restores = 0;
  bool _expunged = false;

  @override
  Future<imap.Mailbox?> expunge() async {
    _expunged = true;
    throw error ?? imap.ImapException(this, 'NO expunge refused');
  }

  @override
  Future<imap.StoreImapResult> fakeStore(
    imap.MessageSequence sequence,
    List<String> flags,
    imap.StoreAction action,
  ) {
    if (_expunged) restores++;
    return super.fakeStore(sequence, flags, action);
  }
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
        final commands = <String>[];
        server.beforeAnswer = (command) async => commands.add(command);

        await deleteAndExpungeUids(client, [mine.uid]);

        expect(server.find('mine@test'), isNull);
        expect(server.find('kept@test'), isNotNull);
        expect(
          commands.where((c) => c.contains('EXPUNGE')),
          [if (uidPlus) 'UID EXPUNGE (Trash)' else 'EXPUNGE (Trash)'],
        );
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

  test('a dropped connection is not followed by a restore attempt', () async {
    final server = serverWith(uidPlus: false);
    final mine = server.deliver('Trash', 'mine@test');
    server.deliver('Trash', 'theirs@test', flags: [r'\Deleted']);
    final client = _FailingExpungeClient(
      server,
      const SocketException('Connection reset by peer'),
    );
    await select(client);

    await expectLater(
      deleteAndExpungeUids(client, [mine.uid]),
      throwsA(isA<SocketException>()),
    );

    expect(client.restores, 0);
  });
}
