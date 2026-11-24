import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/study_queue.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/card_repository.dart';
import 'package:sharedinbox/core/repositories/review_repository.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/entries_screen.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/entry_markdown.dart';
import 'package:sharedinbox/ui/widgets/new_card_dialog.dart';

/// Showing the next card after a rating should take less than this
/// (ENCRYPTED-OBJECTS.md §10); a debug build warns in the app log.
const _nextCardBudgetMs = 50;

/// Studies deck [deckId] (ENCRYPTED-OBJECTS.md §9, #1381): the front, "Show
/// answer" (Space), then Again / Hard / Good / Easy (1–4), each with the
/// interval it gives. A rating moves to the next card at once and is stored
/// locally ([ReviewRepository.rate], offline); Undo (U, Ctrl+Z) takes back
/// the ratings of this session, last first.
class StudyScreen extends ConsumerStatefulWidget {
  const StudyScreen({
    super.key,
    required this.accountId,
    required this.deckId,
  });

  final String accountId;
  final String deckId;

  @override
  ConsumerState<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends ConsumerState<StudyScreen> {
  late final CardRepository _cards;
  late final ReviewRepository _reviews;
  final _subs = <StreamSubscription<Object?>>[];

  /// The ratings of this session not taken back, oldest first; parallel to
  /// the undo steps of [_queue].
  final _rated = <Future<ReviewEvent>>[];
  StudyQueue? _queue;
  Fsrs? _fsrs;
  Map<String, FlashCard>? _content;
  bool _dueLoaded = false;
  bool _newLoaded = false;
  bool _revealed = false;

  /// The card shown and since when, for the duration of its review.
  String? _shownCard;
  int _shownAtMs = 0;
  Object? _error;
  Timer? _wake;

  int _now() => ref.read(todayProvider)().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _cards = ref.read(cardRepositoryProvider);
    _reviews = ref.read(reviewRepositoryProvider);
    unawaited(_start());
  }

  Future<void> _start() async {
    final accountId = widget.accountId;
    final deckId = widget.deckId;
    try {
      final params = await _reviews.deckParams(accountId, deckId);
      final newLeft = await _reviews.newLeftToday(accountId, deckId);
      if (!mounted) return;
      _fsrs = Fsrs(params: params);
      final queue = _queue = StudyQueue(newLeft: newLeft);
      // Reviews are due at the start of a study day and learning cards
      // within the session: what is due within the hour is enough.
      final horizon = _now() + const Duration(hours: 1).inMilliseconds;
      _subs
        ..add(
          _cards.observeCards(accountId, deckId).listen(
                (cards) => setState(() {
                  _content = {for (final c in cards) c.cardId: c};
                  queue.setLive(_content!.keys.toSet());
                }),
                onError: _failed,
              ),
        )
        ..add(
          _reviews.observeDue(accountId, deckId, horizon).listen(
                (due) => setState(() {
                  queue.mergeDue(due);
                  _dueLoaded = true;
                }),
                onError: _failed,
              ),
        )
        ..add(
          _reviews.observeNew(accountId, deckId).listen(
                (ids) => setState(() {
                  queue.mergeNew(ids);
                  _newLoaded = true;
                }),
                onError: _failed,
              ),
        );
    } catch (e) {
      _failed(e);
    }
  }

  void _failed(Object e) {
    if (!mounted) return;
    setState(() => _error = e);
  }

  @override
  void dispose() {
    _wake?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _reviews.endSession(widget.accountId);
    super.dispose();
  }

  bool get _ready =>
      _queue != null && _content != null && _dueLoaded && _newLoaded;

  void _reveal() {
    if (!_ready || _revealed || _queue!.current(_now()) == null) return;
    setState(() => _revealed = true);
  }

  /// The schedule [rating] gives the current card at [nowMs]. Replay seeds
  /// the fuzz of a review by its `h`, which is not known yet; the session
  /// only needs the learning steps, which have no fuzz.
  CardSchedule _preview(String cardId, Rating rating, int nowMs) =>
      _fsrs!.review(
        _queue!.scheduleOf(cardId) ?? CardSchedule.initial,
        rating,
        nowMs,
      );

  void _rate(Rating rating) {
    final queue = _queue;
    if (!_ready || !_revealed || queue == null) return;
    final nowMs = _now();
    final cardId = queue.current(nowMs);
    if (cardId == null) return;
    final timing = kDebugMode ? (Stopwatch()..start()) : null;
    final durationMs = nowMs - _shownAtMs;
    setState(() {
      queue.rated(cardId, _preview(cardId, rating, nowMs));
      _revealed = false;
      _shownCard = null;
    });
    if (timing != null) _logNextCard(timing);
    final event = _reviews.rate(
      widget.accountId,
      cardId,
      rating,
      durationMs: durationMs,
    );
    _rated.add(event);
    unawaited(
      event.then<void>((_) {}, onError: (Object e) => _rateFailed(event, e)),
    );
  }

  /// The rating was not stored: the card comes back if it was the last one.
  /// An older one stays in the undo stack; its undo has nothing to cancel.
  void _rateFailed(Future<ReviewEvent> event, Object e) {
    if (!mounted) return;
    context.showAppSnackBar(
      'Could not save the rating: ${userErrorMessage(e)}',
      level: AppLogLevel.warn,
      event: 'study.rate_failed',
      accountId: widget.accountId,
    );
    if (_rated.lastOrNull != event) return;
    _rated.removeLast().ignore();
    setState(() {
      _queue!.undo();
      _revealed = false;
      _shownCard = null;
    });
  }

