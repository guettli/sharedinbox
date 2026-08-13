import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sharedinbox/core/storage/db_open_result.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full-screen fallback shown by `main()` when the local mail-cache database
/// cannot be opened at startup (see [probeDatabase]). Unlike the generic
/// CrashScreen it names the specific cause and — where the data is genuinely
/// lost — offers a "Delete local cache and restart" recovery that keeps the
/// user's account credentials.
class DatabaseUnreadableScreen extends StatelessWidget {
  const DatabaseUnreadableScreen({
    super.key,
    required this.result,
    this.onDeleteAndRestart,
  });

  final DbProbeResult result;

  /// Deletes the cache and boots a fresh DB. Provided by `main()`; null when
  /// the reason forbids deletion (the build-bug case), so the button is hidden.
  final Future<void> Function()? onDeleteAndRestart;

  String get _title => switch (result.reason) {
        DbUnreadableReason.buildMissingCipher =>
          'Database encryption support is missing',
        DbUnreadableReason.keyMissing => 'Encryption key not found',
        DbUnreadableReason.wrongKeyOrFormat => 'Local cache cannot be opened',
        DbUnreadableReason.corrupt => 'Local cache is damaged',
        null => 'Local cache cannot be opened',
      };

  String get _body => switch (result.reason) {
        DbUnreadableReason.buildMissingCipher =>
          'This build of sharedinbox was compiled without database encryption '
              'support, but your local database is encrypted. This is a bug in '
              'the build, not a problem with your data. Please report it — do '
              'not delete anything.',
        DbUnreadableReason.keyMissing =>
          'The key for your encrypted local database is no longer in the '
              'device keystore, so the cache cannot be decrypted. This happens '
              'after a device restore. Your mail is safe on the server.',
        DbUnreadableReason.wrongKeyOrFormat =>
          'The local mail cache was written by a different version of the app '
              'and this build cannot open it. Your mail is safe on the server; '
              'your accounts and passwords are kept.',
        DbUnreadableReason.corrupt =>
          'The local mail cache is damaged and cannot be opened. Your mail is '
              'safe on the server; your accounts and passwords are kept.',
        null => 'The local mail cache could not be opened.',
      };

  bool get _showDelete => result.allowsDelete && onDeleteAndRestart != null;

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete local cache?'),
        content: const Text(
          'This deletes the local mail cache and restarts the app with a '
          'fresh, empty database. Your accounts and passwords are kept, so '
          'you will not have to sign in again. Your mail is re-fetched from '
          'the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete and restart'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await onDeleteAndRestart!();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Cannot open local cache'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
        body: Builder(
          builder: (ctx) => SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.lock_outline,
                  color: Colors.red,
                  size: AppIconSize.hero,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  _title,
                  style: Theme.of(ctx).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _body,
                  style: Theme.of(ctx).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                const Text(
                  'Error Details:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${result.error ?? 'unknown error'}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: '$_title\n\n${result.error}'),
                    );
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          duration: Duration(seconds: 5),
                          content: Text('Copied to clipboard'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy to Clipboard'),
                ),
                const SizedBox(height: AppSpacing.lg),
                OutlinedButton.icon(
                  onPressed: () async {
                    final title = Uri.encodeComponent('Cannot open DB: $_title');
                    final url = Uri.parse(
                      'https://github.com/guettli/sharedinbox/issues/new?title=$title',
                    );
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.bug_report),
                  label: const Text('Report Issue on GitHub'),
                ),
                if (_showDelete) ...[
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          Theme.of(ctx).colorScheme.errorContainer,
                      foregroundColor:
                          Theme.of(ctx).colorScheme.onErrorContainer,
                    ),
                    onPressed: () => _confirmDelete(ctx),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete local cache and restart'),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Your accounts and passwords are kept.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
