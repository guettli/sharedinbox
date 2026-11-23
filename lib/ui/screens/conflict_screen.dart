import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/encrypted_objects/conflict_presenter.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/text_diff.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/entries_screen.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/text_diff_view.dart';

/// Width from which the versions show in two columns.
const _twoColumnWidth = 600.0;

/// The versions of one encrypted object in conflict, any kind (#1374): one
/// card per distinct version, each with a diff against the newest. "Keep
/// this" resolves with that version, "Keep both" also copies every other
/// version that is not a deletion into a new item.
class ConflictScreen extends ConsumerStatefulWidget {
  const ConflictScreen({
    super.key,
    required this.accountId,
    required this.itemHmac,
  });

  final String accountId;
  final String itemHmac;

  @override
  ConsumerState<ConflictScreen> createState() => _ConflictScreenState();
}

class _ConflictScreenState extends ConsumerState<ConflictScreen> {
  String? _ownDevice;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevice());
  }

  Future<void> _loadDevice() async {
    final clock =
        await ref.read(mailObjectStoreProvider).clockFor(widget.accountId);
    if (!mounted) return;
    setState(() => _ownDevice = clock.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resolve conflict')),
      body: PersonalDataGate(accountId: widget.accountId, child: _body()),
    );
  }

  Widget _body() {
    final item =
        ref.watch(conflictItemProvider((widget.accountId, widget.itemHmac)));
    return item.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: ${userErrorMessage(e)}')),
      data: (it) {
        if (it == null || it.merge.state != MergeState.conflict) {
          return const Center(
            child: Text('Already resolved.', key: Key('conflictResolved')),
          );
        }
        return _versions(it);
      },
    );
  }

  Widget _versions(MailObjectItem item) {
    final heads = item.merge.distinctHeads;
    final newest =
        heads.indexWhere((h) => h.versionId == item.merge.display!.versionId);
    final presenter = presenterFor(item.display.head.kind);
    final newestText = presenter.diffText(item.versions[newest]);
    final live = item.versions.where((v) => !v.head.deleted).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = constraints.maxWidth - 2 * AppSpacing.lg;
        final width = constraints.maxWidth >= _twoColumnWidth
            ? (inner - AppSpacing.lg) / 2
            : inner;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.lg,
            children: [
              for (var i = 0; i < heads.length; i++)
                SizedBox(
                  width: width,
                  child: _VersionCard(
                    index: i,
                    version: item.versions[i],
                    device: _deviceLabel(heads[i].versionId),
                    isNewest: i == newest,
                    text: presenter.diffText(item.versions[i]),
                    diff: i == newest ||
                            item.versions[i].head.deleted ||
                            item.versions[newest].head.deleted
                        ? null
                        : computeContextDiff(
                            newestText,
                            presenter.diffText(item.versions[i]),
                          ),
                    keepAllCount: item.versions[i].head.deleted ? 0 : live,
                    busy: _busy,
                    onKeep: () => _keep(heads[i].versionId),
                    onKeepAll: () => _keepAll(heads[i].versionId),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _deviceLabel(Hlc version) {
    final device = version.deviceId;
    if (device == _ownDevice) return 'This device';
    return 'Device ${device.length > 6 ? device.substring(0, 6) : device}';
  }

  Future<void> _keep(Hlc version) => _run(
        (store) => store.resolve(
          widget.accountId,
          widget.itemHmac,
          keep: version,
        ),
        'Conflict resolved.',
      );

  Future<void> _keepAll(Hlc version) => _run(
        (store) => store.keepAll(
          widget.accountId,
          widget.itemHmac,
          keep: version,
        ),
        'Conflict resolved; the other versions are kept as new items.',
      );

  Future<void> _run(
    Future<Object?> Function(MailObjectStore store) action,
    String done,
  ) async {
    setState(() => _busy = true);
    final messenger = context.appMessenger();
    try {
      await action(ref.read(mailObjectStoreProvider));
    } on ConflictChangedException {
      // Another device resolved it, or a sync brought a new version.
      if (!mounted) return;
      setState(() => _busy = false);
      ref.invalidate(
        conflictItemProvider((widget.accountId, widget.itemHmac)),
      );
      messenger.show('The versions changed meanwhile; showing them again.');
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.show(
        'Could not resolve: ${userErrorMessage(e)}',
        level: AppLogLevel.warn,
      );
      return;
    }
    if (!mounted) return;
    context.pop();
    messenger.show(done);
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.index,
    required this.version,
    required this.device,
    required this.isNewest,
    required this.text,
    required this.diff,
    required this.keepAllCount,
    required this.busy,
    required this.onKeep,
    required this.onKeepAll,
  });

  final int index;
  final InnerObject version;
  final String device;
  final bool isNewest;
  final String text;

  /// Against the newest version; null for the newest and a deletion.
  final List<DiffLine>? diff;

  /// The live versions "Keep both" keeps; 0 for a deletion.
  final int keepAllCount;
  final bool busy;
  final VoidCallback onKeep;
  final VoidCallback onKeepAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = version.head;
    final time = DateFormat.yMMMd().add_Hm().format(
          DateTime.fromMillisecondsSinceEpoch(
            head.versionId.wallMs,
            isUtc: true,
          ).toLocal(),
        );
    final diff = this.diff;
    return Card(
      key: Key('conflictVersion_$index'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$device · $time',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (isNewest)
                  Chip(
                    key: Key('conflictNewest_$index'),
                    label: const Text('Newest'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (head.deleted)
              Text(
                'Deleted',
                key: Key('conflictDeleted_$index'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              SelectableText(text),
            if (diff != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Changes against the newest version',
                style: theme.textTheme.labelMedium,
              ),
              TextDiffView(
                key: Key('conflictDiff_$index'),
                lines: diff,
                emptyText: '(differs only in whitespace or hidden fields)',
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                FilledButton(
                  key: Key('conflictKeep_$index'),
                  onPressed: busy ? null : onKeep,
                  child: Text(head.deleted ? 'Keep deleted' : 'Keep this'),
                ),
                if (keepAllCount > 1)
                  OutlinedButton(
                    key: Key('conflictKeepAll_$index'),
                    onPressed: busy ? null : onKeepAll,
                    child: Text(
                      keepAllCount > 2
                          ? 'Keep all ($keepAllCount)'
                          : 'Keep both',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
