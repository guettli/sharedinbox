import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/about_markdown.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

/// Colour used to outline fields whose contents go into the **public** GitHub
/// issue, so the user can tell at a glance what will be visible to everyone.
const _publicColor = Color(0xFFD97706); // amber-600, legible in both themes

/// Client-side mirror of the server's `maxEncryptedAttachments`
/// (server/bugreport/main.go): the encrypted-report endpoint rejects a report
/// carrying more screenshots than this, so we guard here for a clear message
/// rather than a generic server error.
const _maxEncryptedScreenshots = 10;

class BugReportScreen extends ConsumerStatefulWidget {
  const BugReportScreen({super.key, this.emailId});

  final String? emailId;

  @override
  ConsumerState<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends ConsumerState<BugReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _emailController = TextEditingController();

  final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();
  late final Future<String?> _deviceModelFuture = getDeviceModel();

  final List<PlatformFile> _attachments = [];
  bool _includeEmail = false;
  bool _includeSyncLog = false;
  // When reporting about a specific email, the full mail is encrypted on-device
  // to the maintainer's public key and attached to a public GitHub issue.
  bool _includeEncryptedMail = false;
  bool _submitting = false;

  Email? _attachedEmail;
  List<Account> _accounts = [];
  String? _selectedAccountId;
  String? _deviceModel;
  bool _loadingEmail = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _loadingEmail = true);
    try {
      _deviceModel = await _deviceModelFuture;
      _accounts =
          await ref.read(accountRepositoryProvider).observeAccounts().first;

      if (widget.emailId != null) {
        final email =
            await ref.read(emailRepositoryProvider).getEmail(widget.emailId!);
        if (mounted && email != null) {
          _attachedEmail = email;
          _includeEncryptedMail = true;
          _selectedAccountId = email.accountId;
          final fromStr =
              email.from.isNotEmpty ? email.from.first.toString() : 'unknown';
          final subjectStr = email.subject ?? '(no subject)';
          _descriptionController.text =
              'Problem with email from $fromStr: "$subjectStr"\n\n';
        }
      }

      if (_selectedAccountId == null && _accounts.isNotEmpty) {
        _selectedAccountId = _accounts.first.id;
      }

      if (_selectedAccountId != null) {
        final matching =
            _accounts.where((a) => a.id == _selectedAccountId).firstOrNull;
        if (matching != null) {
          _emailController.text = matching.email;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _loadingEmail = false);
    }
  }

  int get _totalAttachmentSize {
    return _attachments.fold(0, (sum, f) => sum + f.size);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.pickFiles();
      if (result == null) return;
      final newFiles =
          result.files.where((PlatformFile f) => f.path != null).toList();
      if (!mounted) return;
      setState(() {
        _attachments.addAll(newFiles);
      });
    } catch (e, stack) {
      if (mounted) {
        context.showAppSnackBar(
          'Failed to pick files: $e',
          level: AppLogLevel.error,
          event: 'bug_report.pick_files_failed',
          error: e,
          stack: stack,
        );
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
    });
  }

  String _serializeSyncLogs(List<SyncLogEntry> entries) {
    final sb = StringBuffer();
    for (final entry in entries.take(50)) {
      sb.writeln('ID: ${entry.id}');
      sb.writeln('Started: ${entry.startedAt.toIso8601String()}');
      sb.writeln('Finished: ${entry.finishedAt.toIso8601String()}');
      sb.writeln('Result: ${entry.result}');
      if (entry.errorMessage != null) {
        sb.writeln('Error: ${entry.errorMessage}');
      }
      if (entry.stackTrace != null) {
        sb.writeln('StackTrace:\n${entry.stackTrace}');
      }
      sb.writeln('Protocol: ${entry.protocol}');
      sb.writeln(
        'Fetched: ${entry.emailsFetched}, Skipped: ${entry.emailsSkipped}',
      );
      if (entry.protocolLog != null) {
        sb.writeln('Protocol Log:\n${entry.protocolLog}');
      }
      sb.writeln('---');
    }
    return sb.toString();
  }

  Future<void> _submitReport() async {
    if (!_formKey.currentState!.validate()) return;

    final totalSize = _totalAttachmentSize;
    if (totalSize > 20 * 1024 * 1024) {
      context.showAppSnackBar(
        'Total attachments size exceeds the 20 MB limit. Please remove some files.',
        level: AppLogLevel.warn,
        backgroundColor: Colors.red,
      );
      return;
    }

    if (_attachments.length > _maxEncryptedScreenshots) {
      context.showAppSnackBar(
        'Please attach at most $_maxEncryptedScreenshots screenshots.',
        level: AppLogLevel.warn,
        backgroundColor: Colors.red,
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      final client = ref.read(httpClientProvider);
      final encryptedReports = ref.read(encryptedReportServiceProvider);
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(encryptedReports.submitUrl),
      );

      // ── Public fields — these appear in cleartext in the GitHub issue. ──
      request.fields['description'] = _descriptionController.text;

      PackageInfo? pkg;
      try {
        pkg = await _packageInfoFuture;
      } catch (_) {}
      final imapCount =
          _accounts.where((a) => a.type == AccountType.imap).length;
      final jmapCount =
          _accounts.where((a) => a.type == AccountType.jmap).length;

      if (!mounted) return;
      request.fields['about_info'] = buildAboutMarkdown(
        context: context,
        pkg: pkg,
        imapCount: imapCount,
        jmapCount: jmapCount,
        deviceModel: _deviceModel,
      );

      // Sync Log
      if (_includeSyncLog && _selectedAccountId != null) {
        final syncLogs = await ref
            .read(syncLogRepositoryProvider)
            .observeSyncLogs(_selectedAccountId!)
            .first;
        request.fields['sync_log'] = _serializeSyncLogs(syncLogs);
      }

      // Private parts — encrypted on-device to the maintainer's key so they
      // never appear on the public issue tracker. Each part is optional, so a
      // general bug report with no mail is a public issue with no attachments.
      final attachingMail = _includeEncryptedMail && _attachedEmail != null;
      final metadataYaml = _buildMetadataYaml(attachingMail: attachingMail);

      if (attachingMail || metadataYaml != null || _attachments.isNotEmpty) {
        // Fetch the maintainer's public key once; reuse it for every blob.
        final reportKey = await encryptedReports.fetchPublicKey();

        if (attachingMail) {
          final rawMail = await ref
              .read(emailRepositoryProvider)
              .fetchRawRfc822(_attachedEmail!.id);
          final encrypted = await encryptedReports.encryptMail(
            reportKey,
            utf8.encode(rawMail),
          );
          request.files.add(
            http.MultipartFile.fromBytes(
              'encrypted_mail',
              encrypted,
              filename: 'mail.enc',
            ),
          );
        }

        if (metadataYaml != null) {
          final encrypted = await encryptedReports.encryptAttachment(
            reportKey,
            utf8.encode(metadataYaml),
          );
          request.files.add(
            http.MultipartFile.fromBytes(
              'encrypted_metadata',
              encrypted,
              filename: 'metadata.enc',
            ),
          );
        }

        // Screenshots are encrypted to the maintainer's key exactly like the
        // mail and uploaded as `encrypted_attachments[]`, so the plaintext
        // image never reaches the public issue tracker (issue #851).
        for (var i = 0; i < _attachments.length; i++) {
          final bytes = await File(_attachments[i].path!).readAsBytes();
          final encrypted =
              await encryptedReports.encryptAttachment(reportKey, bytes);
          request.files.add(
            http.MultipartFile.fromBytes(
              'encrypted_attachments[]',
              encrypted,
              filename: 'image_${i + 1}.enc',
            ),
          );
        }
      }

      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (!mounted) return;

      if (response.statusCode == 201) {
        final resData = jsonDecode(response.body) as Map<String, dynamic>;
        await _onIssueCreated(
          resData['issueUrl'] as String,
          issueNumber: (resData['issueNumber'] as num?)?.toInt(),
          reportId: resData['id'] as String?,
        );
      } else if (response.statusCode == 429) {
        final retryAfter = response.headers['retry-after'] ?? '6';
        context.showAppSnackBar(
          'Rate limited. Please retry in $retryAfter seconds.',
          level: AppLogLevel.warn,
          backgroundColor: Colors.orange,
        );
      } else {
        String errorMsg =
            'Failed to submit report. Server returned status: ${response.statusCode}';
        try {
          final resData = jsonDecode(response.body) as Map<String, dynamic>;
          if (resData['error'] != null) {
            errorMsg = resData['error'] as String;
          }
        } catch (_) {}
        context.showAppSnackBar(
          errorMsg,
          level: AppLogLevel.warn,
          event: 'bug_report.submit_failed',
          data: {
            'statusCode': response.statusCode,
            'errorMsg': errorMsg,
          },
          backgroundColor: Colors.red,
        );
      }
    } catch (e, stack) {
      if (mounted) {
        context.showAppSnackBar(
          'An error occurred: $e',
          level: AppLogLevel.error,
          event: 'bug_report.submit_failed',
          backgroundColor: Colors.red,
          error: e,
          stack: stack,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _onIssueCreated(
    String issueUrl, {
    int? issueNumber,
    String? reportId,
  }) async {
    // Record the URL in the App Log so the user can find it again later.
    await ref.read(appLoggerProvider).log(
      level: AppLogLevel.info,
      event: 'bug_report.issue_created',
      message: 'Created GitHub issue: $issueUrl',
      screen: 'bug_report',
      emailId: _attachedEmail?.id,
      data: {'issueUrl': issueUrl},
    );
    // Persist the report so it can be listed in the ChangeLog view. A DB
    // failure here must never block the success dialog.
    try {
      await ref.read(dbProvider).recordBugReport(
            issueUrl: issueUrl,
            issueNumber: issueNumber,
            reportId: reportId,
            createdAt: DateTime.now(),
          );
    } catch (_) {
      // Best-effort local record; ignore failures.
    }
    if (!mounted) return;
    await _showResultDialog(
      title: 'Issue Created',
      content: [
        const Text(
          'Thank you! A GitHub issue was created with the email attached in '
          'encrypted form — only the maintainer can read it.',
        ),
        const SizedBox(height: AppSpacing.md),
        SelectableText(
          issueUrl,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
      leadingActions: [
        TextButton(
          onPressed: () async {
            final uri = Uri.tryParse(issueUrl);
            if (uri != null) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: const Text('Open'),
        ),
      ],
    );
  }

  /// Builds the encrypted metadata YAML block carrying the private, non-mail
  /// details of a report: the optional contact email and — when the full mail
  /// is *not* attached — the reported email's metadata. Returns null when there
  /// is nothing private to send. Scalar values are JSON-encoded, which is valid
  /// YAML and safely escapes any special characters.
  String? _buildMetadataYaml({required bool attachingMail}) {
    final lines = <String>[];

    if (_includeEmail && _emailController.text.trim().isNotEmpty) {
      lines.add('contact_email: ${jsonEncode(_emailController.text.trim())}');
    }

    // Only include the email's metadata when the full encrypted mail is not
    // being attached — otherwise the mail already carries everything.
    if (_attachedEmail != null && !attachingMail) {
      lines.add('email:');
      lines.add('  id: ${jsonEncode(_attachedEmail!.id)}');
      lines.add('  subject: ${jsonEncode(_attachedEmail!.subject ?? '')}');
      final from = _attachedEmail!.from.map((e) => e.toString()).toList();
      if (from.isEmpty) {
        lines.add('  from: []');
      } else {
        lines.add('  from:');
        for (final f in from) {
          lines.add('    - ${jsonEncode(f)}');
        }
      }
      final date = _attachedEmail!.sentAt?.toIso8601String() ??
          _attachedEmail!.receivedAt.toIso8601String();
      lines.add('  date: ${jsonEncode(date)}');
      if (_attachedEmail!.preview != null) {
        lines.add('  preview: ${jsonEncode(_attachedEmail!.preview)}');
      }
    }

    if (lines.isEmpty) return null;
    return '${lines.join('\n')}\n';
  }

  /// Shows a modal result dialog. The trailing "Close" button dismisses the
  /// dialog and pops back to the previous screen; [leadingActions] are placed
  /// before it (e.g. an "Open" button).
  Future<void> _showResultDialog({
    required String title,
    required List<Widget> content,
    List<Widget> leadingActions = const [],
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: ListBody(children: content)),
          actions: [
            ...leadingActions,
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(); // Dismiss dialog
                context.pop(); // Go back to previous screen
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// The collapsible "System Info" card. Its contents are public (they go into
  /// the GitHub issue), so the caller wraps it in a [_PublicField].
  Widget _systemInfoCard(ThemeData theme) {
    return FutureBuilder<PackageInfo>(
      future: _packageInfoFuture,
      builder: (context, snapshot) {
        final imapCount =
            _accounts.where((a) => a.type == AccountType.imap).length;
        final jmapCount =
            _accounts.where((a) => a.type == AccountType.jmap).length;
        final aboutMd = buildAboutMarkdown(
          context: context,
          pkg: snapshot.data,
          imapCount: imapCount,
          jmapCount: jmapCount,
          deviceModel: _deviceModel,
        );
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.1),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ExpansionTile(
            title: const Text(
              'System Info (attached automatically)',
              style: TextStyle(fontSize: 14),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: MarkdownBody(data: aboutMd),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalSize = _totalAttachmentSize;
    const sizeLimit = 20 * 1024 * 1024;
    final approachingLimit = totalSize > 15 * 1024 * 1024;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report a Bug'),
      ),
      body: _loadingEmail
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // Privacy legend: what becomes public vs. what is encrypted.
                  Card(
                    elevation: 0,
                    color: theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color:
                            theme.colorScheme.secondary.withValues(alpha: 0.4),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.public, color: _publicColor),
                              SizedBox(width: AppSpacing.lg),
                              Expanded(
                                child: Text(
                                  'This opens a public GitHub issue. Fields with '
                                  'a dashed amber border are visible to everyone.',
                                  style: TextStyle(height: 1.3),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                color: theme.colorScheme.secondary,
                              ),
                              const SizedBox(width: AppSpacing.lg),
                              const Expanded(
                                child: Text(
                                  'Your email, screenshots and contact address '
                                  'are encrypted on this device — only the '
                                  'maintainer can read them.',
                                  style: TextStyle(height: 1.3),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Description Text Field (optional) — public.
                  _PublicField(
                    child: TextFormField(
                      controller: _descriptionController,
                      autofocus: true,
                      maxLines: 8,
                      minLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'What went wrong? (optional)',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                        helperText:
                            'Please describe the problem and how to reproduce it.',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Encrypted-mail opt-in when reporting about an email.
                  if (_attachedEmail != null) ...[
                    CheckboxListTile(
                      title: const Text('Attach this email (encrypted)'),
                      subtitle: const Text(
                        'Creates a public GitHub issue. The full email is '
                        'encrypted on this device so only the maintainer can '
                        'read it.',
                      ),
                      value: _includeEncryptedMail,
                      onChanged: _submitting
                          ? null
                          : (val) {
                              setState(
                                () => _includeEncryptedMail = val ?? false,
                              );
                            },
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  // Attachments Section
                  Text(
                    'Attachments',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _submitting ? null : _pickAttachments,
                        icon: const Icon(Icons.add_a_photo_outlined),
                        label: const Text('Add screenshots'),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Text(
                          'Screenshots help us understand the problem faster.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_attachments.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      height: 48,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _attachments.length,
                        itemBuilder: (context, index) {
                          final file = _attachments[index];
                          return Padding(
                            padding:
                                const EdgeInsets.only(right: AppSpacing.sm),
                            child: InputChip(
                              label: Text(
                                '${file.name} (${_formatSize(file.size)})',
                              ),
                              onDeleted: _submitting
                                  ? null
                                  : () => _removeAttachment(index),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Text(
                          'Total Attachment Size: ${_formatSize(totalSize)} / ${_formatSize(sizeLimit)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: totalSize > sizeLimit
                                ? Colors.red
                                : approachingLimit
                                    ? Colors.orange
                                    : Colors.grey,
                            fontWeight: approachingLimit
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        if (totalSize > sizeLimit) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const Icon(
                            Icons.error_outline,
                            size: AppIconSize.sm,
                            color: Colors.red,
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),

                  // Email opt-in
                  CheckboxListTile(
                    title: const Text('Include my email for follow-up'),
                    value: _includeEmail,
                    onChanged: _submitting
                        ? null
                        : (val) {
                            setState(() => _includeEmail = val ?? false);
                          },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_includeEmail) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Contact Email Address',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (_includeEmail &&
                              (value == null || value.trim().isEmpty)) {
                            return 'Please enter an email address.';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],

                  // Sync log opt-in
                  if (_selectedAccountId != null) ...[
                    CheckboxListTile(
                      title: const Text('Include recent sync log'),
                      subtitle: const Text(
                        'Helps diagnose connection and protocol issues.',
                      ),
                      value: _includeSyncLog,
                      onChanged: _submitting
                          ? null
                          : (val) {
                              setState(() => _includeSyncLog = val ?? false);
                            },
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],

                  // System info section — public.
                  _PublicField(child: _systemInfoCard(theme)),
                  const SizedBox(height: AppSpacing.xxl),

                  // Submit Button
                  FilledButton(
                    onPressed: _submitting ? null : _submitReport,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Send Bug Report',
                              style: TextStyle(fontSize: 16),
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Outlines its [child] with a dashed amber border and a "Public" badge, so the
/// user can see at a glance that the field's contents go into the public GitHub
/// issue.
class _PublicField extends StatelessWidget {
  const _PublicField({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: _publicColor),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.public, size: 16, color: _publicColor),
                SizedBox(width: AppSpacing.sm),
                Text(
                  'Public — shown in the GitHub issue',
                  style: TextStyle(
                    color: _publicColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle border around the paint area.
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    final path = Path()..addRRect(rrect);

    const dashWidth = 6.0;
    const dashGap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dashWidth).clamp(0.0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}
