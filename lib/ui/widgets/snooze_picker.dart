import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SnoozePicker extends StatelessWidget {
  const SnoozePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 8);
    final thisEvening = DateTime(now.year, now.month, now.day, 18);
    final nextWeek = now.add(const Duration(days: 7));

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
          trailing: Text(DateFormat('MMM d, 08:00').format(nextWeek)),
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

            final time = await showTimePicker(
              context: context,
              initialTime: const TimeOfDay(hour: 8, minute: 0),
            );
            if (time == null) return;

            if (context.mounted) {
              final chosen = DateTime(
                date.year,
                date.month,
                date.day,
                time.hour,
                time.minute,
              );
              Navigator.pop(context, chosen);
            }
          },
        ),
      ],
    );
  }
}
