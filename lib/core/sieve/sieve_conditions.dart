sealed class SieveCondition {}

final class HeaderCondition extends SieveCondition {
  HeaderCondition(this.headers, this.matchType, this.keyList);
  final List<String> headers;
  final String matchType; // ':contains', ':is', ':matches'
  final List<String> keyList;
}

/// A Sieve `address` or `envelope` test.
///
/// Unlike [HeaderCondition] it compares against the *address* part of each
/// value (`john@x` out of `John Doe <john@x>`), matching RFC 5228 `address`
/// semantics — the display name is never considered. [isEnvelope] records
/// whether the test was written as `envelope` (the SMTP envelope recipient /
/// sender) rather than `address` (a header). Both are evaluated the same way
/// against the addresses the app has cached, so a filter that tests the
/// recipient with `envelope :is "to" …` previews the same as `address`.
final class AddressCondition extends SieveCondition {
  AddressCondition(
    this.headers,
    this.matchType,
    this.keyList, {
    this.addressPart = ':all',
    this.isEnvelope = false,
  });
  final List<String> headers;
  final String matchType; // ':contains', ':is', ':matches'
  final List<String> keyList;
  final String addressPart; // ':all', ':localpart', ':domain'
  final bool isEnvelope;
}

final class SizeCondition extends SieveCondition {
  SizeCondition(this.comparison, this.bytes);
  final String comparison; // ':over' or ':under'
  final int bytes;
}
