import 'dart:async';
import 'dart:convert';

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

const _bugReportApiUrl = String.fromEnvironment(
  'BUG_REPORT_API_URL',
  defaultValue: 'https://sharedinbox.de/api/v1/bug-reports',
);

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

    setState(() => _submitting = true);

    try {
      final client = ref.read(httpClientProvider);
      final uri = Uri.parse(_bugReportApiUrl);
      final request = http.MultipartRequest('POST', uri);

      // Description
      request.fields['description'] = _descriptionController.text;

      // Email Data if from email view
      if (_attachedEmail != null) {
        final emailMap = {
          'id': _attachedEmail!.id,
          'subject': _attachedEmail!.subject,
          'from': _attachedEmail!.from.map((e) => e.toString()).toList(),
          'date': _attachedEmail!.sentAt?.toIso8601String() ??
              _attachedEmail!.receivedAt.toIso8601String(),
          'preview': _attachedEmail!.preview,
        };
        request.fields['email_data'] = jsonEncode(emailMap);
      }

      // Contact Email
      if (_includeEmail) {
        request.fields['email'] = _emailController.text;
      }

      // About Info
      PackageInfo? pkg;
      try {
        pkg = await _packageInfoFuture;
      } catch (_) {}
      final imapCount =
          _accounts.where((a) => a.type == AccountType.imap).length;
      final jmapCount =
          _accounts.where((a) => a.type == AccountType.jmap).length;

      if (!mounted) return;
      final aboutInfo = buildAboutMarkdown(
        context: context,
        pkg: pkg,
        imapCount: imapCount,
        jmapCount: jmapCount,
        deviceModel: _deviceModel,
      );
      request.fields['about_info'] = aboutInfo;

      // Sync Log
      if (_includeSyncLog && _selectedAccountId != null) {
        final syncLogs = await ref
            .read(syncLogRepositoryProvider)
            .observeSyncLogs(_selectedAccountId!)
            .first;
        request.fields['sync_log'] = _serializeSyncLogs(syncLogs);
      }

      // Attachments
      for (final file in _attachments) {
        final multipartFile = await http.MultipartFile.fromPath(
          'attachments[]',
          file.path!,
          filename: file.name,
        );
        request.files.add(multipartFile);
      }

      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (!mounted) return;

      if (response.statusCode == 201) {
        final resData = jsonDecode(response.body) as Map<String, dynamic>;
        final reportId = resData['id'] as String;
        _showSuccessDialog(reportId);
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

  void _showSuccessDialog(String reportId) {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('Bug Report Submitted'),
            content: SingleChildScrollView(
              child: ListBody(
                children: [
                  const Text('Thank you for helping us improve SharedInbox!'),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Your Report ID is:\n$reportId',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'Your report is handled confidentially and has not been posted to the public issue tracker.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(); // Dismiss dialog
                  context.pop(); // Go back to previous screen
                },
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
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
                  // Confidentiality info card
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
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            color: theme.colorScheme.secondary,
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          const Expanded(
                            child: Text(
                              'Your report is handled confidentially and will not be posted to the public issue tracker.',
                              style: TextStyle(height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Description Text Field
                  TextFormField(
                    controller: _descriptionController,
                    autofocus: true,
                    maxLines: 8,
                    minLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'What went wrong?',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                      helperText:
                          'Please describe the problem and how to reproduce it.',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a description.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Email info chip if email is attached
                  if (_attachedEmail != null) ...[
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.email_outlined,
                              size: AppIconSize.md,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            const Expanded(
                              child: Text(
                                'The current email metadata will be attached automatically.',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
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

                  // System info section
                  FutureBuilder<PackageInfo>(
                    future: _packageInfoFuture,
                    builder: (context, snapshot) {
                      final imapCount = _accounts
                          .where((a) => a.type == AccountType.imap)
                          .length;
                      final jmapCount = _accounts
                          .where((a) => a.type == AccountType.jmap)
                          .length;
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
                  ),
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
