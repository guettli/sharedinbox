import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

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
  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  String? _accountId;
  List<Account> _accounts = [];
  bool _sending = false;
  final List<_AttachmentInfo> _attachments = [];
  bool _opening = false;

  int? _draftId;
  bool _draftDirty = false;
  Timer? _saveTimer;
  bool _draftSaved = false; // drives the "Saved" badge
  // Captured in initState so it remains accessible in dispose() after ref is gone.
  late final DraftRepository _draftRepo;

  static const _saveDelay = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _draftRepo = ref.read(draftRepositoryProvider);
    if (widget.prefillTo != null) _to.text = widget.prefillTo!;
    if (widget.prefillCc != null) _cc.text = widget.prefillCc!;
    if (widget.prefillSubject != null) _subject.text = widget.prefillSubject!;
    if (widget.prefillBody != null) _body.text = widget.prefillBody!;
    _accountId = widget.accountId;
    unawaited(_loadAccounts());
    // Only restore if no prefill fields were provided (avoids overwriting a
    // fresh reply with an old draft from a previous reply to the same email).
    final hasPrefill = widget.prefillTo != null ||
        widget.prefillSubject != null ||
        widget.prefillBody != null;
    if (!hasPrefill) unawaited(_restoreDraft());

    for (final c in [_to, _cc, _subject, _body]) {
      c.addListener(_onTextChanged);
    }
  }

  Future<void> _loadAccounts() async {
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _accountId ??= accounts.isNotEmpty ? accounts.first.id : null;
    });
  }

  Future<void> _restoreDraft() async {
    final draft = await ref
        .read(draftRepositoryProvider)
        .findDraft(replyToEmailId: widget.replyToEmailId);
    if (draft == null || !mounted) return;
    setState(() {
      _draftId = draft.id;
      _to.text = draft.toText;
      _cc.text = draft.ccText;
      _subject.text = draft.subjectText;
      _body.text = draft.bodyText;
      if (draft.accountId != null) _accountId = draft.accountId;
    });
  }

  void _onTextChanged() {
    _draftDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _autoSave);
  }

  Future<void> _autoSave() async {
    if (!_draftDirty || !mounted) return;
    _draftDirty = false;
    final saved = await _draftRepo.saveDraft(
      id: _draftId,
      accountId: _accountId,
      replyToEmailId: widget.replyToEmailId,
      toText: _to.text,
      ccText: _cc.text,
      subjectText: _subject.text,
      bodyText: _body.text,
    );
    if (!mounted) return;
    setState(() {
      _draftId = saved.id;
      _draftSaved = true;
    });
    // Hide the indicator after 2 seconds.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _draftSaved = false);
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final c in [_to, _cc, _subject, _body]) {
      c.removeListener(_onTextChanged);
      c.dispose();
    }
    _toFocus.dispose();
    _ccFocus.dispose();
    // Flush any pending save synchronously — we can't await in dispose, but
    // scheduling a microtask still runs before the isolate exits.
    if (_draftDirty) {
      unawaited(
        _draftRepo.saveDraft(
          id: _draftId,
          accountId: _accountId,
          replyToEmailId: widget.replyToEmailId,
          toText: _to.text,
          ccText: _cc.text,
          subjectText: _subject.text,
          bodyText: _body.text,
        ),
      );
    }
    super.dispose();
  }

  Future<void> _pickAttachments() async {
    final result = await FilePicker.pickFiles();
    if (result == null) return;
    final files = result.files.where((f) => f.path != null).toList();
    if (!mounted) return;
    final newAttachments = <_AttachmentInfo>[];
    for (final file in files) {
      final path = file.path!;
      final stat = await File(path).stat();
      newAttachments.add(
        _AttachmentInfo(
          path: path,
          filename: file.name,
          size: stat.size,
          contentType: _guessMimeType(file.name),
        ),
      );
    }
    setState(() => _attachments.addAll(newAttachments));
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  Future<void> _openAttachment(int index) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final path = _attachments[index].path;
      await OpenFilex.open(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('Failed to open file: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _guessMimeType(String filename) {
    return lookupMimeType(filename) ?? 'application/octet-stream';
  }

  Future<void> _send() async {
    if (_accountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('Select an account first'),
        ),
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
        attachmentFilePaths: List.unmodifiable(
          _attachments.map((a) => a.path).toList(),
        ),
      );
      await ref.read(emailRepositoryProvider).sendEmail(_accountId!, draft);
      // Delete the draft only after a successful send.
      if (_draftId != null) {
        await _draftRepo.deleteDraft(_draftId!);
      }
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('Send failed: $e'),
        ),
      );
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
          if (_draftSaved)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Center(
                child: Text(
                  'Saved',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: 'Add attachment',
            onPressed: _sending ? null : _pickAttachments,
          ),
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
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (_accounts.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
          _addressField(_to, _toFocus, 'To'),
          _addressField(_cc, _ccFocus, 'Cc'),
          _field(_subject, 'Subject'),
          const SizedBox(height: AppSpacing.sm),
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
          if (_attachments.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                'Attachments',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (var i = 0; i < _attachments.length; i++)
              ListTile(
                dense: true,
                leading: const Icon(Icons.attach_file),
                title: Text(_attachments[i].filename),
                subtitle: Text(
                  '${_attachments[i].contentType} • ${fmtSize(_attachments[i].size)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility),
                      tooltip: 'Open',
                      onPressed: () => _openAttachment(i),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove',
                      onPressed: () => _removeAttachment(i),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _addressField(
    TextEditingController ctrl,
    FocusNode focusNode,
    String label,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: RawAutocomplete<EmailAddress>(
        textEditingController: ctrl,
        focusNode: focusNode,
        displayStringForOption: (option) {
          final text = ctrl.text;
          final lastComma = text.lastIndexOf(',');
          final prefix =
              lastComma >= 0 ? '${text.substring(0, lastComma + 1)} ' : '';
          return '$prefix${option.email}, ';
        },
        optionsBuilder: (value) async {
          final text = value.text;
          final lastComma = text.lastIndexOf(',');
          final token = lastComma >= 0
              ? text.substring(lastComma + 1).trim()
              : text.trim();
          if (token.length < 2) return const [];
          final results = await ref
              .read(emailRepositoryProvider)
              .searchAddresses(null, token);
          // Guard: if focus left the field while the query was running,
          // return empty so RawAutocomplete doesn't call show() after hide()
          // has already been called — that races into an assertion in overlay.dart.
          if (!focusNode.hasFocus) return const [];
          return results;
        },
        fieldViewBuilder: (ctx, fieldCtrl, fieldFocusNode, onFieldSubmitted) {
          return TextFormField(
            controller: fieldCtrl,
            focusNode: fieldFocusNode,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            onFieldSubmitted: (_) => onFieldSubmitted(),
          );
        },
        optionsViewBuilder: (ctx, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final option = options.elementAt(i);
                    return InkWell(
                      onTap: () => onSelected(option),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                          vertical: AppSpacing.sm,
                        ),
                        child: option.name != null
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(option.name!),
                                  Text(
                                    option.email,
                                    style: Theme.of(ctx).textTheme.bodySmall,
                                  ),
                                ],
                              )
                            : Text(option.email),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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

class _AttachmentInfo {
  final String path;
  final String filename;
  final int size;
  final String contentType;

  _AttachmentInfo({
    required this.path,
    required this.filename,
    required this.size,
    required this.contentType,
  });
}

// Helper to silence the unawaited_futures lint on fire-and-forget futures.
void unawaited(Future<void> _) {}
