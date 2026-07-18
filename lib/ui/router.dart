import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/core/models/undo_action.dart';

import 'package:sharedinbox/ui/app_log_observer.dart';
import 'package:sharedinbox/ui/screens/about_screen.dart';
import 'package:sharedinbox/ui/screens/account_compare_screen.dart';
import 'package:sharedinbox/ui/screens/account_home_screen.dart';
import 'package:sharedinbox/ui/screens/account_list_screen.dart';
import 'package:sharedinbox/ui/screens/account_receive_screen.dart';
import 'package:sharedinbox/ui/screens/account_send_screen.dart';
import 'package:sharedinbox/ui/screens/add_account_screen.dart';
import 'package:sharedinbox/ui/screens/address_emails_screen.dart';
import 'package:sharedinbox/ui/screens/app_log_screen.dart';
import 'package:sharedinbox/ui/screens/bug_report_screen.dart';
import 'package:sharedinbox/ui/screens/changelog_screen.dart';
import 'package:sharedinbox/ui/screens/combined_inbox_screen.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';
import 'package:sharedinbox/ui/screens/edit_account_screen.dart';
import 'package:sharedinbox/ui/screens/email_detail_screen.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';
import 'package:sharedinbox/ui/screens/outbox_screen.dart';
import 'package:sharedinbox/ui/screens/push_settings_screen.dart';
import 'package:sharedinbox/ui/screens/search_screen.dart';
import 'package:sharedinbox/ui/screens/sent_queue_screen.dart';
import 'package:sharedinbox/ui/screens/sieve_script_edit_screen.dart';
import 'package:sharedinbox/ui/screens/sieve_scripts_screen.dart';
import 'package:sharedinbox/ui/screens/sync_log_screen.dart';
import 'package:sharedinbox/ui/screens/sync_state_screen.dart';
import 'package:sharedinbox/ui/screens/thread_detail_screen.dart';
import 'package:sharedinbox/ui/screens/trusted_image_senders_screen.dart';
import 'package:sharedinbox/ui/screens/undo_log_detail_screen.dart';
import 'package:sharedinbox/ui/screens/undo_log_screen.dart';
import 'package:sharedinbox/ui/screens/user_preferences_screen.dart';
import 'package:sharedinbox/ui/widgets/undo_shell.dart';

/// Shared observer instance so `main.dart` can attach the [AppLogger] once
/// the Riverpod container is available.
final appLogNavigatorObserver = AppLogNavigatorObserver();

