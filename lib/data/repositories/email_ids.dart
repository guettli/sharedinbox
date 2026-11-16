import 'dart:math';

/// Makes the id of a new `emails` row of an account; injectable so tests
/// can make ids they know in advance.
typedef EmailIdGenerator = String Function(String accountId);

final _random = Random.secure();

/// The id of a new `emails` row of [accountId] (SYNC-REDESIGN.md §6):
/// `<accountId>:~` and 32 random hex digits.
///
/// Opaque: it names no server location, so a reused UID can never lead to
/// another mail's row, and no code reads anything from it. Where the server
/// has the mail is in the `srv_*` columns. The account prefix is there for
/// the attachment cache, whose folders are named after the id with `:` as
/// `_` (deleting an account removes `<accountId>_*`); the rest is safe in a
/// file name and a URL. Ids made before (`account:folder:uid`,
/// `account:jmapId`, `account:__local__:…`) never look like this: they have
/// a second `:` or no `~`.
String newEmailId(String accountId) {
  final hex = StringBuffer();
  for (var i = 0; i < 16; i++) {
    hex.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return '$accountId:~$hex';
}
