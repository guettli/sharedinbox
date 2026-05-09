import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';

import 'package:sharedinbox/ui/screens/account_list_screen.dart';
import 'package:sharedinbox/ui/screens/add_account_screen.dart';
import 'package:sharedinbox/ui/screens/address_emails_screen.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';
import 'package:sharedinbox/ui/screens/edit_account_screen.dart';
import 'package:sharedinbox/ui/screens/email_detail_screen.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';
import 'package:sharedinbox/ui/screens/search_screen.dart';
import 'package:sharedinbox/ui/screens/sieve_script_edit_screen.dart';
import 'package:sharedinbox/ui/screens/sieve_scripts_screen.dart';
import 'package:sharedinbox/ui/screens/sync_log_screen.dart';
import 'package:sharedinbox/ui/screens/thread_detail_screen.dart';
import 'package:sharedinbox/ui/widgets/undo_shell.dart';

final router = GoRouter(
  initialLocation: '/accounts',
  routes: [
    ShellRoute(
      builder: (ctx, state, child) => UndoShell(child: child),
      routes: [
        GoRoute(
          path: '/accounts',
          builder: (ctx, state) => const AccountListScreen(),
          routes: [
            GoRoute(
              path: 'add',
              builder: (ctx, state) => const AddAccountScreen(),
            ),
            GoRoute(
              path: ':accountId/edit',
              builder: (ctx, state) => EditAccountScreen(
                accountId: state.pathParameters['accountId']!,
              ),
            ),
            GoRoute(
              path: ':accountId/sync-log',
              builder: (ctx, state) => SyncLogScreen(
                accountId: state.pathParameters['accountId']!,
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
              builder: (ctx, state) => SieveScriptEditScreen(
                accountId: state.pathParameters['accountId']!,
                script: state.extra as SieveScript?,
              ),
            ),
            GoRoute(
              path: ':accountId/search',
              builder: (ctx, state) => SearchScreen(
                accountId: state.pathParameters['accountId']!,
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
          builder: (ctx, state) => const SearchScreen(),
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
      ],
    ),
  ],
);
