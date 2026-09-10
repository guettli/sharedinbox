sealed class SieveCondition {}

/// Which Sieve test produced a [HeaderCondition]. The tests differ in what
/// part of the message they read:
///
///   * [header] tests the raw header value (RFC 5228 `header`).
///   * [address] tests only the address in a structured header, i.e. the
///     `local@domain` part, ignoring any display name (RFC 5228 `address`).
///   * [envelope] tests the SMTP envelope recipient/sender (RFC 5228
///     `envelope`). The app has no separate envelope store, so the preview
///     approximates `to`/`from` with the corresponding header addresses.
enum SieveTestKind { header, address, envelope }

final class HeaderCondition extends SieveCondition {
  HeaderCondition(
    this.headers,
    this.matchType,
    this.keyList, {
    this.kind = SieveTestKind.header,
    this.addressPart,
  });
  final List<String> headers;
  final String matchType; // ':contains', ':is', ':matches'
  final List<String> keyList;

  /// The test this condition came from. Governs whether the raw header value
  /// or just its address part is compared (see [SieveTestKind]).
  final SieveTestKind kind;

  /// For [SieveTestKind.address]/[SieveTestKind.envelope], the address part to
  /// compare: `:all` (default, the whole `local@domain`), `:localpart` or
  /// `:domain`. Null for plain header tests.
  final String? addressPart;
}

final class SizeCondition extends SieveCondition {
  SizeCondition(this.comparison, this.bytes);
  final String comparison; // ':over' or ':under'
  final int bytes;
}
