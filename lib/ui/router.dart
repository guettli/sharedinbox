import 'package:go_router/go_router.dart';

import 'screens/account_list_screen.dart';
import 'screens/add_account_screen.dart';
import 'screens/edit_account_screen.dart';
import 'screens/mailbox_list_screen.dart';
import 'screens/email_list_screen.dart';
import 'screens/email_detail_screen.dart';
import 'screens/compose_screen.dart';
import 'screens/settings_screen.dart';

final router = GoRouter(
  initialLocation: '/accounts',
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
          path: ':accountId/mailboxes',
          builder: (ctx, state) =>
              MailboxListScreen(accountId: state.pathParameters['accountId']!),
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
          ],
        ),
      ],
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
      path: '/settings',
      builder: (ctx, state) => const SettingsScreen(),
    ),
  ],
);
