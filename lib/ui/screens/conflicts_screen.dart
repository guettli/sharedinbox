import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/encrypted_objects/conflict_presenter.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/entries_screen.dart';

/// The encrypted objects of an account edited on several devices at once,
/// any kind (#1374). A row opens the conflict view of its item.
class ConflictsScreen extends ConsumerWidget {
  const ConflictsScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conflicts')),
      body: PersonalDataGate(accountId: accountId, child: _list(ref)),
    );
  }

  Widget _list(WidgetRef ref) {
    final conflicts = ref.watch(conflictsProvider(accountId));
    return conflicts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: ${userErrorMessage(e)}')),
      data: (list) {
        if (list.isEmpty) return const Center(child: Text('No conflicts.'));
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) => _ConflictTile(conflict: list[i]),
        );
      },
    );
  }
}

class _ConflictTile extends ConsumerWidget {
  const _ConflictTile({required this.conflict});

  final ConflictItem conflict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref
        .watch(conflictItemProvider((conflict.accountId, conflict.itemHmac)))
        .value;
    final presenter = presenterFor(conflict.kind);
    final title = item == null ? '…' : presenter.title(item.display);
    final versions = item?.versions.length;
    return ListTile(
      key: Key('conflict_${conflict.itemHmac}'),
      leading: const Icon(Icons.call_split),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          conflict.kind ?? 'object',
          if (versions != null) '$versions versions',
          'newest ${_time(conflict.displayVersionId)}',
        ].join(' · '),
      ),
      onTap: () => context.push(
        '/accounts/${conflict.accountId}/conflicts/${conflict.itemHmac}',
      ),
    );
  }

  static String _time(String versionId) {
    try {
      final hlc = Hlc.parse(versionId);
      return DateFormat.yMMMd().add_Hm().format(
            DateTime.fromMillisecondsSinceEpoch(hlc.wallMs, isUtc: true)
                .toLocal(),
          );
    } on FormatException {
      return '?';
    }
  }
}
