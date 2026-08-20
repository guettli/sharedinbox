import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/di.dart';

const _kAppVersion = String.fromEnvironment('GIT_HASH');
const _kCompareUrl =
    'https://api.github.com/repos/guettli/sharedinbox/compare';

/// Outcome of comparing the running build against the `main` branch.
enum RepoStatusState {
  /// The running build is the tip of `main` (nothing to pull).
  upToDate,

  /// `main` has commits the running build does not contain.
  behind,

  /// GitHub could not be reached, or the response was unusable.
  unknown,
}

/// How far the running build is behind `main`, as reported by GitHub.
class RepoStatus {
  const RepoStatus({
    required this.state,
    this.behindCount = 0,
    this.latestCommitDate,
  });

  final RepoStatusState state;

  /// Number of commits on `main` that are not in the running build.
  final int behindCount;

  /// Commit date of the tip of `main`, when known.
  final DateTime? latestCommitDate;
}

/// Compares [appVersion] (the build's commit) against `main` via the GitHub
/// compare API, returning how many commits the build is behind and the date of
/// the latest `main` commit. Never throws: any failure maps to
/// [RepoStatusState.unknown].
Future<RepoStatus> fetchRepoStatus(http.Client client, String appVersion) async {
  try {
    final resp = await client.get(
      Uri.parse('$_kCompareUrl/$appVersion...main'),
      headers: const {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      return const RepoStatus(state: RepoStatusState.unknown);
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    // In `compare/base...head` with base=build and head=main, `ahead_by` counts
    // the commits that main has but the build does not.
    final aheadBy = (json['ahead_by'] as num?)?.toInt() ?? 0;
    final latestCommitDate = _latestCommitDate(json);
    if (aheadBy <= 0) {
      return RepoStatus(
        state: RepoStatusState.upToDate,
        latestCommitDate: latestCommitDate,
      );
    }
    return RepoStatus(
      state: RepoStatusState.behind,
      behindCount: aheadBy,
      latestCommitDate: latestCommitDate,
    );
  } catch (_) {
    return const RepoStatus(state: RepoStatusState.unknown);
  }
}

/// Extracts the committer date of the tip of `main` (the last entry in the
/// compare response's `commits` list), or null when unavailable.
DateTime? _latestCommitDate(Map<String, dynamic> json) {
  final commits = json['commits'];
  if (commits is! List || commits.isEmpty) return null;
  final head = commits.last;
  if (head is! Map) return null;
  final commit = head['commit'];
  if (commit is! Map) return null;
  final committer = commit['committer'];
  if (committer is! Map) return null;
  final date = committer['date'];
  if (date is! String) return null;
  return DateTime.tryParse(date);
}

/// Compares the running build against `main`. Returns null for development
/// builds (no `GIT_HASH`), where there is nothing to compare against.
final repoStatusProvider = FutureProvider<RepoStatus?>((ref) async {
  if (_kAppVersion.isEmpty) return null;
  return fetchRepoStatus(ref.watch(httpClientProvider), _kAppVersion);
});
