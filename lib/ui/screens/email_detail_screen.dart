import 'dart:async';
import 'dart:developer' show log;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/similar_filter.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/linked_note.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/platform/raw_email_downloader.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart'
    show NoWriteKeyException;
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';
import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:sharedinbox/core/utils/list_unsubscribe.dart';
import 'package:sharedinbox/core/utils/quote_fold.dart';
import 'package:sharedinbox/core/utils/reply_recipients.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/open_file.dart';
import 'package:sharedinbox/ui/utils/save_file_as.dart';
import 'package:sharedinbox/ui/utils/send_briefly.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/confirm_delete_dialog.dart';
import 'package:sharedinbox/ui/widgets/conversation_tree.dart';
import 'package:sharedinbox/ui/widgets/email_headers_dialog.dart';
import 'package:sharedinbox/ui/widgets/error_boundary.dart';
import 'package:sharedinbox/ui/widgets/foldable_quote_text.dart';
import 'package:sharedinbox/ui/widgets/image_viewer_screen.dart';
import 'package:sharedinbox/ui/widgets/new_card_dialog.dart';
import 'package:sharedinbox/ui/widgets/secure_email_webview.dart';
import 'package:sharedinbox/ui/widgets/snooze_picker.dart';
import 'package:sharedinbox/ui/widgets/text_prompt_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

final _dateFmt = DateFormat('EEE, MMM d yyyy, HH:mm');

class EmailDetailScreen extends ConsumerStatefulWidget {
  const EmailDetailScreen({super.key, required this.emailId, this.nav});
  final String emailId;

  /// Ordered list of sibling emails from the caller (mailbox list, search
  /// results, address filter, …). Powers the prev/next controls and the
  /// after-action "next message" hop. `null` for deep links / notifications
  /// — the screen falls back to walking the current mailbox's individual
  /// emails in that case.
  final EmailDetailNav? nav;

  @override
  ConsumerState<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends ConsumerState<EmailDetailScreen> {
  bool _isFlagged = false;

  /// Whether the user toggled the star on this mail. A load that finishes
  /// afterwards then keeps the user's choice instead of the older row's.
  bool _flagTouched = false;
  bool _loadRemoteImages = false;

  /// [htmlHasRemoteResources] result for the body last checked, so the regex
  /// scan runs once per loaded body instead of on every rebuild.
  String? _remoteCheckedHtml;
  bool _remoteCheckedResult = false;
  final Set<String> _downloading = {};

  /// Non-null while a destructive or move action (delete, archive, spam, move,
  /// snooze) is running: holds the label shown over a dimmed message body so
  /// the user gets immediate feedback that their tap took effect, even though
  /// deleting/moving and loading the next message can take a few seconds
  /// (#817). Cleared once the action completes — on success that's the moment
  /// [_navigateTo] swaps in the next mail.
  String? _actionInFlight;

  /// Runs [mutation] while dimming the current message body and showing
  /// [label] over it, so a slow delete/move reads as "in progress" rather than
  /// a frozen, seemingly-unchanged screen (#817). The dim is cleared in a
  /// `finally` so a failure surfaces the mail again instead of stranding the
  /// scrim.
  Future<T> _runDimmed<T>(String label, Future<T> Function() mutation) async {
    if (mounted) setState(() => _actionInFlight = label);
    try {
      return await mutation();
    } finally {
      if (mounted) setState(() => _actionInFlight = null);
    }
  }

  /// Local file paths of image attachments' inline previews, keyed by
  /// filename. Populated by [_showImage] and re-used across rebuilds.
  final Map<String, String> _imagePaths = {};

  /// Filenames whose inline preview fetch has already been kicked off, so the
  /// auto-load in [_buildAttachment] fires exactly once per image rather than
  /// on every rebuild.
  final Set<String> _autoRequestedImages = {};

  /// Filenames whose inline preview fetch failed, so the row offers a Retry
  /// button instead of silently retrying on the next rebuild.
  final Set<String> _imageLoadFailed = {};

  /// Filenames whose downloaded bytes did not match any image format Flutter
  /// can decode, despite a displayable declared MIME type. Rendering them would
  /// show colour-noise rather than throw (#830), so the row shows a "could not
  /// be displayed" note plus the download-and-open action instead of a preview.
  /// Distinct from [_imageLoadFailed]: retrying the fetch would produce the same
  /// bytes, so no Retry button is offered.
  final Set<String> _imageUnsupported = {};

  /// Fallback nav resolved from `observeEmails(mailbox)` when [widget.nav]
  /// is null (deep links, notifications). Cached per emailId so the buttons
  /// don't refetch on every rebuild.
  EmailDetailNav? _fallbackNav;
  String? _fallbackNavForEmailId;
  bool _fallbackNavLoading = false;

  @override
  void didUpdateWidget(covariant EmailDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emailId != widget.emailId) {
      // A different mail is now on screen — its neighbours differ, so drop
      // the cached fallback list. The provided [widget.nav] indexes by id,
      // so no invalidation needed for that path.
      _fallbackNav = null;
      _fallbackNavForEmailId = null;
      // Inline previews are keyed by filename, so clear them too or a new
      // message could show the previous one's image under a same-named file.
      _imagePaths.clear();
      _autoRequestedImages.clear();
      _imageLoadFailed.clear();
      _imageUnsupported.clear();
      // The cached row and star belong to the previous mail: drop them, so
      // no action runs on it, and read this mail's row (#1330). Stepping
      // never opens a draft in compose, so no draft check here.
      _checkedHeader = null;
      _checkedRole = null;
      _isFlagged = false;
      _flagTouched = false;
      unawaited(_refreshCachedRow());
    }
  }

  /// Returns the active nav — either the one handed in by the caller or a
  /// mailbox-scoped fallback fetched lazily from the repo. Returns null while
  /// the fallback is still in flight or when no header is available yet.
  EmailDetailNav? _activeNav(Email? header) {
    // An empty list only marks a step from the fallback list (_steppedNav).
    if (widget.nav?.items.isNotEmpty ?? false) return widget.nav;
    if (header == null) return null;
    if (_fallbackNavForEmailId == widget.emailId && _fallbackNav != null) {
      return _fallbackNav;
    }
    if (!_fallbackNavLoading) {
      _fallbackNavLoading = true;
      unawaited(_loadFallbackNav(header));
    }
    return null;
  }

