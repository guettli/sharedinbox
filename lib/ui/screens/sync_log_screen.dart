import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/di.dart';

final _timeFmt = DateFormat('MMM d, HH:mm:ss');

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class SyncLogScreen extends ConsumerStatefulWidget {
  const SyncLogScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<SyncLogScreen> createState() => _SyncLogScreenState();
}

class _SyncLogScreenState extends ConsumerState<SyncLogScreen> {
  List<SyncLogEntry> _entries = [];
  bool _syncing = false;
  int? _presynCount;
  StreamSubscription<List<SyncLogEntry>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(syncLogRepositoryProvider)
        .observeSyncLogs(widget.accountId)
        .listen((entries) {
      setState(() {
        if (_syncing &&
            _presynCount != null &&
            entries.length > _presynCount!) {
          _syncing = false;
          _presynCount = null;
        }
        _entries = entries;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _syncNow() {
    setState(() {
      _syncing = true;
      _presynCount = _entries.length;
    });
    ref.read(syncManagerProvider).syncNow(widget.accountId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync log'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sync now',
              onPressed: _syncNow,
            ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(child: Text('No sync entries yet'))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (ctx, i) => _SyncLogTile(entry: _entries[i]),
            ),
    );
  }
}

class _SyncLogTile extends StatelessWidget {
  const _SyncLogTile({required this.entry});

  final SyncLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final ms = entry.duration.inMilliseconds;
    final durationLabel =
        ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
    final proto =
        entry.protocol.isEmpty ? '' : ' · ${entry.protocol.toUpperCase()}';
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;

    return ExpansionTile(
      leading: Icon(
        entry.isOk ? Icons.check_circle : Icons.error_outline,
        color: entry.isOk ? Colors.green : errorColor,
      ),
      title: Text(
        '${_timeFmt.format(entry.startedAt)}$proto',
        style: entry.isOk ? null : TextStyle(color: errorColor),
      ),
      subtitle: Text(
        entry.isOk
            ? '${entry.emailsFetched} new · ${entry.emailsSkipped} up-to-date · took $durationLabel'
            : 'Error · took $durationLabel',
        style: TextStyle(fontSize: 12, color: entry.isOk ? null : errorColor),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('Started', _timeFmt.format(entry.startedAt)),
              _row('Finished', _timeFmt.format(entry.finishedAt)),
              _row('Duration', durationLabel),
              if (entry.protocol.isNotEmpty)
                _row('Protocol', entry.protocol.toUpperCase()),
              _row('Emails fetched', '${entry.emailsFetched}'),
              _row('Emails up-to-date', '${entry.emailsSkipped}'),
              _row('Mailboxes synced', '${entry.mailboxesSynced}'),
              _row('Pending changes flushed', '${entry.pendingFlushed}'),
              _row('Data transferred', _fmtBytes(entry.bytesTransferred)),
              if (entry.mailboxStats.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 2),
                  child: Text(
                    'Per mailbox',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                for (final m in entry.mailboxStats)
                  _row(
                    '  ${m.mailboxPath}',
                    '${m.fetched} new · ${m.skipped} up-to-date',
                  ),
              ],
              if (entry.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    entry.errorMessage!,
                    style: TextStyle(color: errorColor, fontSize: 12),
                  ),
                ),
              if (entry.protocolLog != null) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 2),
                  child: Text(
                    'Protocol log',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.protocolLog!,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 180,
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );
}
