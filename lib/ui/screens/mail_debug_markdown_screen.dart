import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// Shows a single message's debug snapshot rendered as copy-pasteable markdown
/// so the user can drop it straight into a bug report. Reached from the mail
/// detail overflow menu ("Debug Mail"). Local state renders immediately;
/// "Check remote" fetches the server's view and folds a local-vs-remote diff
/// into the markdown.
class MailDebugMarkdownScreen extends ConsumerStatefulWidget {
  const MailDebugMarkdownScreen({super.key, required this.messageRef});

  final DebugMessageRef messageRef;

  @override
  ConsumerState<MailDebugMarkdownScreen> createState() =>
      _MailDebugMarkdownScreenState();
}

class _MailDebugMarkdownScreenState
    extends ConsumerState<MailDebugMarkdownScreen> {
  ProbeResult? _probe;
  bool _fetchingProbe = false;

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(
      messageDebugSnapshotProvider(widget.messageRef),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Mail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy markdown',
            onPressed: snapshotAsync.hasValue
                ? () => _copy(buildMessageDebugMarkdown(
                      snapshotAsync.value!,
                      probe: _probe,
                    ))
                : null,
          ),
        ],
      ),
      body: snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load: $e')),
        data: (snapshot) => _buildBody(context, snapshot),
      ),
    );
  }

  Widget _buildBody(BuildContext context, MessageDebugSnapshot snapshot) {
    final markdown = buildMessageDebugMarkdown(snapshot, probe: _probe);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy markdown'),
              onPressed: () => _copy(markdown),
            ),
            OutlinedButton.icon(
              icon: _fetchingProbe
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync),
              label: const Text('Check remote'),
              onPressed:
                  _fetchingProbe || snapshot.email == null ? null : _runProbe,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: SelectableText(
              markdown,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copy(String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    context.showAppSnackBar(
      'Debug markdown copied to clipboard',
      event: 'mail_debug.copied',
      emailId: widget.messageRef.emailId,
      accountId: widget.messageRef.accountId,
      mailboxPath: widget.messageRef.mailboxPath,
    );
  }

  Future<void> _runProbe() async {
    if (_fetchingProbe) return;
    final email = ref
        .read(messageDebugSnapshotProvider(widget.messageRef))
        .value
        ?.email;
    if (email == null) return;
    setState(() {
      _fetchingProbe = true;
      _probe = null;
    });
    try {
      final probe = ref.read(messageProbeProvider);
      final accountRepo = ref.read(accountRepositoryProvider);
      final account = await accountRepo.getAccount(widget.messageRef.accountId);
      if (account == null) {
        if (!mounted) return;
        setState(() => _probe = const ProbeResult.error('Account not found'));
        return;
      }
      final password = await accountRepo.getPassword(account.id);
      final result = await probe.fetch(
        account: account,
        password: password,
        mailboxPath: widget.messageRef.mailboxPath,
        emailId: widget.messageRef.emailId,
        uid: email.uid,
      );
      if (!mounted) return;
      setState(() => _probe = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _probe = ProbeResult.error(e.toString()));
    } finally {
      if (mounted) setState(() => _fetchingProbe = false);
    }
  }
}
