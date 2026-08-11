import 'package:sharedinbox/core/sieve/sieve_actions.dart';
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
List<SieveFinding> diagnoseSieve({
  required bool scriptIsActive,
  required List<String> fileIntoTargets,
  required Set<String> existingFolderPaths,
  required int inboxMatchCount,
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

  if (inboxMatchCount == 0) {
    findings.add(
      const SieveFinding(
        SieveFindingLevel.warning,
        'No messages currently in your inbox match this filter, so there may '
        'be nothing to move yet — or the conditions do not match what you '
        'expect.',
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
