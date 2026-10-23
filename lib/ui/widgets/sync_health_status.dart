import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// The current sync-health status of one account: a spinner while a
/// verification runs, otherwise the stored result (healthy / discrepancies /
/// failure) with the time it was verified. Shared by the account list and the
/// account home screen so both show the same state.
class SyncHealthStatus extends ConsumerWidget {
  const SyncHealthStatus({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(syncHealthProvider(accountId));
    final isVerifying =
        (ref.watch(syncHealthVerifyingProvider).value ?? const <String>{})
            .contains(accountId);
    return health.when(
      data: (h) {
        if (isVerifying) return const _SyncHealthVerifyingRow();
        if (h == null) return const Text('Sync health: Not verified yet');
        if (h.lastError != null) {
          return _SyncHealthErrorRow(error: h.lastError!);
        }
        return _SyncHealthResultRow(
          isHealthy: h.isHealthy,
          lastVerifiedAt: h.lastVerifiedAt,
          discrepancySummary: h.discrepancySummary,
        );
      },
      loading: () => isVerifying
          ? const _SyncHealthVerifyingRow()
          : const Text('Sync health: checking...'),
      error: (e, _) => Text('Sync health error: ${userErrorMessage(e)}'),
    );
  }
}

/// One-line, human-readable outcome of a finished verification, for the
/// snackbar shown when a manual "Verify sync health" completes. [isHealthy] is
/// null when no result has been stored.
String syncHealthResultMessage({
  required bool? isHealthy,
  String? lastError,
  String? discrepancySummary,
}) {
  if (isHealthy == null) return 'Sync health: Not verified yet';
  if (lastError != null) {
    return 'Sync check failed: ${userErrorMessage(lastError)}';
  }
  if (isHealthy) return 'Sync health: Healthy';
  final details = _discrepancyLines(discrepancySummary);
  return details.isEmpty
      ? 'Sync health: Discrepancies found'
      : 'Sync health: Discrepancies found (${details.join(', ')})';
}

/// Shown in the sync-health row while a verification is in flight, so a manual
/// "Verify sync health" is visibly running instead of silently unchanged.
class _SyncHealthVerifyingRow extends StatelessWidget {
  const _SyncHealthVerifyingRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: AppIconSize.sm,
          height: AppIconSize.sm,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: AppSpacing.xs),
        // Expanded, not a bare Text: the spinner is a fixed width, so an
        // unconstrained label overflows the row at large text scales exactly
        // as the result row did.
        Expanded(child: Text('Sync health: verifying...')),
      ],
    );
  }
}

/// Shown when the last verification failed to complete, so the user can see
/// why instead of the row staying on "Not verified yet".
class _SyncHealthErrorRow extends StatelessWidget {
  const _SyncHealthErrorRow({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.error_outline,
          size: AppIconSize.sm,
          color: Colors.red,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: Text('Sync check failed: ${userErrorMessage(error)}')),
      ],
    );
  }
}

/// Shown when a verification finished, for both healthy and unhealthy
/// accounts. A short header line ("Sync health: Healthy/Discrepancies found"
/// plus the verified date) keeps the status readable at phone widths; each
/// discrepancy metric then gets its own line below instead of being crammed
/// into a single overflowing sentence.
class _SyncHealthResultRow extends StatelessWidget {
  const _SyncHealthResultRow({
    required this.isHealthy,
    required this.lastVerifiedAt,
    required this.discrepancySummary,
  });

  final bool isHealthy;
  final DateTime lastVerifiedAt;
  final String? discrepancySummary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = lastVerifiedAt.toLocal().toString().split('.')[0];
    final iconSize = MediaQuery.textScalerOf(context).scale(AppIconSize.sm);
    final details =
        isHealthy ? const <String>[] : _discrepancyLines(discrepancySummary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // One RichText rather than a Row. A Row sized 'Sync health: ' and the
        // date to their intrinsic widths, so once the text scale grew they
        // squeezed the Expanded status down to nothing — rendering 'Healthy'
        // one letter per line — and still overflowed (by 52px on a Galaxy A80
        // at font_scale 1.8). Inline spans soft-wrap onto further lines
        // instead; the only placeholder here is the fixed-size status icon, so
        // nothing in this paragraph can exceed the line width.
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Sync health: '),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(
                  isHealthy ? Icons.verified : Icons.warning_amber,
                  // Scaled with the text: WidgetSpan children are not
                  // text-scaled, so a fixed 16px glyph next to 28px text at
                  // scale 2.0 reads as a rendering fault.
                  size: iconSize,
                  color: isHealthy ? Colors.green : Colors.orange,
                  // Colour alone distinguishes healthy from degraded, so the
                  // state has to reach a screen reader some other way.
                  semanticLabel: isHealthy ? 'healthy' : 'warning',
                ),
              ),
              // Non-breaking space: a plain space is a legal wrap point, which
              // would strand the icon alone at the end of a line.
              TextSpan(
                text: '\u00A0${isHealthy ? 'Healthy' : 'Discrepancies found'}',
              ),
              TextSpan(
                text: ' ($date)',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        for (final line in details)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              line,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// Parses the stored discrepancy summary into one human-readable line per
/// non-zero metric (e.g. "missing locally: 3"). Returns an empty list when the
/// summary is absent, unparseable, or reports no discrepancies, in which case
/// the caller shows just "Discrepancies found".
List<String> _discrepancyLines(String? summary) {
  if (summary == null) return const [];
  try {
    final decoded = jsonDecode(summary) as Map<String, dynamic>;
    var missingLocally = 0;
    var missingOnServer = 0;
    var flagMismatches = 0;
    for (final v in decoded.values) {
      final m = v as Map<String, dynamic>;
      missingLocally += (m['missingLocally'] as int? ?? 0);
      missingOnServer += (m['missingOnServer'] as int? ?? 0);
      flagMismatches += (m['flagMismatches'] as int? ?? 0);
    }
    final lines = <String>[];
    if (missingLocally > 0) lines.add('missing locally: $missingLocally');
    if (missingOnServer > 0) lines.add('missing on server: $missingOnServer');
    if (flagMismatches > 0) lines.add('flag mismatches: $flagMismatches');
    return lines;
  } catch (_) {
    return const [];
  }
}
