import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

/// Fetches the bodies of one prefetch run; [close] releases its connection.
abstract class BodyFetcher {
  Future<void> fetch(String emailId);
  Future<void> close();
}

class _RepoBodyFetcher implements BodyFetcher {
  _RepoBodyFetcher(this._repo);

  final EmailRepositoryImpl _repo;

  @override
  Future<void> fetch(String emailId) =>
      _repo.getEmailBody(emailId, prefetch: true);

  @override
  Future<void> close() => _repo.dispose();
}

/// Prefetches email bodies in the background and enforces a local cache size
/// limit by evicting the oldest cached bodies when the limit is exceeded.
///
/// A long-lived instance (the desktop in-process scheduler keeps one for the
/// app's lifetime) remembers messages whose fetch failed while others in the
/// same batch succeeded, and skips them for [failedRetryAfter], so a few
/// permanently failing messages are not re-picked first on every run.
class BodyCacheService {
  BodyCacheService(
    this._db,
    this._accountRepo, {
    ImapConnectFn imapConnect = connectImap,
    AppLogger? appLogger,
    // Test seams: fake the per-run fetcher and the clock.
    BodyFetcher Function()? fetcherFactory,
    DateTime Function() clock = DateTime.now,
  })  : _imapConnect = imapConnect,
        _appLogger = appLogger,
        _fetcherFactory = fetcherFactory,
        _clock = clock;

  final AppDatabase _db;
  final AccountRepository _accountRepo;
  final ImapConnectFn _imapConnect;
  final AppLogger? _appLogger;
  final BodyFetcher Function()? _fetcherFactory;
  final DateTime Function() _clock;

  static const _batchSize = 20;
  static const failedRetryAfter = Duration(hours: 24);

  final _failedAt = <String, DateTime>{};

  /// Prefetches up to [maxBatches] batches of bodies, stopping early when no
  /// candidates are left, the cache limit is reached, or a batch cached
  /// nothing (offline / server down). [pauseBetweenFetches] spaces the
  /// fetches out so a long run does not compete with the UI. Returns the
  /// number of bodies cached.
  Future<int> run({
    int maxBatches = 1,
    Duration pauseBetweenFetches = Duration.zero,
  }) async {
    final prefs = await (_db.select(
      _db.userPreferences,
    )).getSingleOrNull();
    final limitMb = prefs?.bodyCacheLimitMb ?? 100;
    final limitBytes = limitMb * 1024 * 1024;

    await _evictIfNeeded(limitBytes);

    var cached = 0;
    var attempts = 0;
    BodyFetcher? fetcher;
    try {
      for (var batch = 0; batch < maxBatches; batch++) {
        final candidates = await _fetchCandidates();
        if (candidates.isEmpty) break;
        fetcher ??= _createFetcher();
        var batchCached = 0;
        final batchFailed = <String>[];
        for (final emailId in candidates) {
          if (await _getCacheSizeBytes() >= limitBytes) return cached;
          if (attempts++ > 0 && pauseBetweenFetches > Duration.zero) {
            await Future<void>.delayed(pauseBetweenFetches);
          }
          try {
            await fetcher.fetch(emailId);
            batchCached++;
            cached++;
          } catch (_) {
            // Skip emails that fail to fetch.
            batchFailed.add(emailId);
          }
        }
        // Nothing worked: most likely offline or the server is down, not a
        // problem with these messages — don't mark them, just stop.
        if (batchCached == 0) break;
        final now = _clock();
        for (final id in batchFailed) {
          _failedAt[id] = now;
        }
      }
    } finally {
      // These fetches share one pooled IMAP connection (#679); release it as
      // soon as the run is done instead of waiting for the idle timer.
      await fetcher?.close();
      if (cached > 0) {
        unawaited(
          _appLogger?.info(
            'body_prefetch',
            'Prefetched $cached email bodies',
            data: {'count': cached},
          ),
        );
      }
    }
    return cached;
  }

  BodyFetcher _createFetcher() =>
      _fetcherFactory?.call() ??
      _RepoBodyFetcher(
        EmailRepositoryImpl(
          _db,
          _accountRepo,
          imapConnect: _imapConnect,
          appLogger: _appLogger,
        ),
      );

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
    final now = _clock();
    _failedAt.removeWhere((_, at) => now.difference(at) >= failedRetryAfter);
    final rows = await _db.customSelect(
      'SELECT e.id FROM emails e '
      'LEFT JOIN email_bodies eb ON eb.email_id = e.id '
      'WHERE eb.email_id IS NULL '
      'ORDER BY e.received_at DESC, e.uid DESC, e.id DESC '
      'LIMIT ?',
      variables: [Variable.withInt(_batchSize + _failedAt.length)],
    ).get();
    return rows
        .map((r) => r.read<String>('id'))
        .where((id) => !_failedAt.containsKey(id))
        .take(_batchSize)
        .toList();
  }
}
