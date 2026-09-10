import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';

/// Headers the in-app preview can populate from cached mail — see
/// `EmailRepositoryImpl._buildSieveContext`. A `header` test on anything
/// outside this set cannot be evaluated locally, so the preview match count
/// tells the user nothing about that condition.
const previewableSieveHeaders = <String>{
  'subject',
  'from',
  'to',
  'cc',
  'message-id',
};

/// Headers written by the mail server's delivery pipeline (not by the sender).
/// The app never caches them, and testing them with `header` in server-side
/// Sieve is fragile because at filtering time they may be absent or hold the
/// account's canonical address rather than the alias the mail arrived for.
const _deliveryAddedHeaders = <String>{
  'delivered-to',
  'x-original-to',
  'x-original-recipient',
  'x-delivered-to',
  'return-path',
  'received',
};

/// Severity of a single [SieveFinding].
enum SieveFindingLevel {
  /// Nothing wrong that the app can detect.
  ok,

  /// A likely explanation for "the filter isn't doing anything".
  warning,
}

/// One human-readable conclusion produced by [diagnoseSieve].
class SieveFinding {
  const SieveFinding(this.level, this.message);

  final SieveFindingLevel level;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is SieveFinding && other.level == level && other.message == message;

  @override
  int get hashCode => Object.hash(level, message);

  @override
  String toString() => 'SieveFinding($level, $message)';
}

/// Returns the target folders of every `fileinto` action across [rules],
/// in document order and including duplicates.
List<String> fileIntoTargets(List<SieveRule> rules) => [
      for (final rule in rules)
        for (final action in rule.actions)
          if (action is FileIntoAction) action.folder,
    ];

