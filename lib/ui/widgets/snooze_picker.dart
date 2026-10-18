import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SnoozePicker extends StatelessWidget {
  const SnoozePicker({super.key, this.now});

  /// Overrides the current time, for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final now = this.now ?? DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 8);
    final thisEvening = DateTime(now.year, now.month, now.day, 18);
    // Same weekday next week at 08:00, as the tile says, not the current
    // time of day. Built from fields rather than now + 7 days, which would
    // also be an hour off across a DST change.
    final nextWeek = DateTime(now.year, now.month, now.day + 7, 8);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ListTile(
          title: Text(
            'Snooze until…',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        if (now.hour < 18)
          ListTile(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: const Text('This evening'),
            trailing: Text(DateFormat('HH:mm').format(thisEvening)),
            onTap: () => Navigator.pop(context, thisEvening),
          ),
        ListTile(
          leading: const Icon(Icons.wb_twilight),
          title: const Text('Tomorrow morning'),
          trailing: Text(DateFormat('EEE, 08:00').format(tomorrow)),
          onTap: () => Navigator.pop(context, tomorrow),
        ),
        ListTile(
          leading: const Icon(Icons.next_week_outlined),
          title: const Text('Next week'),
          trailing: Text(DateFormat('EEE, MMM d, 08:00').format(nextWeek)),
          onTap: () => Navigator.pop(context, nextWeek),
        ),
        ListTile(
          leading: const Icon(Icons.calendar_month_outlined),
          title: const Text('Pick date & time…'),
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: now,
              firstDate: now,
              lastDate: now.add(const Duration(days: 365)),
            );
            if (date == null) return;
            if (!context.mounted) return;

            // Today is a valid date, so the default 08:00 can already be
            // over, and such a snooze would wake on the next sync: ask again
            // until the time is in the future or the user cancels.
            String? helpText;
            while (true) {
              final time = await showTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 8, minute: 0),
                helpText: helpText,
              );
              if (time == null || !context.mounted) return;
              final chosen = DateTime(
                date.year,
                date.month,
                date.day,
                time.hour,
                time.minute,
              );
              if (chosen.isAfter(this.now ?? DateTime.now())) {
                Navigator.pop(context, chosen);
                return;
              }
              helpText = 'That time has passed. Pick a later one';
            }
          },
        ),
      ],
    );
  }
}
