import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// Shows a single message's debug snapshot rendered as markdown so the user can
/// eyeball it or copy it straight into a bug report. Reached from the mail
/// detail overflow menu ("Debug Mail"). Local state renders immediately; the
/// server's view is fetched automatically on open (when online) and a
/// local-vs-remote diff is folded into the document. The AppBar copy button
/// copies the raw markdown source.
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
  bool _probeStarted = false;

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(
      messageDebugSnapshotProvider(widget.messageRef),
    );

    _maybeStartProbe(snapshotAsync.value);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Mail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy markdown',
            onPressed: snapshotAsync.hasValue ? _copyCurrent : null,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_fetchingProbe) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: Markdown(
            data: markdown,
            selectable: true,
            padding: const EdgeInsets.all(AppSpacing.md),
          ),
        ),
      ],
    );
  }

  /// Kicks off the remote probe exactly once, as soon as the local snapshot is
  /// available and has a message to compare. Fetching only works while online;
  /// a failed probe surfaces as a "Remote fetch failed" line in the markdown.
  void _maybeStartProbe(MessageDebugSnapshot? snapshot) {
    if (_probeStarted || snapshot?.email == null) return;
    _probeStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runProbe());
    });
  }

  Future<void> _copyCurrent() async {
    final snapshot =
        ref.read(messageDebugSnapshotProvider(widget.messageRef)).value;
    if (snapshot == null) return;
    final markdown = buildMessageDebugMarkdown(snapshot, probe: _probe);
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
    final email =
        ref.read(messageDebugSnapshotProvider(widget.messageRef)).value?.email;
    if (email == null || _fetchingProbe) return;
    setState(() {
      _fetchingProbe = true;
      _probe = null;
    });
    final result = await _safeProbe(email.uid);
    if (!mounted) return;
    setState(() {
      _probe = result;
      _fetchingProbe = false;
    });
  }

  /// Wraps [fetchRemoteMessageSnapshot] so an unexpected throw surfaces in the
  /// markdown as a remote-fetch error rather than tearing down the screen.
  Future<ProbeResult> _safeProbe(int uid) async {
    try {
      return await fetchRemoteMessageSnapshot(ref, widget.messageRef, uid);
    } catch (e) {
      return ProbeResult.error(e.toString());
    }
  }
}