  Future<void> _loadFallbackNav(Email header) async {
    try {
      final emails = await ref
          .read(emailRepositoryProvider)
          .observeEmails(header.accountId, header.mailboxPath)
          .first;
      if (!mounted) return;
      setState(() {
        _fallbackNav = EmailDetailNav.fromEmails(emails);
        _fallbackNavForEmailId = widget.emailId;
        _fallbackNavLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _fallbackNavLoading = false);
    }
  }

  /// False until [_checkForDraft] ran. Until then neither header nor body is
  /// loaded for display, so a draft opens in compose without a read-only view
  /// flashing first, and without the body fetch that view needs.
  bool _draftChecked = false;

  /// The header and its folder's role, read by [_checkForDraft] from the
  /// cached row. They keep "Edit draft" and every action that needs no body
  /// (archive, move, snooze, delete, …) usable while the body loads or when
  /// it fails to load, e.g. offline with no cached body (#1330).
  Email? _checkedHeader;
  String? _checkedRole;

  /// Whether "Edit draft" is running (a draft sync can take a while).
  bool _editingDraft = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkForDraft());
  }

  /// A message in the Drafts folder is a draft's server copy: opened by the
  /// user (from a folder, the combined inbox, search, a link), it goes to
  /// compose to continue editing, like "Open draft" from the Compose action.
  /// Reached by prev/next or after an action it stays here. Without a local
  /// draft yet it stays here too, with "Edit draft" in place of Reply.
  Future<void> _checkForDraft() async {
    // A notification tap can swap in another mail while this runs.
    final emailId = widget.emailId;
    Email? header;
    String? role;
    try {
      (header, role) = await _readCachedRow(emailId);
      if (header != null &&
          role == 'drafts' &&
          !(widget.nav?.steppedTo ?? false) &&
          await _openDraftInCompose(header)) {
        return;
      }
    } catch (e, stack) {
      // Not fatal: the detail view loads (and reports) the message itself.
      log('draft check failed', error: e, stackTrace: stack);
    }
    if (!mounted) return;
    setState(() {
      _draftChecked = true;
      // Another mail is on screen: its own row read is in flight.
      if (widget.emailId != emailId) return;
      _checkedHeader = header;
      _checkedRole = role;
      if (header != null && !_flagTouched) _isFlagged = header.isFlagged;
    });
  }

  /// The cached row of [emailId] and the role of its folder.
  Future<(Email?, String?)> _readCachedRow(String emailId) async {
    final header = await ref.read(emailRepositoryProvider).getEmail(emailId);
    if (header == null) return (null, null);
    final mailboxes = await ref
        .read(mailboxRepositoryProvider)
        .observeMailboxes(header.accountId)
        .first;
    final role =
        mailboxes.where((m) => m.path == header.mailboxPath).firstOrNull?.role;
    return (header, role);
  }

  /// Re-reads the cached row after Prev/Next swapped in another mail.
  Future<void> _refreshCachedRow() async {
    final emailId = widget.emailId;
    try {
      final (header, role) = await _readCachedRow(emailId);
      if (!mounted || widget.emailId != emailId) return;
      setState(() {
        _checkedHeader = header;
        _checkedRole = role;
        if (header != null && !_flagTouched) _isFlagged = header.isFlagged;
      });
    } catch (e, stack) {
      // Not fatal: the detail view loads (and reports) the message itself.
      log('cached row read failed', error: e, stackTrace: stack);
    }
  }

  /// Opens compose for [header]'s local draft in place of this screen.
  /// Returns false when there is none.
  Future<bool> _openDraftInCompose(Email header) async {
    final draft =
        await ref.read(draftRepositoryProvider).findDraftForEmail(header);
    if (draft == null || !mounted) return false;
    final extra = {
      'accountId': draft.accountId ?? header.accountId,
      'draftId': draft.id,
    };
    final router = GoRouter.of(context);
    if (router.canPop()) {
      // Pop, then push, rather than pushReplacement: whoever pushed this
      // screen and awaits its result (search refreshes its hits afterwards)
      // gets it now, and back from compose returns to that list.
      router.pop();
      unawaited(router.push('/compose', extra: extra));
    } else {
      unawaited(router.pushReplacement('/compose', extra: extra));
    }
    return true;
  }

  /// "Edit draft": a server draft not pulled into the local drafts yet (made
  /// by another client since the last sync) is pulled by a draft sync first.
  Future<void> _editDraft(Email header) async {
    if (_editingDraft) return;
    setState(() => _editingDraft = true);
    try {
      if (await _openDraftInCompose(header)) return;
      try {
        await ref.read(draftRepositoryProvider).syncDrafts(header.accountId);
      } catch (e, stack) {
        if (!mounted) return;
        context.showAppSnackBar(
          'Could not sync drafts: ${userErrorMessage(e)}',
          level: AppLogLevel.error,
          event: 'email.detail.draft_sync_failed',
          emailId: widget.emailId,
          error: e,
          stack: stack,
        );
        return;
      }
      if (!mounted || await _openDraftInCompose(header) || !mounted) return;
      context.showAppSnackBar(
        'This draft is not among the drafts on this device. It may have '
        'been sent or deleted meanwhile; pull to refresh the folder.',
        level: AppLogLevel.warn,
        event: 'email.detail.draft_not_found',
        emailId: widget.emailId,
      );
    } finally {
      if (mounted) setState(() => _editingDraft = false);
    }
  }

  /// [widget.nav] (or the fallback list) for the message reached next by
  /// stepping, so it stays in the detail view even when it is a draft.
  EmailDetailNav _steppedNav() =>
      (widget.nav ?? _fallbackNav ?? const EmailDetailNav([])).stepped();

  void _goToNeighbour(EmailDetailNavItem target) {
    if (!mounted) return;
    context.go(
      '/accounts/${target.accountId}'
      '/mailboxes/${Uri.encodeComponent(target.mailboxPath)}'
      '/emails/${Uri.encodeComponent(target.emailId)}',
      extra: _steppedNav(),
    );
  }

  /// Menu entries that cannot run without the message body.
  static bool _isBodyAction(String value) => _bodyActions.contains(value);

  static const _bodyActions = {
    'forward',
    'select_text',
    'create_card',
    'headers',
    'structure',
  };

  /// Menu entries that need the message's row (account, folder, sender).
  static const _headerActions = {
    'forward',
    'move',
    'snooze',
    'find_similar',
    'notify_sender',
    'headers',
    'debug_mail',
    'create_todo',
    'create_card',
  };

  /// Says why a menu entry that needs the message's row did nothing: the
  /// row is not in the local database (e.g. opened from a notification
  /// before the folder synced) (#1330).
  void _explainHeaderMissing() {
    context.showAppSnackBar(
      'Message details are not available yet. Try again after the next sync.',
      level: AppLogLevel.warn,
      event: 'email.detail.header_unavailable',
      emailId: widget.emailId,
      persist: false,
    );
  }

  /// Whether there is no body to work with: not loaded, or a failed load
  /// (#837) that brought back no cached content either. A load error with a
  /// cached body still counts as a body, as the screen shows it.
  static bool _bodyMissing(EmailBody? body) {
    if (body == null) return true;
    if (body.loadError == null) return false;
    return (body.textBody?.isEmpty ?? true) &&
        (body.htmlBody?.isEmpty ?? true) &&
        body.attachments.isEmpty;
  }

  /// While the body of [emailId] is still loading, waits for it (at most a
  /// few seconds, under a scrim that also stops Prev/Next) so Reply can
  /// quote it and Forward can include it (#1346, #1347). Returns [body] when
  /// it is there already, or the load is not running or fails.
  Future<EmailBody?> _awaitLoadingBody(String emailId, EmailBody? body) async {
    if (!_bodyMissing(body)) return body;
    final provider = emailDetailProvider(emailId);
    if (!ref.read(provider).isLoading) return body;
    try {
      final (_, loaded) = await _runDimmed(
        'Loading message…',
        () => ref.read(provider.future).timeout(const Duration(seconds: 10)),
      );
      return loaded;
    } catch (_) {
      // Failure is reported by the detail view itself; reply unquoted.
      return body;
    }
  }

  /// Explains in a SnackBar, and returns true, when [body] is missing or
  /// failed to load, so an action built on it (Forward, quoting in Reply, …)
  /// never silently does nothing (#1330). Returns false when the body is there.
  bool _explainBodyMissing(EmailBody? body, {String? message}) {
    if (!_bodyMissing(body)) return false;
    final loading = ref.read(emailDetailProvider(widget.emailId)).isLoading;
    context.showAppSnackBar(
      message ??
          (loading
              ? 'The message is still loading. Try again in a moment.'
              : 'The message body could not be loaded (offline?), so this '
                  'is not available. Tap Retry when online.'),
      level: AppLogLevel.warn,
      event: 'email.detail.body_unavailable',
      emailId: widget.emailId,
      persist: false,
    );
    return true;
  }

  /// One-shot SnackBar pointing at the App Log, shown when this message's body
  /// could not be loaded — whether the fetch threw or returned a body flagged
  /// with a [EmailBody.loadError] (#587, #837).
  void _showLoadFailedSnackBar() {
    context.showAppSnackBar(
      'Could not load this message. See the app log for details.',
      level: AppLogLevel.error,
      event: 'email.detail.load_failed_snackbar',
      emailId: widget.emailId,
      duration: const Duration(seconds: 6),
      persist: false,
      action: SnackBarAction(
        label: 'Show logs',
        onPressed: () {
          if (mounted) {
            unawaited(
              context.push('/accounts/app-log?emailId=${widget.emailId}'),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_draftChecked) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final repo = ref.watch(emailRepositoryProvider);
    final detail = ref.watch(emailDetailProvider(widget.emailId));

    ref.listen<AsyncValue<(Email?, EmailBody)>>(
      emailDetailProvider(widget.emailId),
      (prev, next) {
        final email = next.value?.$1;
        if (email != null && mounted && !_flagTouched) {
          setState(() => _isFlagged = email.isFlagged);
        }
        // Surface the load failure as a SnackBar so an empty body screen isn't
        // silent — the in-body panel offers Retry/Raw, this points at the App
        // Log where the underlying error was recorded (#587). Fire only on the
        // transition *into* error so a plain rebuild doesn't re-show it, but a
        // Retry that fails again (loading → error) does.
        if (next.hasError && (prev == null || !prev.hasError) && mounted) {
          _showLoadFailedSnackBar();
        }
        // A non-throwing failure (e.g. an IMAP Message-ID mismatch that can't be
        // self-healed) returns a body carrying a loadError instead of throwing,
        // so the hasError branch above never fires. Surface it the same way, on
        // the transition into a load error so a rebuild doesn't re-show it (#837).
        final nextLoadError = next.value?.$2.loadError;
        final prevLoadError = prev?.value?.$2.loadError;
        if (nextLoadError != null && prevLoadError == null && mounted) {
          _showLoadFailedSnackBar();
        }
      },
    );

    // Fall back to the cached row while the body loads or when loading it
    // failed: the detail provider then has no header, and the actions that
    // need none must still work offline, as from the list (#1330).
    // Only this mail's row: after Prev/Next the State is reused and the row
    // of the next mail may not be read yet.
    final cached = _checkedHeader?.id == widget.emailId ? _checkedHeader : null;
    final header = detail.value?.$1 ?? cached;
    final body = detail.value?.$2;
    final personalDataBeta =
        ref.watch(userPreferencesProvider).value?.personalDataBeta ?? false;

    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final activeNav = _activeNav(header);
    // No stepping while an action runs on this mail under its scrim (a
    // Reply waiting for the body, a delete): it would land on the next one.
    final canStep = _actionInFlight == null;
    final prevItem = canStep ? activeNav?.prevOf(widget.emailId) : null;
    final nextItem = canStep ? activeNav?.nextOf(widget.emailId) : null;

    // Role of the folder the open message lives in. When it is the Junk or
    // Trash folder the destructive action turns into its inverse (un-junk /
    // un-trash) so re-junking / re-deleting an already-filed mail is replaced
    // by a clearly labelled "move back to Inbox".
    final folderRole = header == null
        ? null
        : ref
            .watch(
              mailboxByPathProvider((header.accountId, header.mailboxPath)),
            )
            .value
            ?.role;
    final isDraft =
        (folderRole ?? (cached == null ? null : _checkedRole)) == 'drafts';

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isMobile,
        actions: [
          if (!isMobile) ...[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous message',
              onPressed:
                  prevItem == null ? null : () => _goToNeighbour(prevItem),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next message',
              onPressed:
                  nextItem == null ? null : () => _goToNeighbour(nextItem),
            ),
          ],
          if (isDraft)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit draft',
              onPressed: header == null || _editingDraft
                  ? null
                  : () => unawaited(_editDraft(header)),
            )
          else
            IconButton(
              icon: const Icon(Icons.reply),
              tooltip: 'Reply',
              onPressed: header == null
                  ? null
                  : () => unawaited(
                        _composeOnce(
                          () =>
                              _replyWithRecipientDialog(context, header, body),
                        ),
                      ),
            ),
          _ActionMorphButton(
            icon: Icons.archive,
            tooltip: 'Archive',
            color: const Color(0xFF2E7D32),
            onPressed: header == null
                ? null
                : () {
                    unawaited(HapticFeedback.mediumImpact());
                    unawaited(_archive(context, header));
                  },
          ),
          if (folderRole == 'trash')
            _ActionMorphButton(
              icon: Icons.restore_from_trash,
              tooltip: 'Restore',
              color: const Color(0xFF2E7D32),
              onPressed: header == null
                  ? null
                  : () {
                      unawaited(HapticFeedback.mediumImpact());
                      unawaited(_moveToInbox(context, header));
                    },
            )
          else
            _ActionMorphButton(
              icon: Icons.delete,
              tooltip: 'Delete',
              color: Theme.of(context).colorScheme.error,
              onPressed: () async {
                unawaited(HapticFeedback.heavyImpact());
                final nextEmail = await _getNextEmailIfNeeded(header);
                var ops = const <String, List<int>>{};
                final destPath = await _runDimmed('Deleting…', () async {
                  final (dest, queued) = await repo.captureOps(
                    () => repo.deleteEmail(widget.emailId),
                  );
                  ops = queued;
                  return dest;
                });

                if (header != null) {
                  // Fire-and-forget so the state update (which is applied
                  // synchronously inside pushAction) reaches UndoShell before
                  // we start the route transition. Matches _archive /
                  // _markAsSpam.
                  unawaited(
                    ref.read(undoServiceProvider.notifier).pushAction(
                          UndoAction(
                            id: DateTime.now().toIso8601String(),
                            accountId: header.accountId,
                            type: UndoType.delete,
                            emailIds: [widget.emailId],
                            sourceMailboxPath: header.mailboxPath,
                            destinationMailboxPath: destPath,
                            originalEmails: [header],
                            opSeqs: ops,
                          ),
                        ),
                  );
                }

                if (context.mounted) _navigateTo(context, header, nextEmail);
              },
            ),
          IconButton(
            icon: Icon(
              _isFlagged ? Icons.star : Icons.star_border,
              color: _isFlagged ? Colors.amber : null,
            ),
            tooltip: _isFlagged ? 'Unflag' : 'Flag',
            onPressed: () async {
              final next = !_isFlagged;
              final emailId = widget.emailId;
              _flagTouched = true;
              await repo.setFlag(emailId, flagged: next);
              // Prev/Next during the await: the star now shows another mail.
              if (!mounted || widget.emailId != emailId) return;
              setState(() => _isFlagged = next);
            },
          ),
          if (folderRole == 'junk')
            _ActionMorphButton(
              icon: Icons.report_off,
              tooltip: 'Not junk',
              color: const Color(0xFF2E7D32),
              onPressed: header == null
                  ? null
                  : () {
                      unawaited(HapticFeedback.mediumImpact());
                      unawaited(_moveToInbox(context, header));
                    },
            )
          else
            _ActionMorphButton(
              icon: Icons.report_outlined,
              tooltip: 'Mark as spam',
              color: const Color(0xFFE65100),
              onPressed: header == null
                  ? null
                  : () {
                      unawaited(HapticFeedback.mediumImpact());
                      unawaited(_markAsSpam(context, header));
                    },
            ),
          PopupMenuButton<String>(
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'forward', child: Text('Forward')),
              const PopupMenuItem(value: 'move', child: Text('Move to folder')),
              const PopupMenuItem(value: 'snooze', child: Text('Snooze')),
              const PopupMenuItem(
                value: 'find_similar',
                child: Text('Find similar emails'),
              ),
              const PopupMenuItem(
                value: 'notify_sender',
                child: Text('Notify me for mail from this sender'),
              ),
              const PopupMenuItem(
                value: 'select_text',
                child: Text('Select text'),
              ),
              const PopupMenuItem(
                value: 'mark_unread',
                child: Text('Mark as unread'),
              ),
              if (personalDataBeta && header?.messageId != null)
                const PopupMenuItem(
                  key: Key('emailCreateTodo'),
                  value: 'create_todo',
                  child: Text('Create todo'),
                ),
              if (personalDataBeta)
                const PopupMenuItem(
                  key: Key('emailCreateCard'),
                  value: 'create_card',
                  child: Text('Create card'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'headers',
                child: Text('Show Mail Headers'),
              ),
              const PopupMenuItem(
                value: 'structure',
                child: Text('Show Mail Structure'),
              ),
              const PopupMenuItem(value: 'rfc', child: Text('Show Raw Email')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'show_logs',
                child: Text('Show Logs'),
              ),
              const PopupMenuItem(
                value: 'debug_mail',
                child: Text('Debug Mail'),
              ),
              const PopupMenuItem(
                value: 'bug_report',
                child: Text('Report a Bug'),
              ),
            ],
            onSelected: (value) async {
              if (header == null && _headerActions.contains(value)) {
                _explainHeaderMissing();
                return;
              }
              // Forward waits for a body that is still loading, as Reply
              // does, and explains a missing one itself (#1347).
              if (_isBodyAction(value) &&
                  value != 'forward' &&
                  _explainBodyMissing(body)) {
                return;
              }
              if (value == 'forward' && header != null) {
                unawaited(_forward(context, header, body));
              } else if (value == 'move' && header != null) {
                unawaited(_moveTo(context, header));
              } else if (value == 'snooze' && header != null) {
                unawaited(_snooze(context, header));
              } else if (value == 'find_similar' && header != null) {
                unawaited(
                  context.push('/search', extra: similarFilterFor(header)),
                );
              } else if (value == 'notify_sender' && header != null) {
                await _notifyForSender(context, header);
              } else if (value == 'create_todo' && header != null) {
                unawaited(_createTodo(context, header));
              } else if (value == 'select_text' && body != null) {
                _showSelectText(
                  context,
                  body,
                  cardsIn: personalDataBeta ? header?.accountId : null,
                );
              } else if (value == 'create_card' &&
                  body != null &&
                  header != null) {
                _showSelectText(context, body, cardsIn: header.accountId);
              } else if (value == 'mark_unread') {
                // Always back to the list, whatever "After mail action" says:
                // opening the next mail would mark it read although the user
                // never chose to open it.
                await ref
                    .read(emailDetailProvider(widget.emailId).notifier)
                    .markUnread();
                if (context.mounted) _navigateTo(context, header, null);
              } else if (value == 'headers' && body != null && header != null) {
                unawaited(_showHeaders(context, body, header.accountId));
              } else if (value == 'structure' && body != null) {
                unawaited(_showStructure(context, body));
              } else if (value == 'rfc') {
                unawaited(_showRaw(context, header));
              } else if (value == 'show_logs') {
                unawaited(
                  context.push('/accounts/app-log?emailId=${widget.emailId}'),
                );
              } else if (value == 'debug_mail' && header != null) {
                unawaited(
                  context.push(
                    '/debug/mail',
                    extra: DebugMessageRef(
                      accountId: header.accountId,
                      mailboxPath: header.mailboxPath,
                      emailId: widget.emailId,
                    ),
                  ),
                );
              } else if (value == 'bug_report') {
                unawaited(
                  context.push('/bug-report?emailId=${widget.emailId}'),
                );
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _wrapWithSwipe(
            isMobile: isMobile,
            prev: prevItem,
            next: nextItem,
            child: detail.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _buildLoadError(context, e),
              data: (d) {
                final trusted = ref.watch(trustedImageSendersProvider).value ??
                    const <String>[];
                return _buildBody(context, d.$1, d.$2, trusted);
              },
            ),
          ),
          if (_actionInFlight != null)
            _buildActionScrim(context, _actionInFlight!),
        ],
      ),
    );
  }

  /// On mobile, wraps [child] in a horizontal drag detector so a fling left
  /// advances to the next message and a fling right returns to the previous
  /// one. Uses [HitTestBehavior.deferToChild] so vertical scrolls in the mail
  /// body remain unaffected (#292).
  Widget _wrapWithSwipe({
    required bool isMobile,
    required EmailDetailNavItem? prev,
    required EmailDetailNavItem? next,
    required Widget child,
  }) {
    if (!isMobile) return child;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        // Match the ~300 px/s threshold used elsewhere in the app so
        // accidental drift while scrolling never triggers navigation.
        if (velocity <= -300 && next != null) {
          unawaited(HapticFeedback.selectionClick());
          _goToNeighbour(next);
        } else if (velocity >= 300 && prev != null) {
          unawaited(HapticFeedback.selectionClick());
          _goToNeighbour(prev);
        }
      },
      child: child,
    );
  }

  /// Semi-transparent scrim drawn over the message body while a destructive or
  /// move action runs. Grays out the mail the user just acted on and names the
  /// action in progress, and absorbs taps so the dimmed mail can't be acted on
  /// twice while the first action is still in flight (#817).
  Widget _buildActionScrim(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.7),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: AppSpacing.md),
                Text(label, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _hasRemoteResources(String html) {
    if (!identical(html, _remoteCheckedHtml)) {
      _remoteCheckedHtml = html;
      _remoteCheckedResult = htmlHasRemoteResources(html);
    }
    return _remoteCheckedResult;
  }

  Widget _buildBody(
    BuildContext ctx,
    Email? header,
    EmailBody body,
    List<String> trustedSenders,
  ) {
    final hasHtml = (body.htmlBody ?? '').trim().isNotEmpty;
    final senderEmail = header?.from.isNotEmpty == true
        ? header!.from.first.email.toLowerCase()
        : null;
    final isTrusted = senderEmail != null &&
        trustedSenders.any((p) => globMatch(senderEmail, p));
    final effectiveLoadImages = _loadRemoteImages || isTrusted;
    // Offering to load images on mail that has none would also silently add
    // the sender to the trusted list for nothing.
    final offerRemoteImages =
        hasHtml && !effectiveLoadImages && _hasRemoteResources(body.htmlBody!);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (header != null) ...[_buildHeader(ctx, header), const Divider()],
        if (header?.messageId != null) _buildNotesSection(ctx, header!),
        if (body.loadError != null)
          _buildLoadFailedNotice(ctx, body.loadError!),
        if (body.decodeFailed) _buildDecodeFailedNotice(ctx, header),
        if (hasHtml) ...[
          if (offerRemoteImages)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: AppIconSize.sm),
                  label: const Text('Load remote images'),
                  onPressed: () {
                    setState(() => _loadRemoteImages = true);
                    if (senderEmail != null) {
                      unawaited(
                        ref
                            .read(userPreferencesRepositoryProvider)
                            .addTrustedImageSender(senderEmail),
                      );
                      ctx.showAppSnackBar(
                        'Images will be loaded automatically for this sender.',
                        event: 'email.trust_image_sender',
                        emailId: widget.emailId,
                        data: {'sender': senderEmail},
                        duration: const Duration(seconds: 3),
                        // SnackBar defaults to persist=true when an action is
                        // set, which disables the auto-dismiss timer. Explicitly
                        // opt back into duration-based dismiss.
                        persist: false,
                        action: SnackBarAction(
                          label: 'View',
                          onPressed: () {
                            if (mounted) {
                              unawaited(
                                context.push(
                                  '/accounts/trusted-senders',
                                  extra: senderEmail,
                                ),
                              );
                            }
                          },
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ErrorBoundary(
            label: 'Email body',
            child: SecureEmailWebView(
              htmlBody: body.htmlBody!,
              loadRemoteImages: effectiveLoadImages,
            ),
          ),
        ] else
          FoldableQuoteText(
            body.textBody ?? '',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
        if (body.attachments.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(
              'Attachments',
              style: Theme.of(ctx).textTheme.titleSmall,
            ),
          ),
          for (final att in body.attachments) _buildAttachment(ctx, att),
        ],
      ],
    );
  }

  /// Friendly fallback shown when the message can't be loaded at all (network,
  /// DB, …). A malformed body no longer lands here — it's decoded best-effort
  /// and shows the [_buildDecodeFailedNotice] banner instead (#579). The
  /// underlying error is logged in [EmailDetailNotifier.build] so it's still
  /// discoverable in the App Log; here we only offer a retry and raw view.
  Widget _buildLoadError(BuildContext ctx, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: AppIconSize.lg,
              color: Theme.of(ctx).colorScheme.error,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'This message could not be opened.',
              style: Theme.of(ctx).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              userErrorMessage(error),
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: AppIconSize.sm),
                  label: const Text('Retry'),
                  onPressed: () =>
                      ref.invalidate(emailDetailProvider(widget.emailId)),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.code, size: AppIconSize.sm),
                  label: const Text('View raw source'),
                  onPressed: () => unawaited(_showRaw(ctx, null)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Inline banner shown when the message body could only be decoded in part
  /// (a malformed MIME message that made the mail parser throw — #579). Offers
  /// a jump to the raw source so the user can still read the original.
  Widget _buildDecodeFailedNotice(BuildContext ctx, Email? header) {
    final scheme = Theme.of(ctx).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppSpacing.xs),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: AppIconSize.sm,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This message could not be fully displayed.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => unawaited(_showRaw(ctx, header)),
                  child: const Text('View raw source'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Inline banner shown when the body could not be loaded even though the
  /// message row (and its headers) exist — e.g. an IMAP Message-ID mismatch
  /// that couldn't be self-healed, which used to leave the body area silently
  /// blank (#837). Explains why and offers a retry plus a jump to the App Log
  /// where the underlying error was recorded.
  Widget _buildLoadFailedNotice(BuildContext ctx, String reason) {
    final scheme = Theme.of(ctx).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppSpacing.xs),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: AppIconSize.sm,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reason,
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () =>
                          ref.invalidate(emailDetailProvider(widget.emailId)),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => unawaited(
                        context.push(
                          '/accounts/app-log?emailId=${widget.emailId}',
                        ),
                      ),
                      child: const Text('Show logs'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<EmailDetailNavItem?> _getNextEmailIfNeeded(Email? header) async {
    if (header == null) return null;
    final action = await storedAfterMailViewAction(
      ref.read(userPreferencesRepositoryProvider),
    );
    if (!mounted || action != AfterMailViewAction.nextMessage) return null;

    // Prefer the caller-supplied nav so "next" respects the source list
    // (search results, address filter, …) and steps through individual mails
    // rather than jumping thread-by-thread across the whole mailbox (#292).
    final providedNav = widget.nav;
    if (providedNav != null && providedNav.items.isNotEmpty) {
      return providedNav.nextOf(widget.emailId);
    }

    // Fallback for deep links: walk this mailbox's individual mails, keeping
    // the historical guard that limits the hop to the same folder — the
    // stream shouldn't leak cross-folder rows, but a client-side filter still
    // matters when a mailbox rename briefly overlaps (#293).
    final emails = (await ref
            .read(emailRepositoryProvider)
            .observeEmails(header.accountId, header.mailboxPath)
            .first)
        .where((e) => e.mailboxPath == header.mailboxPath)
        .toList();

    final idx = emails.indexWhere((e) => e.id == widget.emailId);
    if (idx >= 0 && idx + 1 < emails.length) {
      final n = emails[idx + 1];
      return EmailDetailNavItem(
        accountId: n.accountId,
        mailboxPath: n.mailboxPath,
        emailId: n.id,
      );
    }
    return null;
  }

  void _navigateTo(
    BuildContext context,
    Email? header,
    EmailDetailNavItem? next,
  ) {
    if (!context.mounted) return;
    if (next != null) {
      context.go(
        '/accounts/${next.accountId}'
        '/mailboxes/${Uri.encodeComponent(next.mailboxPath)}'
        '/emails/${Uri.encodeComponent(next.emailId)}',
        extra: _steppedNav(),
      );
    } else {
      context.pop();
    }
  }

  /// Renders one attachment row. Image attachments Flutter can decode get an
  /// inline preview that loads automatically; everything else keeps the plain
  /// download-and-open tile.
  Widget _buildAttachment(BuildContext ctx, EmailAttachment att) {
    final downloading = _downloading.contains(att.filename);
    final downloadTrailing = downloading
        ? const SizedBox(
            width: AppIconSize.lg,
            height: AppIconSize.lg,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Desktop: save to a chosen folder — also the only way to get
              // at a file no installed app can open.
              if (supportsSaveAs)
                IconButton(
                  icon: const Icon(Icons.save_alt),
                  tooltip: 'Save as…',
                  onPressed: () => _saveAttachmentAs(att),
                ),
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Download and open',
                onPressed: () => _downloadAndOpen(att),
              ),
            ],
          );

    if (!isDisplayableImage(att.contentType)) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.attach_file),
        title: Text(att.filename),
        subtitle: Text('${att.contentType} • ${fmtSize(att.size)}'),
        trailing: downloadTrailing,
      );
    }

    final path = _imagePaths[att.filename];

    // Auto-load the preview the first time we see a displayable image that
    // hasn't been fetched yet — the user asked to see images directly rather
    // than after tapping a button (#802). Guarded so it fires once per image;
    // a failed fetch surfaces a Retry button instead of looping.
    if (path == null &&
        !downloading &&
        !_autoRequestedImages.contains(att.filename) &&
        !_imageLoadFailed.contains(att.filename) &&
        !_imageUnsupported.contains(att.filename)) {
      _autoRequestedImages.add(att.filename);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showImage(att));
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.image_outlined),
          title: Text(att.filename),
          subtitle: Text('${att.contentType} • ${fmtSize(att.size)}'),
          trailing: downloadTrailing,
        ),
        if (path != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: GestureDetector(
              onTap: () => _openImageViewer(att, path),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  errorBuilder: (context, error, stack) => Text(
                    'This image could not be displayed.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          )
        else if (downloading)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              bottom: AppSpacing.sm,
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: AppIconSize.sm,
                  height: AppIconSize.sm,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Loading image…',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          )
        else if (_imageUnsupported.contains(att.filename))
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              bottom: AppSpacing.sm,
            ),
            child: Text(
              'This image could not be displayed. Use download to open it.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          )
        else if (_imageLoadFailed.contains(att.filename))
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              bottom: AppSpacing.sm,
            ),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: AppIconSize.sm),
              label: const Text('Retry'),
              onPressed: () => _showImage(att),
            ),
          ),
      ],
    );
  }

  /// Downloads an image attachment's bytes and reveals its inline preview.
  Future<void> _showImage(EmailAttachment att) async {
    setState(() {
      _downloading.add(att.filename);
      _autoRequestedImages.add(att.filename);
      _imageLoadFailed.remove(att.filename);
      _imageUnsupported.remove(att.filename);
    });
    try {
      final path = await ref
          .read(emailRepositoryProvider)
          .downloadAttachment(widget.emailId, att);
      if (!mounted) return;
      // The declared MIME type got us this far, but the *decoded* bytes may not
      // actually be a format Flutter can render (mislabelled AVIF/HEIC/SVG, or
      // raw multipart bytes). Sniffing the on-disk signature closes the hole
      // where Image.file silently paints colour-noise without throwing (#830).
      final header = _readFileHeader(path);
      if (header == null || sniffImageFormat(header) == null) {
        setState(() => _imageUnsupported.add(att.filename));
        return;
      }
      setState(() => _imagePaths[att.filename] = path);
    } catch (e, stack) {
      if (!mounted) return;
      setState(() => _imageLoadFailed.add(att.filename));
      context.showAppSnackBar(
        'Loading image failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'email.attachment.open_failed',
        emailId: widget.emailId,
        data: {'filename': att.filename},
        error: e,
        stack: stack,
      );
    } finally {
      if (mounted) setState(() => _downloading.remove(att.filename));
    }
  }

  /// Reads the leading bytes of [path] for [sniffImageFormat]. Returns `null`
  /// if the file is missing or unreadable. 16 bytes cover every signature we
  /// check (the longest, WebP, needs 12). Reads synchronously — only 16 bytes,
  /// and it runs after the download has already completed.
  Uint8List? _readFileHeader(String path) {
    try {
      final raf = File(path).openSync();
      try {
        return raf.readSync(16);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  void _openImageViewer(EmailAttachment att, String path) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageViewerScreen(path: path, filename: att.filename),
      ),
    );
  }

  Future<void> _saveAttachmentAs(EmailAttachment att) async {
    await saveFileAs(
      context,
      picker: ref.read(saveLocationPickerProvider),
      filename: att.filename,
      emailId: widget.emailId,
      source: () async {
        if (mounted) setState(() => _downloading.add(att.filename));
        try {
          return await ref
              .read(emailRepositoryProvider)
              .downloadAttachment(widget.emailId, att);
        } finally {
          if (mounted) setState(() => _downloading.remove(att.filename));
        }
      },
    );
  }

  Future<void> _downloadAndOpen(EmailAttachment att) async {
    setState(() => _downloading.add(att.filename));
    try {
      final path = await ref
          .read(emailRepositoryProvider)
          .downloadAttachment(widget.emailId, att);
      final problem = await openFile(path);
      if (problem != null && mounted) {
        context.showAppSnackBar(
          problem.text,
          level: AppLogLevel.warn,
          event: 'email.attachment.open_failed',
          emailId: widget.emailId,
          data: {'filename': att.filename, 'detail': problem.detail},
        );
      }
    } catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Opening file failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'email.attachment.open_failed',
        emailId: widget.emailId,
        data: {'filename': att.filename},
        error: e,
        stack: stack,
      );
    } finally {
      if (mounted) setState(() => _downloading.remove(att.filename));
    }
  }

  Widget _buildNotesSection(BuildContext ctx, Email header) {
    final messageId = header.messageId!;
    final notes = ref.watch(
      conversationNotesProvider(
        (header.accountId, messageId, header.threadId),
      ),
    );
    final threadId = header.threadId;
    final threadEmails = threadId == null
        ? const <Email>[]
        : ref.watch(threadEmailsProvider((header.accountId, threadId))).value ??
            const <Email>[];
    final mode = ref.watch(notesModeProvider(header.accountId));
    final locked = mode == NotesMode.locked;
    final awaiting = legacyNotesAwaitingConfirmationProvider(header.accountId);
    final awaitingMigration =
        mode == NotesMode.entries ? ref.watch(awaiting).value ?? 0 : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                'Notes',
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('notesAdd'),
              icon: const Icon(Icons.add, size: AppIconSize.sm),
              label: const Text('Add'),
              // An encrypted account gets no new plaintext note (#1375).
              onPressed: locked
                  ? null
                  : () => unawaited(_addNoteDialog(ctx, header, mode)),
            ),
          ],
        ),
        if (locked)
          _notesHint(
            ctx,
            header.accountId,
            key: const Key('notesLockedHint'),
            text: 'Unlock personal data to add notes',
            action: 'Unlock',
          ),
        if (awaitingMigration > 0)
          _notesHint(
            ctx,
            header.accountId,
            key: const Key('notesMigrationHint'),
            text: 'Older notes are not encrypted yet',
            action: 'Review',
          ),
        notes.when(
          // conversationNotesProvider is fed by threadEmailsProvider, a drift
          // .watch() that re-emits on every write to the emails table — so it
          // resubscribes (passing through AsyncLoading) constantly while a sync
          // runs. skipLoadingOnReload keeps the current notes on screen through
          // those reloads; without it the section collapsed to zero height and
          // back, shifting the HTML body below it up and down, which read as
          // the single-mail view blinking (#1053). (skipLoadingOnRefresh
          // already defaults to true in Riverpod, so it is not set here.)
          skipLoadingOnReload: true,
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Text('Error loading notes: ${userErrorMessage(e)}'),
          data: (list) {
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  'No notes yet.',
                  style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              );
            }
            return Column(
              children: [
                for (final note in list)
                  _buildNoteRow(
                    ctx,
                    note,
                    header,
                    threadEmails,
                    locked: locked,
                  ),
              ],
            );
          },
        ),
        const Divider(),
      ],
    );
  }

  /// A line under the notes header leading to the personal-data screen
  /// (#1375).
  Widget _notesHint(
    BuildContext ctx,
    String accountId, {
    required Key key,
    required String text,
    required String action,
  }) =>
      Row(
        key: key,
        children: [
          Icon(
            Icons.lock_outline,
            size: AppIconSize.sm,
            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(text, style: Theme.of(ctx).textTheme.bodySmall),
          ),
          TextButton(
            onPressed: () => unawaited(
              GoRouter.of(ctx).push('/accounts/$accountId/personal-data'),
            ),
            child: Text(action),
          ),
        ],
      );

  /// While [locked], an entry's tick is off and deleting it asks to unlock.
  Widget _buildNoteRow(
    BuildContext ctx,
    LinkedNote note,
    Email header,
    List<Email> threadEmails, {
    required bool locked,
  }) {
    final created = DateFormat('MMM d, HH:mm').format(note.createdAt);
    final base = note.messageId == header.messageId
        ? created
        : '$created · ${_relatedMailLabel(note.messageId, threadEmails)}';
    // Saved locally; it goes to the server on the next successful sync.
    final task = note.task;
    final due = task?.due;
    final dated = due == null ? base : '$base · due $due';
    final subtitle = switch (note) {
      LinkedNote(pendingUpload: true) => '$dated · not synced yet',
      LinkedNote(hasConflict: true) => '$dated · conflict',
      _ => dated,
    };
    return ListTile(
      key: Key('note-${note.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: task == null
          ? null
          : Checkbox(
              key: Key('noteTodoDone-${note.id}'),
              value: task.done,
              onChanged: locked
                  ? null
                  : (done) =>
                      unawaited(_setLinkedTodoDone(note, task, done ?? false)),
            ),
      title: Text(
        note.text,
        style: task?.done ?? false
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        subtitle,
        style: Theme.of(ctx).textTheme.bodySmall,
      ),
      onTap: note.isEntry
          ? () => unawaited(
                GoRouter.of(ctx)
                    .push('/accounts/${note.accountId}/entries/${note.id}'),
              )
          : null,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: AppIconSize.md),
        tooltip: 'Delete note',
        onPressed: () => unawaited(_deleteNote(note, locked: locked)),
      ),
    );
  }

  /// Ticks or unticks the todo [note] from the mail; saved at once, like
  /// in the Todos tab.
  Future<void> _setLinkedTodoDone(
    LinkedNote note,
    EntryTask task,
    bool done,
  ) async {
    try {
      await ref
          .read(entryRepositoryProvider)
          .setTask(note.accountId, note.id, task.copyWith(done: done));
    } on NoWriteKeyException {
      if (!mounted) return;
      context.showAppSnackBar('Unlock personal data to tick this todo');
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    }
  }

  Future<void> _deleteNote(LinkedNote note, {required bool locked}) async {
    if (!note.isEntry) {
      await ref.read(noteRepositoryProvider).deleteNote(note.id);
      return;
    }
    if (locked) {
      context.showAppSnackBar('Unlock personal data to delete this note');
      return;
    }
    // An encrypted entry may be a todo or a long text, and deleting it
    // cannot be undone: ask first, like the Entries tab does.
    final first = note.text.split('\n').first.trim();
    final confirmed = await showConfirmDelete(
      context,
      title: note.task == null ? 'Delete note?' : 'Delete todo?',
      content: first.isEmpty ? 'Delete it?' : 'Delete "$first"?',
      confirmKey: const Key('noteDeleteConfirm'),
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(entryRepositoryProvider).delete(note.accountId, note.id);
    } on NoWriteKeyException {
      if (!mounted) return;
      context.showAppSnackBar('Unlock personal data to delete this note');
    }
  }

  /// Names the related mail of the conversation a note belongs to (#870),
  /// e.g. "on mail from Alice, Mar 3, 10:15".
  String _relatedMailLabel(String messageId, List<Email> threadEmails) {
    final mail =
        threadEmails.where((e) => e.messageId == messageId).firstOrNull;
    if (mail == null) return 'on related mail';
    final from = mail.from.firstOrNull;
    final name = from?.name;
    final sender = from == null
        ? ''
        : ' from ${name != null && name.isNotEmpty ? name : from.email}';
    final sent = DateFormat('MMM d, HH:mm').format(mail.date);
    return 'on mail$sender, $sent';
  }

  /// Adds a note to [header]: an encrypted entry linked to the mail when
  /// the account's notes are entries, else a plaintext note (#1375).
  Future<void> _addNoteDialog(
    BuildContext context,
    Email header,
    NotesMode? mode,
  ) async {
    final messageId = header.messageId;
    if (messageId == null) return;

    final text = await showTextPrompt(
      context,
      title: 'Add note',
      hintText: 'Type a note…',
      // A plaintext note: say so, every time (crypto review, M1/F5). A
      // device that never saw this account's key mails cannot tell a
      // hidden keys folder from an account without encryption.
      helperText: mode == NotesMode.entries
          ? null
          : 'Stored unencrypted on your mail server. Set up "Personal data" '
              'for this account to encrypt notes.',
      confirmLabel: 'Save',
      maxLines: 4,
    );
    if (text == null) return;
    if (!context.mounted) return;

    try {
      if (mode == NotesMode.entries) {
        await ref.read(entryRepositoryProvider).create(
          header.accountId,
          body: text,
          links: [messageId],
        );
        return;
      }
      await ref.read(noteRepositoryProvider).addNote(
            header.accountId,
            messageId,
            text,
          );
    } on NotesEncryptedException {
      if (!context.mounted) return;
      context.showAppSnackBar('Unlock personal data to add notes');
    } on NoWriteKeyException {
      if (!context.mounted) return;
      context.showAppSnackBar('Unlock personal data to add notes');
    }
  }

  /// One "To:"/"Cc:"/"Bcc:" header line. Capped so a mail to dozens of
  /// people does not push the body off screen; the full lists are in
  /// "Show Mail Headers". [empty] is shown when [addresses] is empty.
  Widget _recipientLine(
    BuildContext ctx,
    String label,
    List<EmailAddress> addresses, {
    String empty = '',
  }) =>
      Text(
        '$label: ${addresses.isEmpty ? empty : addresses.join(', ')}',
        style: Theme.of(ctx).textTheme.bodySmall,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );

  Widget _buildHeader(BuildContext ctx, Email email) {
    if (email.from.isEmpty || email.to.isEmpty) {
      unawaited(
        ref.read(appLoggerProvider).warn(
          'email.header.missing_addresses',
          'Email has empty from/to on open',
          accountId: email.accountId,
          emailId: email.id,
          data: {
            'fromEmpty': email.from.isEmpty,
            'toEmpty': email.to.isEmpty,
          },
        ),
      );
    }
    // Resolve the containing folder's human-readable path the same way the
    // list tile does (#288), so the header can show it next to the date (#693).
    final mailbox = ref
        .watch(mailboxByPathProvider((email.accountId, email.mailboxPath)))
        .value;
    final folderLabel = mailbox?.displayPath ?? email.mailboxPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          email.subject ?? '(no subject)',
          style: Theme.of(ctx).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        if (email.from.isNotEmpty)
          // Tapping the sender opens advanced search pre-filled with a
          // from/to/cc OR-contains filter on the address, so you can find every
          // mail involving this correspondent (#796).
          InkWell(
            onTap: () => context.push(
              '/search',
              extra: senderFilterFor(email),
            ),
            child: Text(
              'From: ${email.from.first}',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: Theme.of(ctx).colorScheme.primary,
                  ),
            ),
          )
        else
          Text(
            'From: (unknown)',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        _recipientLine(ctx, 'To', email.to, empty: '(no recipients)'),
        if (email.cc.isNotEmpty) _recipientLine(ctx, 'Cc', email.cc),
        // Only known for mail you sent; never shown to other recipients.
        if (email.bcc.isNotEmpty) _recipientLine(ctx, 'Bcc', email.bcc),
        Row(
          children: [
            // Flexible: the date led this row unconstrained, taking its
            // intrinsic width. Measured at text scale 2.0 on a 320dp screen
            // it renders 270.6px wide inside a 288px row, leaving ~9px for
            // the folder label after the gap — the label is already starved,
            // and a slightly narrower screen or larger scale overflows.
            Flexible(
              child: Text(
                _dateFmt.format(email.date),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            if (folderLabel.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  folderLabel,
                  style: Theme.of(ctx)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(ctx).hintColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        ConversationTree(email: email, onTapEmail: _goToNeighbour),
        // Gate on the parsed result, not just header presence, so the detail
        // view and the chip agree — otherwise a header we can't turn into a URI
        // renders an invisible chip (#698).
        if (parseListUnsubscribeUris(email.listUnsubscribeHeader).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _UnsubscribeChip(email: email),
          ),
      ],
    );
  }

  Future<String> _quotedBody(Email header, EmailBody? body) async {
    final date = _dateFmt.format(header.date);
    final from =
        header.from.isNotEmpty ? header.from.first.toString() : '(unknown)';
    final rawText = body?.textBody;
    final text = (rawText != null && rawText.isNotEmpty)
        ? rawText
        : await compute(htmlToPlain, body?.htmlBody ?? '');
    final quoted = quoteText(text);
    return '\n\n— On $date, $from wrote:\n$quoted';
  }

  Future<void> _replyWithRecipientDialog(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    final account =
        await ref.read(accountRepositoryProvider).getAccount(header.accountId);
    final candidates = [
      for (final r in replyRecipients(
        ownEmail: account?.email ?? '',
        from: header.from,
        to: header.to,
        cc: header.cc,
        replyTo: header.replyTo,
      ))
        _Candidate(r.address, r.isCc ? _Placement.cc : _Placement.to),
    ];

    if (!context.mounted) return;

    if (candidates.length <= 1) {
      final to = candidates
          .where((c) => c.placement == _Placement.to)
          .map((c) => c.address.email)
          .join(', ');
      final cc = candidates
          .where((c) => c.placement == _Placement.cc)
          .map((c) => c.address.email)
          .join(', ');
      await _composeReply(context, header, body, to: to, cc: cc);
      return;
    }

    final confirmed = await showDialog<List<_Candidate>>(
      context: context,
      builder: (ctx) => _ReplyAllDialog(candidates: candidates),
    );

    if (confirmed == null || !context.mounted) return;

    final to = confirmed
        .where((c) => c.placement == _Placement.to)
        .map((c) => c.address.email)
        .join(', ');
    final cc = confirmed
        .where((c) => c.placement == _Placement.cc)
        .map((c) => c.address.email)
        .join(', ');
    await _composeReply(context, header, body, to: to, cc: cc);
  }

  Future<void> _composeReply(
    BuildContext context,
    Email header,
    EmailBody? body, {
    required String to,
    required String cc,
  }) async {
    // [header] was captured at the tap. Prev/Next since then (e.g. while the
    // account was read) swapped in another mail: do not mix the two.
    final emailId = header.id;
    if (widget.emailId != emailId) return;
    final subject = (header.subject?.startsWith('Re:') ?? false)
        ? header.subject!
        : 'Re: ${header.subject ?? ''}';
    // Tapped while the body still loads: wait for it, so the reply quotes it.
    final loaded = await _awaitLoadingBody(emailId, body);
    if (!context.mounted || widget.emailId != emailId) return;
    // Without the body there is nothing to quote: reply anyway, unquoted,
    // and say so rather than quoting an empty text (#1330).
    final quoted = _explainBodyMissing(
      loaded,
      message: 'The message body is not available, so the reply does not '
          'quote it.',
    )
        ? ''
        : await _quotedBody(header, loaded);
    if (!context.mounted) return;
    unawaited(
      context.push(
        '/compose',
        extra: {
          // Answer from the account the mail arrived in. Without it Compose
          // only picks an account when there is exactly one.
          'accountId': header.accountId,
          'replyToEmailId': emailId,
          'prefillTo': to,
          'prefillSubject': subject,
          'prefillBody': quoted,
          if (cc.isNotEmpty) 'prefillCc': cc,
        },
      ),
    );
  }

  Future<void> _archive(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'archive',
      folderKind: 'archive',
      createFolderName: 'Archive',
    );

    if (mailbox == null || !context.mounted) return;

    final ops = await _moveCapturingOps('Archiving…', mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
              destinationMailboxRole: 'archive',
              originalEmails: [header],
              opSeqs: ops,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  Future<void> _markAsSpam(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'junk',
      folderKind: 'spam',
      createFolderName: 'Junk',
    );

    if (mailbox == null || !context.mounted) return;

    final ops = await _moveCapturingOps('Marking as spam…', mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
              destinationMailboxRole: 'junk',
              originalEmails: [header],
              opSeqs: ops,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  /// Moves the open message back to its account's inbox. Backs the "Not junk"
  /// and "Restore" actions shown when the mail is being viewed from the Junk
  /// or Trash folder.
  Future<void> _moveToInbox(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final mailbox = await resolveMailboxByRole(
      context,
      ref.read(mailboxRepositoryProvider),
      header.accountId,
      header.mailboxPath,
      'inbox',
      folderKind: 'inbox',
      createFolderName: 'Inbox',
    );

    if (mailbox == null || !context.mounted) return;

    final ops = await _moveCapturingOps('Moving to Inbox…', mailbox.path);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: mailbox.path,
              destinationMailboxRole: 'inbox',
              originalEmails: [header],
              opSeqs: ops,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  /// True while a Reply or Forward prepares Compose, so a second tap does
  /// not start a second wait or download loop and a second Compose.
  bool _composing = false;

  /// Runs [prepare] unless a Reply/Forward or a dimmed action is running.
  Future<void> _composeOnce(Future<void> Function() prepare) async {
    if (_composing || _actionInFlight != null) return;
    _composing = true;
    try {
      await prepare();
    } finally {
      _composing = false;
    }
  }

  Future<void> _forward(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) =>
      _composeOnce(() => _prepareForward(context, header, body));

  Future<void> _prepareForward(
    BuildContext context,
    Email header,
    EmailBody? body,
  ) async {
    // Captured once: Prev/Next can swap in another mail (same State) while
    // the downloads run, and they must still come from this one.
    final emailId = header.id;
    if (widget.emailId != emailId) return;
    final subject = (header.subject?.startsWith('Fwd:') ?? false)
        ? header.subject!
        : 'Fwd: ${header.subject ?? ''}';
    // Tapped while the body still loads: wait for it, as Reply does (#1347).
    final loaded = await _awaitLoadingBody(emailId, body);
    if (!context.mounted || widget.emailId != emailId) return;
    if (_explainBodyMissing(loaded)) return;
    final quoted = await _quotedBody(header, loaded);
    if (!context.mounted) return;
    final attachments = loaded?.attachments ?? const <EmailAttachment>[];
    final downloaded = attachments.isEmpty
        ? (paths: const <String>[], failed: const <String>[])
        : await _runDimmed(
            'Downloading attachments…',
            () => _downloadForForward(emailId, header, attachments),
          );
    if (!context.mounted) return;
    if (downloaded.failed.isNotEmpty) {
      context.showAppSnackBar(
        'Could not attach: ${downloaded.failed.join(', ')}',
        level: AppLogLevel.warn,
        event: 'email.forward.attachments_missing',
        emailId: emailId,
        data: {'failed': downloaded.failed.length},
        duration: const Duration(seconds: 8),
      );
    }
    unawaited(
      context.push(
        '/compose',
        extra: {
          'accountId': header.accountId,
          'prefillSubject': subject,
          'prefillBody': quoted,
          if (downloaded.paths.isNotEmpty)
            'prefillAttachmentPaths': downloaded.paths,
        },
      ),
    );
  }

  /// Downloads [attachments] of [emailId] one after the other (each IMAP
  /// download opens its own connection) for a forward. Returns the local
  /// paths and the names of those that failed. Parts without a file name
  /// are skipped.
  Future<({List<String> paths, List<String> failed})> _downloadForForward(
    String emailId,
    Email header,
    List<EmailAttachment> attachments,
  ) async {
    final repo = ref.read(emailRepositoryProvider);
    final logger = ref.read(appLoggerProvider);
    final paths = <String>[];
    final failed = <String>[];
    for (final att in attachments) {
      if (att.filename.isEmpty) {
        unawaited(
          logger.warn(
            'email.forward.attachment_skipped',
            'Attachment without a file name not forwarded',
            accountId: header.accountId,
            emailId: emailId,
            data: {'partId': att.fetchPartId, 'contentType': att.contentType},
          ),
        );
        continue;
      }
      try {
        final path = await repo.downloadAttachment(emailId, att);
        if (paths.contains(path)) {
          // The cache keeps one file per part, so this should not happen;
          // if it does, attaching the file twice would not help either.
          unawaited(
            logger.warn(
              'email.forward.attachment_deduplicated',
              'Two attachments resolved to the same file; attached once',
              accountId: header.accountId,
              emailId: emailId,
              data: {'filename': att.filename, 'partId': att.fetchPartId},
            ),
          );
          continue;
        }
        paths.add(path);
      } catch (e, stack) {
        failed.add(att.filename);
        unawaited(
          logger.error(
            'email.forward.attachment_failed',
            'Could not download an attachment to forward',
            accountId: header.accountId,
            emailId: emailId,
            data: {'filename': att.filename},
            error: e,
            stack: stack,
          ),
        );
      }
    }
    return (paths: paths, failed: failed);
  }

  Future<void> _moveTo(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);

    final mailboxRepo = ref.read(mailboxRepositoryProvider);
    final mailboxes =
        await mailboxRepo.observeMailboxes(header.accountId).first;

    // Remove the current mailbox from the list.
    final destinations =
        mailboxes.where((m) => m.path != header.mailboxPath).toList();

    if (!context.mounted) return;

    const createNewSentinel = '__create_new__';

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              'Move to…',
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          for (final m in destinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(m.name),
              onTap: () => Navigator.pop(ctx, m.path),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Create new folder…'),
            onTap: () => Navigator.pop(ctx, createNewSentinel),
          ),
        ],
      ),
    );

    if (chosen == null || !context.mounted) return;

    String destination = chosen;
    if (chosen == createNewSentinel) {
      final name = await showTextPrompt(
        context,
        title: 'Create new folder',
        hintText: 'Folder name',
        confirmLabel: 'Create',
        textCapitalization: TextCapitalization.words,
      );
      if (name == null || !context.mounted) return;
      // "Projects/2026" creates 2026 inside Projects on IMAP and JMAP alike;
      // a malformed name ("a//b") or a server refusal lands here.
      try {
        final mailbox = await mailboxRepo.createMailbox(header.accountId, name);
        destination = mailbox.path;
      } catch (e, stack) {
        if (!context.mounted) return;
        context.showAppSnackBar(
          'Could not create folder: ${userErrorMessage(e)}',
          level: AppLogLevel.error,
          event: 'email.move.create_folder_failed',
          emailId: widget.emailId,
          data: {'name': name},
          error: e,
          stack: stack,
        );
        return;
      }
    }

    final ops = await _moveCapturingOps('Moving…', destination);

    unawaited(
      ref.read(undoServiceProvider.notifier).pushAction(
            UndoAction(
              id: DateTime.now().toIso8601String(),
              accountId: header.accountId,
              type: UndoType.move,
              emailIds: [widget.emailId],
              sourceMailboxPath: header.mailboxPath,
              destinationMailboxPath: destination,
              originalEmails: [header],
              opSeqs: ops,
            ),
          ),
    );

    if (context.mounted) _navigateTo(context, header, nextEmail);
  }

  /// Creates a `From is` notification rule for this mail's sender on its
  /// account and turns notifications on if they were off, so future mail from
  /// the sender pops up. Confirms with an undoable snackbar.
  Future<void> _notifyForSender(BuildContext context, Email header) async {
    if (header.from.isEmpty) return;
    final sender = header.from.first.email;
    if (sender.isEmpty) return;

    final accountRepo = ref.read(accountRepositoryProvider);
    final ruleRepo = ref.read(notificationRuleRepositoryProvider);
    final account = await accountRepo.getAccount(header.accountId);
    if (account == null) return;

    if (!account.notificationsEnabled) {
      await ruleRepo.markBaseline(header.accountId);
      await accountRepo.updateAccount(
        account.copyWith(notificationsEnabled: true),
      );
    }
    final filter = FilterGroup.single(
      FilterField.from_,
      FilterComparison.is_,
      sender,
    );
    final ruleId = await ruleRepo.addRule(header.accountId, filter);

    if (!context.mounted) return;
    context.showAppSnackBar(
      'You will be notified for mail from $sender',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => ruleRepo.deleteRule(ruleId),
      ),
    );
  }

  /// Moves the open message to [dest] behind the dimmed [label], returning
  /// the queued changes for its undo action ([UndoAction.opSeqs]).
  Future<Map<String, List<int>>> _moveCapturingOps(
    String label,
    String dest,
  ) async {
    var ops = const <String, List<int>>{};
    await _runDimmed(label, () async {
      final repo = ref.read(emailRepositoryProvider);
      ops = (await repo.captureOps(
        () => repo.moveEmail(widget.emailId, dest),
      ))
          .$2;
    });
    return ops;
  }

  /// Creates a todo for [header] in its account, titled by the subject and
  /// linked by its Message-ID (#1357).
  Future<void> _createTodo(BuildContext context, Email header) async {
    final messageId = header.messageId;
    if (messageId == null) return;
    final router = GoRouter.of(context);
    try {
      final todo = await ref.read(entryRepositoryProvider).create(
        header.accountId,
        title: header.subject,
        body: '',
        task: const EntryTask(),
        links: [messageId],
      );
      if (!context.mounted) return;
      context.showAppSnackBar(
        'Todo created',
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => unawaited(
            router.push('/accounts/${header.accountId}/entries/${todo.itemId}'),
          ),
        ),
      );
    } on NoWriteKeyException {
      if (!context.mounted) return;
      context.showAppSnackBar('Unlock personal data to add todos.');
    }
  }

  Future<void> _snooze(BuildContext context, Email header) async {
    final nextEmail = await _getNextEmailIfNeeded(header);
    if (!context.mounted) return;

    final until = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (ctx) => const SnoozePicker(),
    );
    if (until == null || !context.mounted) return;

    final repo = ref.read(emailRepositoryProvider);
    // Read before the await: the screen may be gone when it returns.
    final undo = ref.read(undoServiceProvider.notifier);
    var ops = const <String, List<int>>{};
    await _runDimmed('Snoozing…', () async {
      ops = (await repo.captureOps(
        () => repo.snoozeEmail(widget.emailId, until),
      ))
          .$2;
    });
    final action = UndoAction(
      id: DateTime.now().toIso8601String(),
      accountId: header.accountId,
      type: UndoType.snooze,
      emailIds: [widget.emailId],
      sourceMailboxPath: header.mailboxPath,
      originalEmails: [header],
      opSeqs: ops,
    );
    unawaited(undo.pushAction(action));

    if (context.mounted) {
      context.showAppSnackBar(
        'Snoozed until ${DateFormat('MMM d, HH:mm').format(until)}',
        event: 'email.snooze',
        emailId: widget.emailId,
        accountId: header.accountId,
        mailboxPath: header.mailboxPath,
        duration: const Duration(seconds: 5),
      );
      _navigateTo(context, header, nextEmail);
    }
  }

  /// Shows the message body as selectable plain text.
  ///
  /// Native text selection inside the HTML [SecureEmailWebView] is unreliable
  /// when the WebView is embedded in the scrollable detail screen (#707), so
  /// this offers a deterministic way to select and copy the body on every
  /// platform. HTML is stripped to plain text via [htmlToPlain]; text-only
  /// messages are shown as-is.
  ///
  /// With [cardsIn] (an account, while "Personal data (beta)" is on) it also
  /// offers "Create card": the selection (or the whole text) becomes the
  /// back of a new flash card in that account (#1381).
  void _showSelectText(
    BuildContext context,
    EmailBody body, {
    String? cardsIn,
  }) {
    final html = body.htmlBody;
    final text = html != null && html.trim().isNotEmpty
        ? htmlToPlain(html)
        : (body.textBody ?? '');
    if (text.trim().isEmpty) {
      context.showAppSnackBar(
        'This message has no text to select.',
        event: 'email.select_text.empty',
        emailId: widget.emailId,
      );
      return;
    }

    var selected = '';
    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select text'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                key: const Key('selectTextBody'),
                style: Theme.of(ctx).textTheme.bodyMedium,
                onSelectionChanged: (selection, _) =>
                    selected = selection.textInside(text),
              ),
            ),
          ),
          actions: [
            if (cardsIn != null)
              TextButton(
                key: const Key('selectTextCreateCard'),
                onPressed: () {
                  final back = selected.trim().isEmpty ? text : selected;
                  Navigator.pop(ctx);
                  unawaited(
                    addCardWithDialog(
                      context,
                      ref,
                      accountId: cardsIn,
                      back: back.trim(),
                    ),
                  );
                },
                child: const Text('Create card'),
              ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (ctx.mounted) {
                  ctx.showAppSnackBar(
                    'Copied to clipboard',
                    event: 'email.select_text.copied',
                    emailId: widget.emailId,
                  );
                }
              },
              child: const Text('Copy all'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRaw(BuildContext context, Email? header) async {
    final String raw;
    try {
      raw = await ref
          .read(emailRepositoryProvider)
          .fetchRawRfc822(widget.emailId);
    } catch (e, stack) {
      if (!context.mounted) return;
      context.showAppSnackBar(
        'Failed to fetch raw email: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'email.raw.fetch_failed',
        accountId: header?.accountId,
        emailId: widget.emailId,
        error: e,
        stack: stack,
      );
      return;
    }

    if (!context.mounted) return;

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Raw Email'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fmtSize(raw.length),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      raw,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: raw));
                if (ctx.mounted) {
                  ctx.showAppSnackBar(
                    'Copied to clipboard',
                    event: 'email.raw.copied',
                    emailId: widget.emailId,
                  );
                }
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () async {
                await _downloadRaw(ctx, header, raw);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Download'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadRaw(
    BuildContext context,
    Email? header,
    String raw,
  ) async {
    try {
      final filename = rawEmailFilename(header?.subject);
      final saved = await saveRawEmail(filename: filename, content: raw);
      if (!context.mounted) return;
      // The snack bar outlives this context, so capture the messenger now.
      final messenger = context.appMessenger();
      // On platforms that wrote to a public, system-indexed location
      // (Android Downloads), offer "Open" — opening the file is what makes
      // it appear in the system file picker's "Recently used" list.
      // Elsewhere fall back to "Share" so the user can still hand the file
      // off to another app.
      final action = saved.isPublic
          ? SnackBarAction(
              label: 'Open',
              onPressed: () async {
                final problem = await openFile(saved.path);
                if (problem != null) {
                  messenger.show(
                    problem.text,
                    level: AppLogLevel.warn,
                    event: 'email.raw.open_failed',
                    accountId: header?.accountId,
                    emailId: widget.emailId,
                    data: {'detail': problem.detail},
                  );
                }
              },
            )
          : SnackBarAction(
              label: 'Share',
              onPressed: () => SharePlus.instance.share(
                ShareParams(files: [XFile(saved.path)]),
              ),
            );
      context.showAppSnackBar(
        'Saved ${saved.displayLocation}',
        event: 'email.raw.download',
        accountId: header?.accountId,
        emailId: widget.emailId,
        // SnackBar defaults to persist=true when an action is set, which
        // disables the auto-dismiss timer. Explicitly opt back into
        // duration-based dismiss so the "Saved" snack bar slides away on its
        // own while the Open/Share action button still works.
        persist: false,
        action: action,
      );
    } catch (e, stack) {
      if (!context.mounted) return;
      context.showAppSnackBar(
        'Download failed: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'email.raw.download_failed',
        accountId: header?.accountId,
        emailId: widget.emailId,
        error: e,
        stack: stack,
      );
    }
  }

  /// Forces a fresh fetch of the body from the server, bypassing the local
  /// cache. Used when the cached row is missing fields (headers, mimeTree)
  /// that earlier sync versions did not store. Shows a progress snackbar
  /// while the fetch is in flight and returns null on error.
  Future<EmailBody?> _refetchBody(BuildContext context) async {
    final messenger = context.appMessenger();
    final controller = messenger.show(
      'Fetching mail details…',
      event: 'email.body.refetch',
      emailId: widget.emailId,
      duration: const Duration(minutes: 1),
      content: const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: AppSpacing.sm),
          Text('Fetching mail details…'),
        ],
      ),
    );
    try {
      return await ref
          .read(emailRepositoryProvider)
          .getEmailBody(widget.emailId, forceRefresh: true);
    } catch (e, stack) {
      if (context.mounted) {
        messenger.show(
          'Failed to fetch mail details: ${userErrorMessage(e)}',
          level: AppLogLevel.error,
          event: 'email.body.refetch_failed',
          emailId: widget.emailId,
          error: e,
          stack: stack,
        );
      }
      return null;
    } finally {
      controller.close();
    }
  }

  Future<void> _showHeaders(
    BuildContext context,
    EmailBody body,
    String accountId,
  ) async {
    var effective = body;
    if (effective.headers.isEmpty) {
      effective = await _refetchBody(context) ?? effective;
      if (!context.mounted) return;
      if (effective.headers.isEmpty) {
        context.showAppSnackBar(
          'Server did not return headers for this message.',
          level: AppLogLevel.warn,
          event: 'email.headers.missing',
          emailId: widget.emailId,
          duration: const Duration(seconds: 5),
        );
        return;
      }
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => EmailHeadersDialog(
          headers: effective.headers,
          accountId: accountId,
        ),
      ),
    );
  }

  Future<void> _showStructure(BuildContext context, EmailBody body) async {
    var effective = body;
    var tree = effective.mimeTree;
    if (tree == null) {
      effective = await _refetchBody(context) ?? effective;
      if (!context.mounted) return;
      tree = effective.mimeTree;
      if (tree == null) {
        context.showAppSnackBar(
          'Server did not return MIME structure for this message.',
          level: AppLogLevel.warn,
          event: 'email.structure.missing',
          emailId: widget.emailId,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'View raw email',
            onPressed: () {
              unawaited(_showRaw(context, null));
            },
          ),
        );
        return;
      }
    }

    final rows = <_MimeRow>[];
    _flattenMimeTree(tree, 0, rows);

    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Mail Structure'),
              leading: const CloseButton(),
            ),
            body: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (ctx, i) {
                final row = rows[i];
                return Container(
                  color: i.isEven
                      ? Theme.of(ctx).colorScheme.surfaceContainerHighest
                      : Theme.of(ctx).colorScheme.surface,
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.xs,
                    horizontal: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: row.depth * AppSpacing.lg),
                      Expanded(
                        child: Text(
                          row.label,
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

enum _Placement { to, cc, skip }

class _Candidate {
  _Candidate(this.address, this.placement);
  final EmailAddress address;
  _Placement placement;
}

class _ReplyAllDialog extends StatefulWidget {
  const _ReplyAllDialog({required this.candidates});
  final List<_Candidate> candidates;

  @override
  State<_ReplyAllDialog> createState() => _ReplyAllDialogState();
}

class _ReplyAllDialogState extends State<_ReplyAllDialog> {
  late final List<_Candidate> _candidates;

  @override
  void initState() {
    super.initState();
    _candidates = [
      for (final c in widget.candidates) _Candidate(c.address, c.placement),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reply All'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in _candidates)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.address.toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SegmentedButton<_Placement>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _Placement.to, label: Text('To')),
                        ButtonSegment(value: _Placement.cc, label: Text('Cc')),
                        ButtonSegment(
                          value: _Placement.skip,
                          label: Text('Skip'),
                        ),
                      ],
                      selected: {c.placement},
                      onSelectionChanged: (s) =>
                          setState(() => c.placement = s.first),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _candidates),
          child: const Text('Reply'),
        ),
      ],
    );
  }
}

