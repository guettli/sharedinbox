import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';

/// A lightweight email representation used by [SieveInterpreter].
/// Header names are lower-cased.
class SieveEmailContext {
  const SieveEmailContext({required this.headers, this.sizeBytes = 0});

  final Map<String, List<String>> headers;
  final int sizeBytes;

  List<String> getHeader(String name) =>
      headers[name.toLowerCase()] ?? const [];
}

/// Tracks the outcome of running a Sieve script against one email.
class SieveExecutionContext {
  bool isCancelled = false;
  Set<String> targetFolders = {};
  Set<String> flagsToAdd = {};
  bool keepInInbox = true;

  /// True when at least one non-else rule's test evaluated to true, regardless
  /// of whether the resulting actions produced a visible effect (a `keep`-only
  /// branch still counts as a match).
  bool anyRuleMatched = false;
}

/// Evaluates a compiled list of [SieveRule]s against a [SieveEmailContext].
class SieveInterpreter {
  /// Executes [rules] and returns the resulting [SieveExecutionContext].
  ///
  /// Rules produced by [SieveParser] may carry a [SieveRule.branchGroupId]
  /// to represent if/elsif/else chains; at most one branch per group fires.
  SieveExecutionContext execute(
    List<SieveRule> rules,
    SieveEmailContext email,
  ) {
    final ctx = SieveExecutionContext();
    final firedGroups = <int>{};

    for (final rule in rules) {
      if (ctx.isCancelled) break;

      final groupId = rule.branchGroupId;
      if (groupId != null && firedGroups.contains(groupId)) continue;

      bool matches;
      if (rule.isElseBranch) {
        matches = true; // else fires unconditionally (group not yet consumed)
      } else {
        matches = _evaluateConditions(rule, email);
      }

      if (matches) {
        if (!rule.isElseBranch) ctx.anyRuleMatched = true;
        _applyActions(rule.actions, ctx);
        if (groupId != null) firedGroups.add(groupId);
        if (ctx.isCancelled) break;
      }
    }

    // Implicit keep: if no fileinto/discard was reached, email stays in inbox.
    return ctx;
  }

  bool _evaluateConditions(SieveRule rule, SieveEmailContext email) {
    if (rule.conditions.isEmpty) return true;
    return switch (rule.joinType) {
      'allof' => rule.conditions.every((c) => _evalCondition(c, email)),
      'anyof' => rule.conditions.any((c) => _evalCondition(c, email)),
      _ => rule.conditions.length == 1 &&
          _evalCondition(rule.conditions.first, email),
    };
  }

  bool _evalCondition(SieveCondition cond, SieveEmailContext email) {
    return switch (cond) {
      final HeaderCondition c => _evalHeader(c, email),
      final SizeCondition c => _evalSize(c, email),
    };
  }

  bool _evalHeader(HeaderCondition cond, SieveEmailContext email) {
    for (final header in cond.headers) {
      final values = email.getHeader(header);
      for (final rawValue in values) {
        // `address`/`envelope` tests compare only the address (or a part of
        // it), not the raw "Display Name <local@domain>" header value.
        final candidates = cond.kind == SieveTestKind.header
            ? [rawValue]
            : _addressCandidates(rawValue, cond.addressPart);
        for (final value in candidates) {
          for (final key in cond.keyList) {
            if (_matchString(value, cond.matchType, key)) return true;
          }
        }
      }
    }
    return false;
  }

  /// Extracts the address parts to compare for an `address`/`envelope` test.
  /// A single header value may hold several comma-separated addresses; each is
  /// reduced to its `local@domain` (or [addressPart]).
  List<String> _addressCandidates(String rawValue, String? addressPart) {
    final result = <String>[];
    for (final part in rawValue.split(',')) {
      final email = _extractEmail(part);
      if (email.isEmpty) continue;
      switch (addressPart) {
        case ':localpart':
        case ':user':
          final at = email.indexOf('@');
          result.add(at >= 0 ? email.substring(0, at) : email);
        case ':domain':
          final at = email.indexOf('@');
          if (at >= 0) result.add(email.substring(at + 1));
        default:
          result.add(email);
      }
    }
    return result;
  }

  /// Pulls the bare address out of a header value that may be either
  /// `local@domain` or `Display Name <local@domain>`.
  String _extractEmail(String value) {
    final v = value.trim();
    final open = v.indexOf('<');
    final close = v.indexOf('>', open + 1);
    if (open >= 0 && close > open) {
      return v.substring(open + 1, close).trim();
    }
    return v;
  }

  bool _evalSize(SizeCondition cond, SieveEmailContext email) {
    return switch (cond.comparison) {
      ':over' => email.sizeBytes > cond.bytes,
      ':under' => email.sizeBytes < cond.bytes,
      _ => false,
    };
  }

  bool _matchString(String value, String matchType, String key) {
    final v = value.toLowerCase();
    final k = key.toLowerCase();
    return switch (matchType) {
      ':contains' => k.isEmpty || v.contains(k),
      ':is' => v == k,
      ':matches' => globMatch(v, k),
      _ => false,
    };
  }

  void _applyActions(List<SieveAction> actions, SieveExecutionContext ctx) {
    for (final action in actions) {
      switch (action) {
        case final FileIntoAction a:
          ctx.targetFolders.add(a.folder);
          ctx.keepInInbox = false;
        case DiscardAction():
          ctx.isCancelled = true;
          ctx.keepInInbox = false;
          return;
        case KeepAction():
          ctx.keepInInbox = true;
        case MarkAsSeenAction():
          ctx.flagsToAdd.add(r'\Seen');
        case StarMessageAction():
          ctx.flagsToAdd.add(r'\Flagged');
        case final FlagAction a:
          ctx.flagsToAdd.addAll(a.flags);
      }
    }
  }
}
