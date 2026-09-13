import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';

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

/// The headers the in-app preview ([SieveInterpreter] over synced inbox rows)
/// can actually read. Anything else — most notably delivery-added headers such
/// as `Delivered-To` — is invisible to the preview, so a filter that tests it
/// can never match locally regardless of how the server behaves.
const Set<String> previewableHeaders = {
  'subject',
  'from',
  'to',
  'cc',
  'message-id',
};

/// Headers added or rewritten by the mail server's delivery pipeline. Testing
/// them with a plain `header` test inside a Sieve script is unreliable: at the
/// time the script runs the header may be absent, or hold the account's
/// canonical address rather than the alias the mail was actually sent to.
const Set<String> _deliveryAddedHeaders = {
  'delivered-to',
  'x-delivered-to',
  'x-original-to',
  'envelope-to',
  'return-path',
  'received',
};

/// Lower-cased header names referenced by `header`/`address`/`envelope` tests.
Set<String> _referencedHeaderNames(List<SieveRule> rules) {
  final names = <String>{};
  for (final rule in rules) {
    for (final cond in rule.conditions) {
      if (cond is HeaderCondition) {
        names.addAll(cond.headers.map((h) => h.toLowerCase()));
      } else if (cond is AddressCondition) {
        names.addAll(cond.headers.map((h) => h.toLowerCase()));
      }
    }
  }
  return names;
}

/// Lower-cased header names tested with a plain `header` test (not `address`
/// or `envelope`), used to spot the delivery-added-header anti-pattern.
Set<String> _plainHeaderNames(List<SieveRule> rules) {
  final names = <String>{};
  for (final rule in rules) {
    for (final cond in rule.conditions) {
      if (cond is HeaderCondition) {
        names.addAll(cond.headers.map((h) => h.toLowerCase()));
      }
    }
  }
  return names;
}

String _quoteList(Iterable<String> names) =>
    names.map((n) => '"$n"').join(', ');

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
///   * the filter tests a header the in-app preview cannot read (so its match
///     count is meaningless — the case behind issue #701);
///   * the filter tests a delivery-added header (e.g. `Delivered-To`) that is
///     unreliable inside server Sieve;
///   * nothing in the inbox matches the filter's conditions.
///
/// [existingFolderPaths] and the folders in [fileIntoTargets] are compared as
/// `displayPath`s (the form Sieve `fileinto` stores). [rules] is the parsed
/// filter, inspected to tell an honest "nothing matched" apart from a match
/// count that could not be computed. The inputs are plain facts the caller has
/// already gathered so this stays pure and testable.
List<SieveFinding> diagnoseSieve({
  required bool scriptIsActive,
  required List<String> fileIntoTargets,
  required Set<String> existingFolderPaths,
  required int inboxMatchCount,
  required List<SieveRule> rules,
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

  // A plain `header` test on a delivery-added header (Delivered-To, …) is the
  // usual reason a filter "does nothing" on the server: the header is set by
  // the delivery pipeline, so when the script runs it may be missing or hold
  // the account's canonical address instead of the alias the mail arrived for.
  final deliveryHeaders = _plainHeaderNames(rules)
      .intersection(_deliveryAddedHeaders)
      .toList()
    ..sort();
  if (deliveryHeaders.isNotEmpty) {
    findings.add(
      SieveFinding(
        SieveFindingLevel.warning,
        'This filter tests the ${_quoteList(deliveryHeaders)} header with a '
        '"header" test. That header is added by the mail server while '
        'delivering the message, so inside a Sieve script it is often missing '
        'or holds your account\'s main address instead of the address the mail '
        'was sent to — which is why nothing gets filed. Test the recipient '
        'with envelope :is "to" "…" (add "envelope" to the require line) or '
        'address :is "to" "…" instead.',
      ),
    );
  }

  // Headers the local preview cannot read make [inboxMatchCount] meaningless:
  // a count of 0 then says nothing about whether the filter is correct.
  final unpreviewable = _referencedHeaderNames(rules)
      .difference(previewableHeaders)
      .toList()
    ..sort();

  if (inboxMatchCount == 0) {
    if (unpreviewable.isNotEmpty) {
      findings.add(
        SieveFinding(
          SieveFindingLevel.warning,
          'This filter tests the ${_quoteList(unpreviewable)} header, which the '
          'in-app preview cannot read — it only knows subject, from, to, cc '
          'and message-id. A match count of 0 here does not mean the filter is '
          'wrong; it just means the preview could not evaluate it.',
        ),
      );
    } else {
      findings.add(
        const SieveFinding(
          SieveFindingLevel.warning,
          'No messages currently in your inbox match this filter, so there may '
          'be nothing to move yet — or the conditions do not match what you '
          'expect. (This count is computed locally over the inbox messages the '
          'app has synced.)',
        ),
      );
    }
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
