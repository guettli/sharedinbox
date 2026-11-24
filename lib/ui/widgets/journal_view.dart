import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/journal_days.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/entry_tile.dart';

/// The journal (entries with a `date`) of one account, one day at a time
/// (#1358): a day back or forward, a jump to the previous or next day with
/// entries, a calendar and back to today. "New entry" writes an entry for
/// the day shown and opens it; if it is still blank when the user comes
/// back, it is deleted again.
class JournalView extends ConsumerStatefulWidget {
  const JournalView({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<JournalView> createState() => _JournalViewState();
}

class _JournalViewState extends ConsumerState<JournalView> {
  /// The day shown; null: today.
  DateTime? _selected;
  bool _busy = false;

  DateTime get _today {
    final now = ref.read(todayProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _day => _selected ?? _today;

  void _show(DateTime day) =>
      setState(() => _selected = DateTime(day.year, day.month, day.day));

  @override
  Widget build(BuildContext context) {
    final journal = ref.watch(journalProvider(widget.accountId));
    final days = groupJournal(journal.value ?? const []);
    final date = isoDate(_day);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('journalNewEntry'),
        onPressed: _busy ? null : () => _add(date),
        icon: const Icon(Icons.add),
        label: const Text('New entry'),
      ),
      body: Column(
        children: [
          _header(days, date),
          Expanded(
            child: journal.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Error: ${userErrorMessage(e)}')),
              data: (_) => _list(days, date),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(List<JournalDay> days, String date) {
    final previous = previousDayWithEntries(days, date);
    final next = nextDayWithEntries(days, date);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          IconButton(
            key: const Key('journalPrevFilled'),
            tooltip: 'Previous day with entries',
            icon: const Icon(Icons.keyboard_double_arrow_left),
            onPressed: previous == null
                ? null
                : () => _show(parseJournalDate(previous)!),
          ),
          IconButton(
            key: const Key('journalPrevDay'),
            tooltip: 'Previous day',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _show(_day.copyWith(day: _day.day - 1)),
          ),
          Expanded(
            child: Text(
              DateFormat.yMMMEd().format(_day),
              key: const Key('journalDay'),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const Key('journalNextDay'),
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _show(_day.copyWith(day: _day.day + 1)),
          ),
          IconButton(
            key: const Key('journalNextFilled'),
            tooltip: 'Next day with entries',
            icon: const Icon(Icons.keyboard_double_arrow_right),
            onPressed:
                next == null ? null : () => _show(parseJournalDate(next)!),
          ),
          IconButton(
            key: const Key('journalPickDay'),
            tooltip: 'Pick a day',
            icon: const Icon(Icons.calendar_month),
            onPressed: _pick,
          ),
          if (date != isoDate(_today))
            IconButton(
              key: const Key('journalToday'),
              tooltip: 'Today',
              icon: const Icon(Icons.today),
              onPressed: () => setState(() => _selected = null),
            ),
        ],
      ),
    );
  }

  Widget _list(List<JournalDay> days, String date) {
    final entries =
        days.where((d) => d.date == date).firstOrNull?.entries ?? const [];
    if (entries.isEmpty) {
      return const Center(child: Text('No entries for this day.'));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (_, i) => EntryTile(
        entry: entries[i],
        onTap: () => context.push(
          '/accounts/${widget.accountId}/entries/${entries[i].itemId}',
        ),
        onResolve: () => context.push(
          '/accounts/${widget.accountId}/conflicts/${entries[i].itemHmac}',
        ),
      ),
    );
  }

  Future<void> _pick() async {
    final day = _day;
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(min(day.year, today.year - 100)),
      lastDate: DateTime(max(day.year, today.year + 100), 12, 31),
    );
    if (picked == null || !mounted) return;
    _show(picked);
  }

  /// Writes an empty entry for [date] and opens it. Deletes it again if
  /// the user comes back without having put anything in it.
  Future<void> _add(String date) async {
    setState(() => _busy = true);
    try {
      final entry = await ref
          .read(entryRepositoryProvider)
          .create(widget.accountId, body: '', date: date);
      if (!mounted) return;
      await context
          .push('/accounts/${widget.accountId}/entries/${entry.itemId}');
      await _deleteIfBlank(entry.itemId);
    } on NoWriteKeyException {
      if (!mounted) return;
      context.showAppSnackBar('Unlock personal data to add entries.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Deletes entry [itemId] if it is still blank. A failure (e.g. locked
  /// meanwhile) only leaves the blank entry behind, so it is logged, not
  /// shown.
  Future<void> _deleteIfBlank(String itemId) async {
    final repo = ref.read(entryRepositoryProvider);
    try {
      final entry = await repo.entry(widget.accountId, itemId);
      if (entry == null || !entry.isBlank || entry.hasConflict) return;
      await repo.delete(widget.accountId, itemId);
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).warn(
              'journal.blank_entry.delete_failed',
              'Could not delete a blank new journal entry',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
    }
  }
}