/// Explains, in plain language, why a Sieve filter might not be moving mail —
/// the case behind issue #435 ("I created a filter to move some messages, but
/// the corresponding folder does not get new messages").
///
/// Server-side Sieve runs at delivery time on the mail server, so its *runtime*
/// errors are only ever written to the server's own logs — no mail protocol
/// (ManageSieve, JMAP) exposes them to a client. What the app *can* check are
/// the common local causes, which is what this function reports:
///
///   * the script is not the active one (the server only runs the active
///     script);
///   * a `fileinto` target folder does not exist on the server;
///   * nothing in the inbox matches the filter's conditions.
///
/// [existingFolderPaths] and the folders in [fileIntoTargets] are compared as
/// `displayPath`s (the form Sieve `fileinto` stores). The inputs are plain
/// facts the caller has already gathered so this stays pure and testable.
///
/// When [rules] are supplied, the check also reports the case behind issue
/// #701: a filter that tests a delivery-added header (e.g. `Delivered-To`).
/// Such a filter can never match in the local preview — the app has no copy of
/// that header — so a bare "0 matches" would be misleading; instead the user
/// is told the count is not meaningful and is pointed at an `envelope`/`address`
/// recipient test that the server can evaluate reliably.
List<SieveFinding> diagnoseSieve({
  required bool scriptIsActive,
  required List<String> fileIntoTargets,
  required Set<String> existingFolderPaths,
  required int inboxMatchCount,
  List<SieveRule> rules = const [],
}) {
  final findings = <SieveFinding>[];

  if (!scriptIsActive) {
    findings.add(
      const SieveFinding(
        SieveFindingLevel.warning,
        'This filter is not active. The mail server only runs the active '
        'filter, so incoming mail is not processed by this one. Set it active '
        'from the filter list.',
      ),
    );
  }

  final missing = <String>[];
  for (final target in fileIntoTargets) {
    if (!existingFolderPaths.contains(target) && !missing.contains(target)) {
      missing.add(target);
    }
  }
  for (final folder in missing) {
    findings.add(
      SieveFinding(
        SieveFindingLevel.warning,
        'The target folder "$folder" does not exist on the server. Messages '
        'matching this rule cannot be filed there until the folder is created.',
      ),
    );
  }

  // Headers this filter tests that the local preview cannot read, split into
  // the delivery-added ones (which get their own actionable advice) and the
  // rest (a generic "cannot evaluate" note).
  final deliveryHeaders = <String>[];
  final otherUnevaluable = <String>[];
  for (final header in _unevaluableHeaders(rules)) {
    if (_deliveryAddedHeaders.contains(header)) {
      deliveryHeaders.add(header);
    } else {
      otherUnevaluable.add(header);
    }
  }

  if (deliveryHeaders.isNotEmpty) {
    final names = deliveryHeaders.map(_displayHeader).join('", "');
    findings.add(
      SieveFinding(
        SieveFindingLevel.warning,
        'This filter tests the "$names" header. That header is added by the '
        'mail server while delivering the message, so the in-app preview '
        'cannot read it from your cached mail — which is why it reports 0 '
        'matches. Server-side Sieve is also unreliable here: when the filter '
        'runs, the header may be missing or hold your main address instead of '
        'the alias the mail was sent to. To match the recipient reliably, test '
        'the envelope instead, e.g. add "envelope" to your require line and '
        'use  envelope :is "to" "alias@example.com"  (or  address :is "to" '
        '"alias@example.com"  to test the To header).',
      ),
    );
  }

  if (otherUnevaluable.isNotEmpty) {
    final names = otherUnevaluable.map(_displayHeader).join('", "');
    findings.add(
      SieveFinding(
        SieveFindingLevel.warning,
        'This filter tests the "$names" header, which the in-app preview '
        'cannot read from your cached mail (it only has subject, from, to, cc '
        'and message-id). The match count is therefore not meaningful for this '
        'filter.',
      ),
    );
  }

  // Only claim "nothing matches" when the preview could actually evaluate the
  // whole filter. If it tests a header we cannot see, 0 is an artifact of the
  // preview, not evidence about the filter — the notes above already explain
  // that, so we suppress the misleading zero-match warning here.
  final previewIsMeaningful =
      deliveryHeaders.isEmpty && otherUnevaluable.isEmpty;

  if (previewIsMeaningful && inboxMatchCount == 0) {
    findings.add(
      const SieveFinding(
        SieveFindingLevel.warning,
        'No messages currently in your inbox match this filter. This count is '
        'computed on this device over the mail already synced here, using only '
        'cached headers, so 0 can simply mean there is nothing to move yet — it '
        'is not proof that the server filter is wrong.',
      ),
    );
  }

  if (findings.isEmpty) {
    findings.add(
      SieveFinding(
        SieveFindingLevel.ok,
        'This filter is active, its target folders exist and it matches '
        '$inboxMatchCount message(s) in your inbox. If the server still is '
        'not filing new mail, the cause is on the mail server and only '
        'visible in its logs.',
      ),
    );
  }

  return findings;
}

/// Header names tested by a plain `header` test in [rules] that the in-app
/// preview cannot evaluate, in first-seen order without duplicates.
///
/// `address`/`envelope` tests on `to`/`from`/`cc` are considered evaluable —
/// the preview derives those addresses from cached mail — so they are not
/// reported here.
List<String> _unevaluableHeaders(List<SieveRule> rules) {
  final result = <String>[];
  for (final rule in rules) {
    for (final cond in rule.conditions) {
      if (cond is! HeaderCondition) continue;
      for (final rawHeader in cond.headers) {
        final header = rawHeader.toLowerCase();
        final evaluable = switch (cond.kind) {
          SieveTestKind.header => previewableSieveHeaders.contains(header),
          SieveTestKind.address ||
          SieveTestKind.envelope =>
            header == 'to' || header == 'from' || header == 'cc',
        };
        if (!evaluable && !result.contains(header)) {
          result.add(header);
        }
      }
    }
  }
  return result;
}

/// Renders a lower-cased header name in its conventional capitalisation, e.g.
/// `delivered-to` -> `Delivered-To`.
String _displayHeader(String header) => header
    .split('-')
    .map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}')
    .join('-');