class _MimeRow {
  const _MimeRow(this.depth, this.label);
  final int depth;
  final String label;
}

void _flattenMimeTree(MimePart part, int depth, List<_MimeRow> out) {
  final parts = <String>[part.contentType];
  if (part.filename != null) parts.add('"${part.filename}"');
  if (part.size != null) parts.add(fmtSize(part.size!));
  if (part.encoding != null) parts.add(part.encoding!);
  out.add(_MimeRow(depth, parts.join('  ')));
  for (final child in part.children) {
    _flattenMimeTree(child, depth + 1, out);
  }
}

class _UnsubscribeChip extends ConsumerStatefulWidget {
  const _UnsubscribeChip({required this.email});
  final Email email;

  @override
  ConsumerState<_UnsubscribeChip> createState() => _UnsubscribeChipState();
}

class _UnsubscribeChipState extends ConsumerState<_UnsubscribeChip> {
  bool _sending = false;

  /// Set once an unsubscribe mail is in the outbox, which sends (and
  /// retries) it even after Send stopped waiting: a second tap must not
  /// queue a second one (#1351). Cleared when the server refused it.
  bool _requested = false;

  @override
  void didUpdateWidget(covariant _UnsubscribeChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Prev/Next reuses this State for another mail.
    if (oldWidget.email.id != widget.email.id) _requested = false;
  }

