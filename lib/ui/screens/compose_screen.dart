import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart'
    show SendNowOutcome;
import 'package:sharedinbox/core/services/image_shrink_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/core/utils/recipient_check.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/open_file.dart';
import 'package:sharedinbox/ui/widgets/accessible_dropdown.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/shrink_image_dialog.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.accountId,
    this.replyToEmailId,
    this.prefillTo,
    this.prefillCc,
    this.prefillBcc,
    this.prefillSubject,
    this.prefillBody,
    this.draftId,
    this.attachmentPaths = const [],
    this.tempAttachmentPaths = const [],
    this.inReplyTo,
    this.references = const [],
  });

  /// Builds the screen from a `/compose` route's `extra` map. Shared by the
  /// app router and the widget-test router so the two cannot drift.
  factory ComposeScreen.fromExtra(Map<String, dynamic>? extra) => ComposeScreen(
        accountId: extra?['accountId'] as String?,
        replyToEmailId: extra?['replyToEmailId'] as String?,
        prefillTo: extra?['prefillTo'] as String?,
        prefillCc: extra?['prefillCc'] as String?,
        prefillBcc: extra?['prefillBcc'] as String?,
        prefillSubject: extra?['prefillSubject'] as String?,
        prefillBody: extra?['prefillBody'] as String?,
        draftId: extra?['draftId'] as int?,
        attachmentPaths:
            (extra?['attachmentPaths'] as List<String>?) ?? const [],
        tempAttachmentPaths:
            (extra?['tempAttachmentPaths'] as List<String>?) ?? const [],
        inReplyTo: extra?['inReplyTo'] as String?,
        references: (extra?['references'] as List<String>?) ?? const [],
      );

  final String? accountId;
  final String? replyToEmailId;
  final String? prefillTo;
  final String? prefillCc;
  final String? prefillBcc;
  final String? prefillSubject;
  final String? prefillBody;

  /// The saved draft to resume. Compose only ever restores a draft the user
  /// explicitly picked — without this it always starts blank (#1047).
  final int? draftId;

  /// Files to attach from the start: those of a queued message taken back
  /// for editing. Missing ones are skipped with a notice.
  final List<String> attachmentPaths;

  /// The subset of [attachmentPaths] the app created (shrunk copies). This
  /// screen owns them again, as if shrunk here: deleted when removed or when
  /// Compose closes without sending. The others are the user's files.
  final List<String> tempAttachmentPaths;

  /// Threading headers of a queued message taken back for editing. When
  /// [inReplyTo] is set, Send uses these as they were queued instead of
  /// re-deriving them from [replyToEmailId] (the original may not be in the
  /// local database at all).
  final String? inReplyTo;
  final List<String> references;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _bcc = TextEditingController();
  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _bccFocus = FocusNode();

  /// Whether the Bcc field is shown. Collapsed by default behind a "Bcc"
  /// button on the Cc field; opened by that button, or by a prefill or
  /// restored draft that has Bcc recipients (#1126).
  bool _showBcc = false;
  final _subject = TextEditingController();
  final _body = TextEditingController();
  String? _accountId;

  /// The message this compose answers: from the route, or from a restored
  /// reply draft, so a resumed reply is still sent as a reply.
  String? _replyToEmailId;
  List<Account> _accounts = [];
  bool _sending = false;

  /// Set once Send queued the message: the outbox now refers to the
  /// attachment files, so [dispose] must not delete the shrunk temp copies.
  bool _queued = false;

  /// Set right before Compose closes itself (Discard draft), so the
  /// lose-the-attachments question is not asked.
  bool _leaving = false;

  /// True until [ComposeScreen.attachmentPaths] are checked and attached;
  /// Send waits, so the message never goes out without them.
  late bool _loadingAttachments = widget.attachmentPaths.isNotEmpty;
  final List<_AttachmentInfo> _attachments = [];
  bool _opening = false;
  // Last shrink settings the user accepted, so re-attaching / adjusting further
  // images in this compose session starts from the same choices.
  ImageShrinkSettings _shrinkSettings = ImageShrinkSettings.defaults;

  int? _draftId;
  bool _draftDirty = false;
  Timer? _saveTimer;

  /// The auto-save currently writing, if any. Sending waits for it, so the
  /// row it creates is the one deleted rather than one that outlives the send.
  Future<void>? _autoSaveInFlight;
  bool _draftSaved = false; // drives the "Saved" badge

  // The account signature currently inserted into the body, including the
  // surrounding blank lines, so switching the "From" account swaps it cleanly
  // rather than stacking signatures (#646). Left untouched once a saved draft
  // has been restored — the draft already carries whatever body was saved.
  String _sigBlock = '';
  String? _sigAccountId;
  bool _draftRestored = false;

  // The body text as last set programmatically (prefill / signature). While
  // the body still equals it the user has not written anything yet, so the
  // cursor is parked at [_parkOffset], where the message belongs, instead of
  // after the signature or below the quote.
  String _programmaticBody = '';
  int _parkOffset = 0;
  bool _suppressAutoSave = false;
  // Captured in initState so it remains accessible in dispose() after ref is gone.
  late final DraftRepository _draftRepo;

  static const _saveDelay = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _draftRepo = ref.read(draftRepositoryProvider);
    // Before the body prefill: a reply parks the cursor at the top.
    _replyToEmailId = widget.replyToEmailId;
    if (widget.prefillTo != null) _to.text = widget.prefillTo!;
    if (widget.prefillCc != null) _cc.text = widget.prefillCc!;
    if (widget.prefillBcc != null) _bcc.text = widget.prefillBcc!;
    _showBcc = _bcc.text.trim().isNotEmpty;
    if (widget.prefillSubject != null) _subject.text = widget.prefillSubject!;
    if (widget.prefillBody != null) {
      _setPristineBody(normalizeNewlines(widget.prefillBody!));
    }
    _accountId = widget.accountId;
    unawaited(_loadAccounts());
    if (widget.draftId != null) unawaited(_restoreDraft(widget.draftId!));
    if (widget.attachmentPaths.isNotEmpty) {
      unawaited(_loadInitialAttachments(widget.attachmentPaths));
    }

    for (final c in [_to, _cc, _bcc, _subject, _body]) {
      c.addListener(_onTextChanged);
    }
  }

  Future<void> _loadAccounts() async {
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      // With more than one account, require an explicit choice (#463) rather
      // than silently defaulting to the first one — the "From" dropdown starts
      // unselected and _send blocks until the user picks. A single account is
      // still auto-selected. An account passed in (reply, restored draft)
      // keeps its value via ??=.
      _accountId ??= accounts.length == 1 ? accounts.first.id : null;
    });
    await _applySignatureForAccount(_accountId);
  }

  /// Inserts the selected account's signature into the body, swapping out any
  /// previously inserted one. A new message gets it appended
  /// (`<text>\n\n<signature>`). A reply gets it above the quoted text, after
  /// an empty first line the user types into (`\n\n<signature>\n\n<quote>`;
  /// the quote's own leading blank lines provide the separator when present).
  /// While the user has not touched the body the cursor stays parked where the
  /// message belongs ([_parkOffset]); otherwise their cursor is shifted along.
  Future<void> _applySignatureForAccount(String? accountId) async {
    // A restored draft already carries its body verbatim — never rewrite it.
    if (_draftRestored) return;
    if (accountId == _sigAccountId) return;
    final signature = accountId == null
        ? ''
        : (await ref.read(accountRepositoryProvider).getAccount(accountId))
                ?.signature ??
            '';
    if (!mounted) return;
    _sigAccountId = accountId;
    final isReply = _replyToEmailId != null;
    final text = _body.text;
    final oldIndex = _sigBlock.isEmpty ? -1 : text.indexOf(_sigBlock);
    // The range of [text] the new block replaces: the old block, or an empty
    // range at the start (reply) / end (new message).
    final int from;
    final int to;
    if (oldIndex >= 0) {
      from = oldIndex;
      to = oldIndex + _sigBlock.length;
    } else {
      from = isReply ? 0 : text.length;
      to = from;
    }
    final after = text.substring(to);
    final String newBlock;
    if (signature.isEmpty) {
      newBlock = '';
    } else if (isReply) {
      newBlock = after.startsWith('\n') || after.isEmpty
          ? '\n\n$signature'
          : '\n\n$signature\n\n';
    } else {
      newBlock = '\n\n$signature';
    }
    final updated = text.replaceRange(from, to, newBlock);
    final pristine = _bodyIsPristine;
    final sel = _body.selection;
    _sigBlock = newBlock;
    if (updated == text) return;
    // Programmatic edit — don't count it as the user dirtying a draft.
    _suppressAutoSave = true;
    if (pristine) {
      _setPristineBody(updated, base: text.replaceRange(from, to, ''));
    } else if (sel.isValid) {
      int shift(int o) =>
          o <= from ? o : (o >= to ? o + newBlock.length - (to - from) : from);
      _body.value = TextEditingValue(
        text: updated,
        selection: TextSelection(
          baseOffset: shift(sel.baseOffset),
          extentOffset: shift(sel.extentOffset),
        ),
      );
    } else {
      _body.text = updated;
    }
    _suppressAutoSave = false;
  }

  /// True while the body holds only programmatically inserted text and the
  /// cursor has not been placed anywhere but where we parked it.
  bool get _bodyIsPristine {
    final sel = _body.selection;
    return _body.text == _programmaticBody &&
        (!sel.isValid || sel == TextSelection.collapsed(offset: _parkOffset));
  }

  /// Sets a body the user has not touched yet, with the cursor parked where
  /// the message belongs. [base] is the body without the signature block.
  /// Focusing the body without a tap (Tab, IME "next", a screen reader) keeps
  /// a valid selection, so typing lands above the signature / quote instead
  /// of being glued to its end. A tap still places the cursor where tapped.
  void _setPristineBody(String text, {String? base}) {
    final b = base ?? text;
    // A reply, a forward ("\n\n— On … wrote:") or an empty body is written
    // at the top. A prefilled message text (mailto body) is continued, so the
    // cursor goes after it — before an appended signature.
    _parkOffset = _replyToEmailId != null || b.isEmpty || b.startsWith('\n')
        ? 0
        : b.length;
    _programmaticBody = text;
    _body.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: _parkOffset),
    );
  }

  /// Adds the files of [paths] that still exist; tells the user about the
  /// others, so a message is not sent without them unnoticed.
  Future<void> _loadInitialAttachments(List<String> paths) async {
    final found = <_AttachmentInfo>[];
    final missing = <String>[];
    final temp = widget.tempAttachmentPaths.toSet();
    for (final path in paths) {
      try {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.notFound) {
          missing.add(p.basename(path));
          continue;
        }
        final name = p.basename(path);
        found.add(
          _AttachmentInfo(
            path: path,
            filename: name,
            size: stat.size,
            contentType: _guessMimeType(name),
            isTemp: temp.contains(path),
          ),
        );
      } catch (_) {
        // Unreadable counts as gone; never leave Send disabled over it.
        missing.add(p.basename(path));
      }
    }
    if (!mounted) return;
    setState(() {
      _attachments.addAll(found);
      _loadingAttachments = false;
    });
    if (missing.isNotEmpty) {
      context.showAppSnackBar(
        'Attachment no longer available: ${missing.join(', ')}',
        level: AppLogLevel.warn,
        event: 'compose.attachment.missing',
        duration: const Duration(seconds: 8),
      );
    }
  }

  Future<void> _restoreDraft(int id) async {
    final draft = await _draftRepo.getDraft(id);
    if (draft == null || !mounted) return;
    // The user already started typing — never splice the draft into it.
    if (_draftDirty) return;
    // Programmatic fill — don't count it as the user dirtying the draft.
    _suppressAutoSave = true;
    setState(() {
      _draftRestored = true;
      _draftId = draft.id;
      _replyToEmailId = draft.replyToEmailId ?? _replyToEmailId;
      _to.text = draft.toText;
      _cc.text = draft.ccText;
      _bcc.text = draft.bccText;
      if (draft.bccText.trim().isNotEmpty) _showBcc = true;
      _subject.text = draft.subjectText;
      // Drafts pulled from the server come back with CRLF.
      _body.text = normalizeNewlines(draft.bodyText);
      if (draft.accountId != null) _accountId = draft.accountId;
      _sigAccountId = _accountId;
      _sigBlock = '';
    });
    _suppressAutoSave = false;
  }

  void _onTextChanged() {
    if (_suppressAutoSave) return;
    _draftDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _autoSave);
  }

  void _autoSave() => _autoSaveInFlight = _saveDraftNow();

  /// Waits for an in-flight auto-save so the row it creates is the one that
  /// gets deleted. A failed save is irrelevant here — the caller is about to
  /// drop the draft — so its error must not fail the send or discard.
  Future<void> _settleAutoSave() async {
    try {
      await _autoSaveInFlight;
    } on Object catch (_) {
      // Ignored: see above.
    }
  }

  Future<void> _saveDraftNow() async {
    if (!_draftDirty || !mounted) return;
    _draftDirty = false;
    final saved = await _draftRepo.saveDraft(
      id: _draftId,
      accountId: _accountId,
      replyToEmailId: _replyToEmailId,
      toText: _to.text,
      ccText: _cc.text,
      bccText: _bcc.text,
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
    for (final c in [_to, _cc, _bcc, _subject, _body]) {
      c.removeListener(_onTextChanged);
      c.dispose();
    }
    _toFocus.dispose();
    _ccFocus.dispose();
    _bccFocus.dispose();
    // Drop any temp files created for shrunk attachments — unless the
    // message was queued: the outbox sends (and may retry) from these files.
    if (!_queued) {
      for (final a in _attachments) {
        if (a.isTemp) unawaited(_deleteTempFile(a.path));
      }
    }
    // Flush any pending save synchronously — we can't await in dispose, but
    // scheduling a microtask still runs before the isolate exits.
    if (_draftDirty) {
      unawaited(
        _draftRepo.saveDraft(
          id: _draftId,
          accountId: _accountId,
          replyToEmailId: _replyToEmailId,
          toText: _to.text,
          ccText: _cc.text,
          bccText: _bcc.text,
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
    final service = ref.read(imageShrinkServiceProvider);
    for (final file in files) {
      final path = file.path!;
      final stat = await File(path).stat();
      var info = _AttachmentInfo(
        path: path,
        filename: file.name,
        size: stat.size,
        contentType: _guessMimeType(file.name),
      );
      // After attaching an image, offer to shrink it before it goes out.
      if (service.isShrinkable(info.contentType)) {
        final shrunk = await _maybeShrink(service, info);
        if (shrunk != null) info = shrunk;
      }
      if (!mounted) return;
      setState(() => _attachments.add(info));
    }
  }

  /// Shows the shrink dialog for [info] and, if the user accepts, writes the
  /// re-encoded JPEG to a temp file and returns a replacement attachment.
  /// Returns null when the user keeps the original or shrinking fails.
  Future<_AttachmentInfo?> _maybeShrink(
    ImageShrinkService service,
    _AttachmentInfo info,
  ) async {
    if (!mounted) return null;
    final result = await ShrinkImageDialog.show(
      context,
      path: info.path,
      service: service,
      initialSettings: _shrinkSettings,
    );
    if (result == null || !mounted) return null;
    _shrinkSettings = result.settings;
    try {
      final dir = await getTemporaryDirectory();
      final base = p.basenameWithoutExtension(info.filename);
      final outPath = p.join(
        dir.path,
        'shrunk_${DateTime.now().microsecondsSinceEpoch}_$base.jpg',
      );
      await File(outPath).writeAsBytes(result.bytes);
      return _AttachmentInfo(
        path: outPath,
        filename: '$base.jpg',
        size: result.bytes.length,
        contentType: 'image/jpeg',
        isTemp: true,
      );
    } catch (e, stack) {
      if (mounted) {
        context.showAppSnackBar(
          'Failed to shrink image: ${userErrorMessage(e)}',
          level: AppLogLevel.error,
          event: 'compose.attachment.shrink_failed',
          error: e,
          stack: stack,
          duration: const Duration(seconds: 5),
        );
      }
      return null;
    }
  }

  /// Re-opens the shrink dialog for an already-added attachment so the user can
  /// shrink it (or adjust an earlier shrink).
  Future<void> _shrinkExisting(int index) async {
    final service = ref.read(imageShrinkServiceProvider);
    final current = _attachments[index];
    final shrunk = await _maybeShrink(service, current);
    if (shrunk == null || !mounted) return;
    setState(() => _attachments[index] = shrunk);
    if (current.isTemp) unawaited(_deleteTempFile(current.path));
  }

  Future<void> _deleteTempFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Best-effort cleanup — a leftover temp file is harmless.
    }
  }

  void _removeAttachment(int index) {
    final removed = _attachments[index];
    setState(() => _attachments.removeAt(index));
    if (removed.isTemp) unawaited(_deleteTempFile(removed.path));
  }

  Future<void> _openAttachment(int index) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final path = _attachments[index].path;
      final problem = await openFile(path);
      if (problem != null && mounted) {
        context.showAppSnackBar(
          problem.text,
          level: AppLogLevel.warn,
          event: 'compose.attachment.open_failed',
          data: {'index': index, 'detail': problem.detail},
        );
      }
    } catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Failed to open file: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'compose.attachment.open_failed',
        data: {'index': index},
        error: e,
        stack: stack,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _guessMimeType(String filename) {
    return lookupMimeType(filename) ?? 'application/octet-stream';
  }

  /// `In-Reply-To` / `References` for a reply, from the original message's
  /// stored headers. Null for a new message, or when the original is gone,
  /// has no Message-ID or cannot be read; the reply is then sent unthreaded
  /// rather than not at all.
  Future<({String inReplyTo, List<String> references})?>
      _replyThreading() async {
    final id = _replyToEmailId;
    if (id == null) return null;
    final Email? parent;
    try {
      parent = await ref.read(emailRepositoryProvider).getEmail(id);
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).warn(
              'compose.reply_threading_failed',
              'Could not load the original message; sending unthreaded',
              screen: 'ComposeScreen',
              accountId: _accountId,
              emailId: id,
              error: e,
              stack: stack,
            ),
      );
      return null;
    }
    if (parent == null) return null;
    return replyThreading(
      messageId: parent.messageId,
      inReplyTo: parent.inReplyTo,
      references: parent.references,
    );
  }

  /// [_accountId], unless it names an account that no longer exists (a draft
  /// left behind by a deleted account): then the only account, or none.
  String? get _fromAccountId {
    final id = _accountId;
    if (id != null && _accounts.any((a) => a.id == id)) return id;
    return _accounts.length == 1 ? _accounts.first.id : null;
  }

  Future<void> _send() async {
    _accountId = _fromAccountId;
    if (_accountId == null) {
      context.showAppSnackBar(
        'Select an account first',
        duration: const Duration(seconds: 5),
      );
      return;
    }
    final invalid = [
      ...invalidRecipients(_to.text),
      ...invalidRecipients(_cc.text),
      ...invalidRecipients(_bcc.text),
    ];
    if (invalid.isNotEmpty) {
      context.showAppSnackBar(
        invalid.length == 1
            ? 'Not an email address: ${invalid.single}'
            : 'Not email addresses: ${invalid.join(', ')}',
        duration: const Duration(seconds: 5),
      );
      return;
    }
    final to = recipientAddresses(_to.text);
    if (to.isEmpty) {
      context.showAppSnackBar(
        'Add a recipient in To first',
        duration: const Duration(seconds: 5),
      );
      return;
    }
    setState(() => _sending = true);
    final messenger = context.appMessenger();
    // Set once the message is in the outbox: from then on a failure must not
    // leave the screen open for a second Send, nor bring the draft back.
    var queued = false;
    try {
      final account =
          (await ref.read(accountRepositoryProvider).getAccount(_accountId!))!;
      final queuedInReplyTo = widget.inReplyTo;
      final threading = queuedInReplyTo != null
          ? (inReplyTo: queuedInReplyTo, references: widget.references)
          : await _replyThreading();
      final draft = EmailDraft(
        from: EmailAddress(name: account.displayName, email: account.email),
        // Parsed into name and address here: the JMAP send path uses the
        // address as given, so a raw "Bob <bob@x>" chunk was rejected there.
        to: to,
        cc: recipientAddresses(_cc.text),
        bcc: recipientAddresses(_bcc.text),
        subject: _subject.text,
        body: _body.text,
        attachmentFilePaths: List.unmodifiable(
          _attachments.map((a) => a.path).toList(),
        ),
        tempAttachmentPaths: List.unmodifiable(
          _attachments.where((a) => a.isTemp).map((a) => a.path).toList(),
        ),
        inReplyTo: threading?.inReplyTo,
        references: threading?.references ?? const [],
      );
      // Enqueue first so the message is durably persisted even if the send
      // below is interrupted; the outbox is also drained on every sync cycle.
      final rowId = await ref
          .read(emailRepositoryProvider)
          .enqueueSend(_accountId!, draft);
      queued = true;
      _queued = true;
      // Delete the draft once it has been queued — the queued copy is the
      // canonical record from here on. As in [_discard], first stop the
      // pending auto-save and the [dispose] flush: typing and pressing Send
      // within [_saveDelay] otherwise wrote the sent message back as a fresh
      // draft when the screen closed, which then synced to the server's
      // Drafts folder.
      _saveTimer?.cancel();
      _draftDirty = false;
      _suppressAutoSave = true;
      await _settleAutoSave();
      if (_draftId != null) {
        await _draftRepo.deleteDraft(_draftId!);
      }
      // Attempt the send right now instead of only kicking the background loop,
      // so the message goes out "directly" and the user sees the concrete
      // outcome via a SnackBar (which AppMessenger also mirrors to the app log)
      // rather than a fire-and-forget "queued" with no follow-up (#755).
      final result = await ref
          .read(emailRepositoryProvider)
          .sendNow(_accountId!, outboxRowId: rowId);
      if (mounted) {
        switch (result.outcome) {
          case SendNowOutcome.sent:
            final warning = result.warning;
            messenger.show(
              warning == null ? 'Message sent' : 'Message sent. $warning',
              level: warning == null ? AppLogLevel.info : AppLogLevel.warn,
              event: 'compose.sent',
              accountId: _accountId,
              duration: Duration(seconds: warning == null ? 3 : 8),
            );
          case SendNowOutcome.transientFailed:
            messenger.show(
              'Queued — will retry: ${result.message}',
              level: AppLogLevel.warn,
              event: 'compose.send_queued',
              accountId: _accountId,
              duration: const Duration(seconds: 5),
            );
          case SendNowOutcome.permanentlyFailed:
            messenger.show(
              'Send failed: ${result.message}',
              level: AppLogLevel.error,
              event: 'compose.send_failed',
              accountId: _accountId,
              duration: const Duration(seconds: 5),
            );
          case SendNowOutcome.queued:
            messenger.show(
              'Message queued',
              event: 'compose.queued',
              accountId: _accountId,
              duration: const Duration(seconds: 3),
            );
        }
        context.pop();
      }
    } catch (e, stack) {
      if (!mounted) return;
      if (queued) {
        // The outbox already holds the message and retries it on every sync
        // cycle, so report it as queued and close, as for a transient failure.
        messenger.show(
          'Queued — will retry: ${userErrorMessage(e)}',
          level: AppLogLevel.warn,
          event: 'compose.send_queued',
          accountId: _accountId,
          error: e,
          stack: stack,
          duration: const Duration(seconds: 5),
        );
        context.pop();
        return;
      }
      messenger.show(
        'Queue failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'compose.enqueue_failed',
        accountId: _accountId,
        error: e,
        stack: stack,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Throws away the draft: cancels any pending auto-save, deletes the saved
  /// row (which also tombstones it on the server, see [DraftRepository]) and
  /// pops the screen. Clearing [_draftDirty] and setting [_suppressAutoSave]
  /// stops both the [dispose] flush and the field listeners from resurrecting
  /// the row after we delete it.
  Future<void> _discard() async {
    if (_sending) return;
    _saveTimer?.cancel();
    _draftDirty = false;
    _suppressAutoSave = true;
    final messenger = context.appMessenger();
    try {
      // As in [_send]: an auto-save still writing would otherwise create the
      // row after we delete it (or under an id we never saw).
      await _settleAutoSave();
      if (_draftId != null) {
        await _draftRepo.deleteDraft(_draftId!);
      }
    } catch (e, stack) {
      if (!mounted) return;
      messenger.show(
        'Discard failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'compose.discard_failed',
        accountId: _accountId,
        error: e,
        stack: stack,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    if (mounted) {
      messenger.show(
        'Draft discarded',
        duration: const Duration(seconds: 3),
      );
      _leaving = true;
      context.pop();
    }
  }

  /// Leaving keeps the text as a draft, but drafts cannot hold attachments
  /// yet (#955) — so with attachments that would silently lose them. Ask.
  bool get _wouldLoseAttachments =>
      (_attachments.isNotEmpty || _loadingAttachments) && !_queued && !_leaving;

  Future<void> _confirmLeave() async {
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard attachments?'),
        content: const Text(
          'The text is kept as a draft, but drafts cannot keep attachments '
          'yet. Leaving now loses them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.stay),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.discard),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.send),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _LeaveChoice.discard:
        setState(() => _leaving = true);
        Navigator.of(context).pop();
      case _LeaveChoice.send:
        if (!_sending && !_loadingAttachments) await _send();
      case _LeaveChoice.stay:
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_wouldLoseAttachments,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Send or Discard draft closing the screen while canPop was stale.
        if (!_wouldLoseAttachments) {
          Navigator.of(context).pop();
          return;
        }
        unawaited(_confirmLeave());
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
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
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Discard draft',
            onPressed: _sending ? null : _discard,
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
            onPressed: _sending || _loadingAttachments ? null : _send,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (_accounts.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: AccessibleDropdown.formField(
                child: DropdownButtonFormField<String>(
                  initialValue: _fromAccountId,
                  decoration: const InputDecoration(
                    labelText: 'From',
                    border: OutlineInputBorder(),
                  ),
                  // Without isExpanded the button sizes itself to the WIDEST
                  // ITEM, not to whatever is displayed — so this overflowed by
                  // 426px on a 411dp screen at text scale 2.0 while the short
                  // "Select an account" hint was the only thing on screen.
                  // isExpanded clamps the button to the field it sits in.
                  isExpanded: true,
                  // With the button clamped, an un-ellipsized item would wrap
                  // instead, making the collapsed field two or three lines
                  // tall. selectedItemBuilder truncates only the closed
                  // button, so the open menu keeps the full address readable
                  // — the menu can never be wider than the button, so
                  // ellipsizing the items themselves would leave the user
                  // choosing between addresses they cannot read.
                  // No Align: DropdownButton already puts these in an
                  // IndexedStack aligned centerStart, and a bare Align expands
                  // to fill any bounded height it is handed.
                  selectedItemBuilder: (context) => _accounts
                      .map(
                        (a) => Text(
                          accountFromLabel(a),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                      .toList(),
                  hint: const Text('Select an account'),
                  items: _accounts
                      .map(
                        (a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(accountFromLabel(a)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() => _accountId = v);
                    unawaited(_applySignatureForAccount(v));
                    // Save the new account like an edit, so a saved draft
                    // moves even when nothing is typed afterwards.
                    if (_draftId != null) _onTextChanged();
                  },
                ),
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
                // Deliberately NOT ellipsized. There is no menu to open in
                // this branch, so truncating would hide the sending address
                // with no way to recover it. It wraps instead, which costs a
                // couple of lines inside a ListView that already scrolls.
                child: Text(accountFromLabel(_accounts.first)),
              ),
            ),
          _addressField(_to, _toFocus, 'To'),
          _addressField(
            _cc,
            _ccFocus,
            'Cc',
            suffix: _showBcc
                ? null
                : TextButton(
                    key: const Key('compose-show-bcc'),
                    onPressed: () {
                      setState(() => _showBcc = true);
                      _bccFocus.requestFocus();
                    },
                    child: const Text('Bcc'),
                  ),
          ),
          if (_showBcc) _addressField(_bcc, _bccFocus, 'Bcc'),
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
                    if (ref
                        .read(imageShrinkServiceProvider)
                        .isShrinkable(_attachments[i].contentType))
                      IconButton(
                        icon: const Icon(Icons.compress),
                        tooltip: 'Shrink',
                        onPressed: () => _shrinkExisting(i),
                      ),
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
    String label, {
    Widget? suffix,
  }) {
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
              suffixIcon: suffix,
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

enum _LeaveChoice { stay, discard, send }

class _AttachmentInfo {
  final String path;
  final String filename;
  final int size;
  final String contentType;

  /// True when [path] points at a temp file we created (a shrunk copy) and are
  /// responsible for deleting once the attachment is removed or replaced.
  final bool isTemp;

  _AttachmentInfo({
    required this.path,
    required this.filename,
    required this.size,
    required this.contentType,
    this.isTemp = false,
  });
}

// Helper to silence the unawaited_futures lint on fire-and-forget futures.
void unawaited(Future<void> _) {}
