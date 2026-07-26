/// Push (RFC 8887 EventSource) connection state for a JMAP account, as
/// captured in the `sync.jmap.push` app-log event's `push_status` data field.
///
/// Every branch of `EmailRepositoryImpl.watchJmapPush` writes exactly one row
/// tagged with one of these values; the sync-state view reads the newest row
/// per account and renders it. Keeping the strings in one place stops the
/// writer and reader drifting.
enum JmapPushStatus {
  /// SSE stream opened successfully and the loop is waiting on real
  /// `StateChange` events. This is the "no 30 s poll" happy path.
  connected('connected'),

  /// The JMAP session was fetched but the server did not advertise an
  /// `eventSourceUrl`, or the account is missing its JMAP URL entirely.
  unsupported('unsupported'),

  /// `JmapClient.connect()` threw — usually a network hiccup or bad
  /// credentials. Transient.
  connectFailed('connect_failed'),

  /// The SSE `GET` request itself failed (timeout, socket error, TLS…).
  sseFailed('sse_failed'),

  /// The SSE endpoint returned a non-200 HTTP status. The concrete status
  /// code is appended when logged (e.g. `sse_status_401`, `sse_status_502`)
  /// but this constant is the recognised prefix for parsers.
  sseStatusPrefix('sse_status_'),

  /// The SSE stream closed cleanly (`onDone`) after being connected — usually
  /// the built-in 25-min cap, sometimes the server proactively closing.
  closed('closed'),

  /// The SSE stream errored after being connected. Distinct from
  /// [sseFailed] which covers the initial connect.
  errored('errored');

  const JmapPushStatus(this.wireName);

  final String wireName;
}
