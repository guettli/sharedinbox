import 'package:drift/drift.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

/// Prefetches email bodies in the background and enforces a local cache size
/// limit by evicting the oldest cached bodies when the limit is exceeded.
class BodyCacheService {
  BodyCacheService(this._db, this._accountRepo);

  final AppDatabase _db;
  final AccountRepository _accountRepo;

  static const _batchSize = 20;

  Future<void> run() async {
    final prefs = await (_db.select(
      _db.userPreferences,
    )).getSingleOrNull();
    final limitMb = prefs?.bodyCacheLimitMb ?? 100;
    final limitBytes = limitMb * 1024 * 1024;

    await _evictIfNeeded(limitBytes);

    final candidates = await _fetchCandidates();
    if (candidates.isEmpty) return;

    final emailRepo = EmailRepositoryImpl(_db, _accountRepo);

    try {
      for (final emailId in candidates) {
        final currentSize = await _getCacheSizeBytes();
        if (currentSize >= limitBytes) break;
        try {
          await emailRepo.getEmailBody(emailId, prefetch: true);
        } catch (_) {
          // Skip emails that fail to fetch.
        }
      }
    } finally {
      // These fetches share one pooled IMAP connection (#679); release it as
      // soon as the batch is done instead of waiting for the idle timer.
      await emailRepo.dispose();
    }
  }

  Future<void> _evictIfNeeded(int limitBytes) async {
    final currentSize = await _getCacheSizeBytes();
    if (currentSize <= limitBytes) return;

    final bodies = await (_db.select(_db.emailBodies)
          ..where((t) => t.cachedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.asc(t.cachedAt)]))
        .get();

    var remaining = currentSize;
    for (final body in bodies) {
      if (remaining <= limitBytes) break;
      final bodySize =
          (body.textBody?.length ?? 0) + (body.htmlBody?.length ?? 0);
      await (_db.delete(_db.emailBodies)
            ..where((t) => t.emailId.equals(body.emailId)))
          .go();
      remaining -= bodySize;
    }
  }

  Future<int> _getCacheSizeBytes() async {
    final result = await _db
        .customSelect(
          "SELECT COALESCE(SUM(LENGTH(COALESCE(text_body, '')) + LENGTH(COALESCE(html_body, ''))), 0) AS total FROM email_bodies",
        )
        .getSingle();
    return result.read<int>('total');
  }

  Future<List<String>> _fetchCandidates() async {
    final rows = await _db.customSelect(
      'SELECT e.id FROM emails e '
      'LEFT JOIN email_bodies eb ON eb.email_id = e.id '
      'WHERE eb.email_id IS NULL '
      'ORDER BY e.received_at DESC '
      'LIMIT ?',
      variables: [Variable.withInt(_batchSize)],
    ).get();
    return rows.map((r) => r.read<String>('id')).toList();
  }
}
