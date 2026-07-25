import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/services/unified_push_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// User-facing screen for configuring [UnifiedPush] real-time notifications.
///
/// Picks a distributor (the app provider used to deliver pushes — e.g. ntfy,
/// NextPush) and shows the resulting endpoint URL, which the user copies to
/// their relay server so it can wake the device when new mail arrives.
class PushSettingsScreen extends ConsumerStatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  ConsumerState<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends ConsumerState<PushSettingsScreen> {
  late final UnifiedPushService _service;
  List<String> _distributors = const [];
  String? _selected;
  String? _endpoint;
  String? _error;
  StreamSubscription<UnifiedPushStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    _service = ref.read(unifiedPushServiceProvider);
    _endpoint = _service.endpoint;
    _error = _service.lastError;
    _statusSub = _service.watch().listen((status) {
      if (!mounted) return;
      setState(() {
        _endpoint = status.endpoint;
        _error = status.error;
      });
    });
    unawaited(_refreshDistributors());
  }

  @override
  void dispose() {
    unawaited(_statusSub?.cancel());
    super.dispose();
  }

  Future<void> _refreshDistributors() async {
    final distributors = await _service.getDistributors();
    final current = await _service.getDistributor();
    if (!mounted) return;
    setState(() {
      _distributors = distributors;
      _selected = current;
    });
  }

  Future<void> _pick(String distributor) async {
    await _service.pickDistributor(distributor);
    await _refreshDistributors();
  }

  Future<void> _unregister() async {
    await _service.unregister();
    await _refreshDistributors();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UnifiedPush')),
      body: ListView(
        children: [
          if (!_service.isSupported)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Not supported on this platform'),
              subtitle: Text(
                'UnifiedPush is currently wired up for Android only.',
              ),
            )
          else ...[
            ListTile(
              title: Text(
                'Distributor',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'The app on your device that delivers push messages. Install '
                'one (for example ntfy or NextPush) before choosing it here.',
              ),
            ),
            if (_distributors.isEmpty)
              const ListTile(
                leading: Icon(Icons.warning_amber_outlined),
                title: Text('No distributor installed'),
                subtitle: Text(
                  'Install a UnifiedPush distributor app from F-Droid or the '
                  'Play Store, then return to this screen.',
                ),
              )
            else
              RadioGroup<String>(
                groupValue: _selected,
                onChanged: (value) {
                  if (value != null) unawaited(_pick(value));
                },
                child: Column(
                  children: [
                    for (final d in _distributors)
                      RadioListTile<String>(
                        title: Text(d),
                        value: d,
                      ),
                  ],
                ),
              ),
            const Divider(),
            ListTile(
              title: Text(
                'Endpoint',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                _endpoint ??
                    'No endpoint yet — pick a distributor above and wait a '
                        'few seconds for it to register.',
              ),
              trailing: _endpoint == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy endpoint URL',
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _endpoint!),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Endpoint copied')),
                        );
                      },
                    ),
            ),
            if (_error != null)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
              ),
            const Divider(),
            if (_selected != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Unregister'),
                  onPressed: _unregister,
                ),
              ),
            const SizedBox(height: AppSpacing.xl),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                'Once you have an endpoint URL, paste it into your relay '
                'server configuration. The relay watches your IMAP mailbox '
                'and POSTs to this URL whenever new mail arrives, waking '
                'this app for an immediate sync.',
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ],
      ),
    );
  }
}