  Future<void> _undo() async {
    final queue = _queue;
    if (queue == null || _rated.isEmpty) return;
    final event = _rated.removeLast();
    setState(() {
      queue.undo();
      _revealed = false;
      _shownCard = null;
    });
    final ReviewEvent rated;
    try {
      rated = await event;
    } catch (_) {
      return;
    }
    try {
      await _reviews.undo(
        widget.accountId,
        deviceId: rated.deviceId,
        seq: rated.seq,
      );
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Could not undo: ${userErrorMessage(e)}',
        level: AppLogLevel.warn,
        event: 'study.undo_failed',
        accountId: widget.accountId,
      );
    }
  }

  /// Debug builds: how long from the tap until the next card's frame.
  void _logNextCard(Stopwatch timing) {
    final logger = ref.read(appLoggerProvider);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      timing.stop();
      final ms = timing.elapsedMilliseconds;
      final slow = ms > _nextCardBudgetMs;
      unawaited(
        logger.log(
          level: slow ? AppLogLevel.warn : AppLogLevel.debug,
          event: 'study.next_card',
          message: slow
              ? 'The next card took ${ms}ms (budget ${_nextCardBudgetMs}ms)'
              : 'The next card took ${ms}ms',
          accountId: widget.accountId,
          data: {'ms': ms},
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final decks = ref.watch(decksProvider(widget.accountId)).value;
    final name =
        decks?.where((d) => d.deckId == widget.deckId).firstOrNull?.name;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _reveal,
        const SingleActivator(LogicalKeyboardKey.digit1): () =>
            _rate(Rating.again),
        const SingleActivator(LogicalKeyboardKey.digit2): () =>
            _rate(Rating.hard),
        const SingleActivator(LogicalKeyboardKey.digit3): () =>
            _rate(Rating.good),
        const SingleActivator(LogicalKeyboardKey.digit4): () =>
            _rate(Rating.easy),
        const SingleActivator(LogicalKeyboardKey.keyU): () =>
            unawaited(_undo()),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            unawaited(_undo()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(name ?? 'Study'),
            actions: [
              IconButton(
                key: const Key('studyUndo'),
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: _rated.isEmpty ? null : () => unawaited(_undo()),
              ),
            ],
          ),
          body: PersonalDataGate(
            accountId: widget.accountId,
            child: _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(child: Text('Error: ${userErrorMessage(error)}'));
    }
    final queue = _queue;
    if (!_ready || queue == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_content!.isEmpty) return _empty(context);
    final nowMs = _now();
    final cardId = queue.current(nowMs);
    final card = cardId == null ? null : _content![cardId];
    if (cardId == null || card == null) return _done(context, queue, nowMs);
    _wake?.cancel();
    if (cardId != _shownCard) {
      _shownCard = cardId;
      _shownAtMs = nowMs;
    }
    final counts = queue.counts(nowMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Text(
            '${counts.newCards} new · ${counts.learning} learning · '
            '${counts.due} due',
            key: const Key('studyCounts'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('studyCard_$cardId'),
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyedSubtree(
                  key: const Key('studyFront'),
                  child: EntryMarkdown(body: card.front),
                ),
                if (_revealed) ...[
                  const Divider(height: AppSpacing.xl),
                  KeyedSubtree(
                    key: const Key('studyBack'),
                    child: EntryMarkdown(body: card.back),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _revealed
              ? _ratingButtons(cardId, nowMs)
              : FilledButton(
                  key: const Key('studyReveal'),
                  onPressed: _reveal,
                  child: const Text('Show answer'),
                ),
        ),
      ],
    );
  }

  Widget _ratingButtons(String cardId, int nowMs) {
    const labels = {
      Rating.again: 'Again',
      Rating.hard: 'Hard',
      Rating.good: 'Good',
      Rating.easy: 'Easy',
    };
    return Row(
      children: [
        for (final MapEntry(key: rating, value: label) in labels.entries)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: FilledButton.tonal(
                key: Key('studyRate_${rating.name}'),
                onPressed: () => _rate(rating),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label),
                    Text(
                      intervalLabel(
                        _fsrs!,
                        _preview(cardId, rating, nowMs),
                        nowMs,
                      ),
                      key: Key('studyInterval_${rating.name}'),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A deck without cards: says so, instead of "All done for now", and
  /// offers to add one.
  Widget _empty(BuildContext context) {
    return Center(
      key: const Key('studyEmpty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No cards in this deck yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            key: const Key('studyAddCard'),
            icon: const Icon(Icons.add),
            label: const Text('Add card'),
            onPressed: () => unawaited(
              addCardWithDialog(
                context,
                ref,
                accountId: widget.accountId,
                deckId: widget.deckId,
                offerStudy: false,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Nothing left to study now; wakes up when the next learning card is
  /// within the learn-ahead window.
  Widget _done(BuildContext context, StudyQueue queue, int nowMs) {
    final next = queue.nextLearningDue();
    _wake?.cancel();
    final wait = next == null ? 0 : next - learnAhead.inMilliseconds - nowMs;
    if (wait > 0) {
      _wake = Timer(Duration(milliseconds: wait), () {
        if (mounted) setState(() {});
      });
    }
    return Center(
      key: const Key('studyDone'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'All done for now',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (next != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Next learning card at '
              '${DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(next))}',
              key: const Key('studyNextLearning'),
            ),
          ],
        ],
      ),
    );
  }
}
