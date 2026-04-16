import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/account.dart';
import '../../core/models/email.dart';
import '../../di.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.accountId,
    this.replyToEmailId,
    this.prefillTo,
    this.prefillCc,
    this.prefillSubject,
    this.prefillBody,
  });

  final String? accountId;
  final String? replyToEmailId;
  final String? prefillTo;
  final String? prefillCc;
  final String? prefillSubject;
  final String? prefillBody;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  String? _accountId;
  List<Account> _accounts = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefillTo != null) _to.text = widget.prefillTo!;
    if (widget.prefillCc != null) _cc.text = widget.prefillCc!;
    if (widget.prefillSubject != null) _subject.text = widget.prefillSubject!;
    if (widget.prefillBody != null) _body.text = widget.prefillBody!;
    _accountId = widget.accountId;
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      // Auto-select the first account when none was pre-selected.
      _accountId ??= accounts.isNotEmpty ? accounts.first.id : null;
    });
  }

  @override
  void dispose() {
    for (final c in [_to, _cc, _subject, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    if (_accountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select an account first')),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      final account =
          (await ref.read(accountRepositoryProvider).getAccount(_accountId!))!;
      final draft = EmailDraft(
        from: EmailAddress(name: account.displayName, email: account.email),
        to: _to.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map((e) => EmailAddress(email: e))
            .toList(),
        cc: _cc.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map((e) => EmailAddress(email: e))
            .toList(),
        subject: _subject.text,
        body: _body.text,
      );
      await ref.read(emailRepositoryProvider).sendEmail(_accountId!, draft);
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Send failed: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compose'),
        actions: [
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_accounts.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DropdownButtonFormField<String>(
                initialValue: _accountId,
                decoration: const InputDecoration(
                  labelText: 'From',
                  border: OutlineInputBorder(),
                ),
                items: _accounts
                    .map(
                      (a) => DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.displayName} <${a.email}>'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            )
          else if (_accounts.length == 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'From',
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  '${_accounts.first.displayName} <${_accounts.first.email}>',
                ),
              ),
            ),
          _field(_to, 'To', keyboardType: TextInputType.emailAddress),
          _field(_cc, 'Cc', keyboardType: TextInputType.emailAddress),
          _field(_subject, 'Subject'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _body,
            maxLines: null,
            minLines: 10,
            decoration: const InputDecoration(
              labelText: 'Body',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