final router = GoRouter(
  initialLocation: '/inbox',
  observers: [appLogNavigatorObserver],
  routes: [
    ShellRoute(
      builder: (ctx, state, child) => UndoShell(child: child),
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (ctx, state) => const CombinedInboxScreen(),
        ),
        GoRoute(
          path: '/accounts',
          builder: (ctx, state) => const AccountListScreen(),
          routes: [
            GoRoute(
              path: 'add',
              builder: (ctx, state) => const AddAccountScreen(),
            ),
            GoRoute(
              path: 'receive',
              builder: (ctx, state) => const AccountReceiveScreen(),
            ),
            GoRoute(
              path: 'send',
              builder: (ctx, state) => const AccountSendScreen(),
            ),
            GoRoute(
              path: 'undo-log',
              builder: (ctx, state) => const UndoLogScreen(),
              routes: [
                GoRoute(
                  path: ':actionId',
                  builder: (ctx, state) => UndoLogDetailScreen(
                    action: state.extra as UndoAction,
                  ),
                ),
              ],
            ),
            GoRoute(
              path: 'app-log',
              builder: (ctx, state) => AppLogScreen(
                initialSyncLogId: int.tryParse(
                  state.uri.queryParameters['syncLogId'] ?? '',
                ),
                initialAccountId: state.uri.queryParameters['accountId'],
              ),
            ),
            GoRoute(
              path: 'changelog',
              builder: (ctx, state) => const ChangeLogScreen(),
            ),
            GoRoute(
              path: 'about',
              builder: (ctx, state) => const AboutScreen(),
            ),
            GoRoute(
              path: 'preferences',
              builder: (ctx, state) => const UserPreferencesScreen(),
            ),
            GoRoute(
              path: 'push',
              builder: (ctx, state) => const PushSettingsScreen(),
            ),
            GoRoute(
              path: 'trusted-senders',
              builder: (ctx, state) => TrustedImageSendersScreen(
                highlightedSender: state.extra as String?,
              ),
            ),
            GoRoute(
              path: ':accountId',
              builder: (ctx, state) => AccountHomeScreen(
                accountId: state.pathParameters['accountId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/edit',
              builder: (ctx, state) => EditAccountScreen(
                accountId: state.pathParameters['accountId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/sync-log',
              builder: (ctx, state) =>
                  SyncLogScreen(accountId: state.pathParameters['accountId']!),
            ),
            GoRoute(
              path: ':accountId/sync-state',
              builder: (ctx, state) => SyncStateScreen(
                accountId: state.pathParameters['accountId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/outbox',
              builder: (ctx, state) =>
                  OutboxScreen(accountId: state.pathParameters['accountId']!),
            ),
            GoRoute(
              path: ':accountId/compare/:otherId',
              builder: (ctx, state) => AccountCompareScreen(
                accountIdA: state.pathParameters['accountId']!,
                accountIdB: state.pathParameters['otherId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/sieve',
              builder: (ctx, state) => SieveScriptsScreen(
                accountId: state.pathParameters['accountId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/sieve/edit',
              builder: (ctx, state) {
                final payload = _sieveEditPayload(state.extra);
                return SieveScriptEditScreen(
                  accountId: state.pathParameters['accountId']!,
                  script: payload.script,
                  initialFilter: payload.filter,
                  initialName: payload.name,
                );
              },
            ),
            GoRoute(
              path: ':accountId/sieve/local',
              builder: (ctx, state) => SieveScriptsScreen(
                accountId: state.pathParameters['accountId']!,
                isLocal: true,
              ),
            ),
            GoRoute(
              path: ':accountId/sieve/local/edit',
              builder: (ctx, state) {
                final payload = _sieveEditPayload(state.extra);
                return SieveScriptEditScreen(
                  accountId: state.pathParameters['accountId']!,
                  script: payload.script,
                  isLocal: true,
                  initialFilter: payload.filter,
                  initialName: payload.name,
                );
              },
            ),
            GoRoute(
              path: ':accountId/search',
              builder: (ctx, state) => SearchScreen(
                accountId: state.pathParameters['accountId']!,
                initialFilter: state.extra as FilterGroup?,
              ),
            ),
            GoRoute(
              path: ':accountId/emails/by-address/:address',
              builder: (ctx, state) => AddressEmailsScreen(
                accountId: state.pathParameters['accountId']!,
                address: state.pathParameters['address']!,
              ),
            ),
            GoRoute(
              path: ':accountId/mailboxes',
              builder: (ctx, state) => MailboxListScreen(
                accountId: state.pathParameters['accountId']!,
              ),
              routes: [
                GoRoute(
                  path: ':mailboxPath/emails',
                  builder: (ctx, state) => EmailListScreen(
                    accountId: state.pathParameters['accountId']!,
                    mailboxPath: state.pathParameters['mailboxPath']!,
                  ),
                  routes: [
                    GoRoute(
                      path: ':emailId',
                      builder: (ctx, state) => EmailDetailScreen(
                        emailId: state.pathParameters['emailId']!,
                      ),
                    ),
                  ],
                ),
                GoRoute(
                  path: ':mailboxPath/threads/:threadId',
                  builder: (ctx, state) => ThreadDetailScreen(
                    accountId: state.pathParameters['accountId']!,
                    mailboxPath: Uri.decodeComponent(
                      state.pathParameters['mailboxPath']!,
                    ),
                    threadId: Uri.decodeComponent(
                      state.pathParameters['threadId']!,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/search',
          builder: (ctx, state) => SearchScreen(
            initialFilter: state.extra as FilterGroup?,
          ),
        ),
        GoRoute(
          path: '/compose',
          builder: (ctx, state) {
            final extra = state.extra as Map<String, dynamic>?;
            return ComposeScreen(
              accountId: extra?['accountId'] as String?,
              replyToEmailId: extra?['replyToEmailId'] as String?,
              prefillTo: extra?['prefillTo'] as String?,
              prefillCc: extra?['prefillCc'] as String?,
              prefillSubject: extra?['prefillSubject'] as String?,
              prefillBody: extra?['prefillBody'] as String?,
            );
          },
        ),
        GoRoute(
          path: '/bug-report',
          builder: (ctx, state) => BugReportScreen(
            emailId: state.uri.queryParameters['emailId'],
          ),
        ),
        GoRoute(
          path: '/sent-queue',
          builder: (ctx, state) => const SentQueueScreen(),
        ),
      ],
    ),
  ],
);

/// A `sieve/edit` route accepts either a bare [SieveScript] (edit an existing
/// script) or a prefill record `(filter, name)` used when creating a new
/// script from another screen — e.g. the mail-header actions in issue #254.
({SieveScript? script, FilterGroup? filter, String? name}) _sieveEditPayload(
  Object? extra,
) {
  if (extra is SieveScript) {
    return (script: extra, filter: null, name: null);
  }
  if (extra is SieveEditPrefill) {
    return (script: null, filter: extra.filter, name: extra.name);
  }
  return (script: null, filter: null, name: null);
}

/// Prefill payload for `context.push('/…/sieve/edit', extra: …)` when creating
/// a new Sieve script pre-populated from elsewhere in the app.
class SieveEditPrefill {
  const SieveEditPrefill({required this.filter, required this.name});
  final FilterGroup filter;
  final String name;
}