  Future<void> _onTap(BuildContext context, List<Uri> uris) async {
    final chosen = uris.length == 1
        ? await _confirmSingle(context, uris.single)
        : await _chooseFromMany(context, uris);
    if (chosen == null) return;
    if (!context.mounted) return;

    if (chosen.scheme == 'mailto') {
      await _sendUnsubscribeEmail(context, chosen);
      return;
    }

    final ok = await launchUrl(chosen, mode: LaunchMode.externalApplication);
    if (ok || !context.mounted) return;
    context.showAppSnackBar(
      'Could not open unsubscribe link',
      level: AppLogLevel.warn,
      event: 'email.unsubscribe.open_failed',
      accountId: widget.email.accountId,
      emailId: widget.email.id,
    );
  }

  Future<Uri?> _confirmSingle(BuildContext context, Uri uri) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: Text(_describe(uri)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unsubscribe'),
          ),
        ],
      ),
    );
    return confirmed == true ? uri : null;
  }

  Future<Uri?> _chooseFromMany(BuildContext context, List<Uri> uris) {
    return showDialog<Uri>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final uri in uris)
                ListTile(
                  leading: Icon(_iconFor(uri)),
                  title: Text(_actionLabel(uri)),
                  subtitle: Text(_target(uri)),
                  onTap: () => Navigator.pop(ctx, uri),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  static String _describe(Uri uri) {
    return uri.scheme == 'mailto'
        ? 'Send an unsubscribe email to:\n${uri.path}'
        : 'Open the unsubscribe page:\n$uri';
  }

  static String _actionLabel(Uri uri) {
    return uri.scheme == 'mailto'
        ? 'Send unsubscribe email'
        : 'Open unsubscribe page';
  }

  static String _target(Uri uri) =>
      uri.scheme == 'mailto' ? uri.path : uri.toString();

  static IconData _iconFor(Uri uri) =>
      uri.scheme == 'mailto' ? Icons.email_outlined : Icons.open_in_new;

  /// Static, like [_showUnsubscribeResult]: also called once the send ended
  /// in the background, when this chip may be gone.
  static void _showUnsubscribeQueued(
    AppMessenger messenger,
    Email email,
    String? reason, {
    Object? error,
    StackTrace? stack,
  }) {
    messenger.show(
      reason == null || reason.isEmpty
          ? 'Unsubscribe email queued, it will be sent shortly'
          : 'Unsubscribe email queued, will retry: $reason',
      level: AppLogLevel.warn,
      event: 'email.unsubscribe.queued',
      accountId: email.accountId,
      emailId: email.id,
      error: error,
      stack: stack,
    );
  }

  /// Reports how the unsubscribe send to [email]'s list ended. Uses only
  /// [messenger] (the app's), so it also works once the send finished in the
  /// background and this chip is gone (#1351).
  static void _showUnsubscribeResult(
    AppMessenger messenger,
    Email email,
    SendNowResult result,
  ) {
    switch (result.outcome) {
      case SendNowOutcome.sent:
        final warning = result.warning;
        messenger.show(
          warning == null
              ? 'Unsubscribe email sent'
              : 'Unsubscribe email sent. $warning',
          level: warning == null ? AppLogLevel.info : AppLogLevel.warn,
          event: 'email.unsubscribe.sent',
          accountId: email.accountId,
          emailId: email.id,
        );
      case SendNowOutcome.queued:
      case SendNowOutcome.transientFailed:
        _showUnsubscribeQueued(messenger, email, result.message);
      case SendNowOutcome.permanentlyFailed:
        messenger.show(
          'Failed to send unsubscribe: '
          '${result.message ?? 'rejected by the server'}',
          level: AppLogLevel.error,
          event: 'email.unsubscribe.send_failed',
          accountId: email.accountId,
          emailId: email.id,
        );
    }
  }

  Future<void> _sendUnsubscribeEmail(BuildContext context, Uri uri) async {
    final messenger = context.appMessenger();
    final logger = ref.read(appLoggerProvider);
    final email = widget.email;
    setState(() => _sending = true);
    var queued = false;
    var refused = false;
    try {
      final accountId = email.accountId;
      final account =
          await ref.read(accountRepositoryProvider).getAccount(accountId);
      if (account == null) {
        messenger.show(
          'Account not found',
          level: AppLogLevel.warn,
          event: 'email.unsubscribe.account_missing',
          accountId: accountId,
          emailId: email.id,
        );
        return;
      }
      final recipients = uri.path
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map((e) => EmailAddress(email: e))
          .toList();
      final draft = EmailDraft(
        from: EmailAddress(name: account.displayName, email: account.email),
        to: recipients,
        cc: const [],
        subject: uri.queryParameters['subject'] ?? 'unsubscribe',
        body: uri.queryParameters['body'] ?? '',
      );
      // Queue first, like compose: the request is durable even offline and
      // the outbox retries it on every sync cycle (#1240). Then try to send
      // right away so the user sees the outcome, but as in Compose wait only
      // briefly for it: on a dead link the SMTP connect hangs for about 50 s
      // (#1351). A later outcome still shows up as a SnackBar.
      final repo = ref.read(emailRepositoryProvider);
      final rowId = await repo.enqueueSend(accountId, draft);
      queued = true;
      final result = await sendNowBriefly(
        repo,
        logger,
        accountId: accountId,
        outboxRowId: rowId,
        unshownEvent: 'email.unsubscribe.result_unshown',
        onLate: (r) => _showUnsubscribeResult(messenger, email, r),
        onLateError: (e, stack) => _showUnsubscribeQueued(
          messenger,
          email,
          userErrorMessage(e),
          error: e,
          stack: stack,
        ),
      );
      // The messenger is the app's: report even if the chip is gone now.
      if (result == null) {
        messenger.show(
          'Sending the unsubscribe email in the background',
          event: 'email.unsubscribe.sending_background',
          accountId: accountId,
          emailId: email.id,
          duration: const Duration(seconds: 3),
        );
        return;
      }
      refused = result.outcome == SendNowOutcome.permanentlyFailed;
      _showUnsubscribeResult(messenger, email, result);
    } catch (e, stack) {
      if (queued) {
        _showUnsubscribeQueued(
          messenger,
          email,
          userErrorMessage(e),
          error: e,
          stack: stack,
        );
        return;
      }
      messenger.show(
        'Failed to send unsubscribe: ${userErrorMessage(e)}',
        level: AppLogLevel.error,
        event: 'email.unsubscribe.send_failed',
        accountId: email.accountId,
        emailId: email.id,
        error: e,
        stack: stack,
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          // Prev/Next may have swapped in another mail meanwhile.
          if (widget.email.id == email.id) _requested = queued && !refused;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uris = parseListUnsubscribeUris(widget.email.listUnsubscribeHeader);
    if (uris.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: uris.map((u) => u.toString()).join('\n'),
      child: ActionChip(
        avatar: _sending
            ? const SizedBox(
                width: AppIconSize.sm,
                height: AppIconSize.sm,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                _requested ? Icons.check : Icons.unsubscribe_outlined,
                size: AppIconSize.sm,
              ),
        label: const Text('Unsubscribe'),
        onPressed: _sending || _requested ? null : () => _onTap(context, uris),
      ),
    );
  }
}

/// Action button used for destructive top-bar actions (archive / delete /
/// spam). Always visible: a tinted, coloured circular badge that identifies
/// the action at rest, so a mis-tap between the three neighbouring icons is
/// obvious even before the SnackBar / banner appears.
///
/// On tap the badge saturates to full colour, the icon inverts to white,
/// and the whole button scales up ~1.6× with an ease-out bounce before
/// settling back — a much more emphatic pulse than the old 1.4× tint-only
/// animation (#233).
class _ActionMorphButton extends StatefulWidget {
  const _ActionMorphButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  State<_ActionMorphButton> createState() => _ActionMorphButtonState();
}

class _ActionMorphButtonState extends State<_ActionMorphButton> {
  static const _pulseDuration = Duration(milliseconds: 320);

  bool _pulsing = false;
  Timer? _pulseTimer;

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _handle() {
    final onPressed = widget.onPressed;
    if (onPressed == null) return;
    setState(() => _pulsing = true);
    _pulseTimer?.cancel();
    _pulseTimer = Timer(_pulseDuration, () {
      if (mounted) setState(() => _pulsing = false);
    });
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final restBackground =
        widget.color.withValues(alpha: enabled ? 0.18 : 0.08);
    final firingBackground = widget.color;
    final restForeground =
        enabled ? widget.color : widget.color.withValues(alpha: 0.5);
    const firingForeground = Colors.white;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox(
          width: 48,
          height: 48,
          child: InkResponse(
            onTap: enabled ? _handle : null,
            radius: 28,
            child: Center(
              child: AnimatedScale(
                scale: _pulsing ? 1.6 : 1.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _pulsing ? firingBackground : restBackground,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: _pulsing ? firingForeground : restForeground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
