import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/notification_rule.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';

/// Per-account "pop up for these mails" configuration. New mail is silent by
/// default; the user turns on the master switch and adds rules describing which
/// messages should fire an OS notification.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key, required this.accountId});

  final String accountId;

  /// Notification rules never match on the mailbox folder — they only run
  /// against inbox mail — so the folder field is hidden in the builder.
  static const _availableFields = [
    FilterField.from_,
    FilterField.to,
    FilterField.cc,
    FilterField.subject,
    FilterField.header,
    FilterField.size,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: accountAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (account) {
          if (account == null) {
            return const Center(child: Text('Account not found'));
          }
          return _body(context, ref, account.notificationsEnabled);
        },
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, bool enabled) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        SwitchListTile(
          value: enabled,
          onChanged: (value) => _setEnabled(context, ref, value),
          title: const Text('Show notifications for new mail on this account'),
          subtitle: const Text(
            'Off by default. Turn on to configure which mails pop up.',
          ),
        ),
        if (enabled) ..._enabledSections(context, ref),
      ],
    );
  }

  List<Widget> _enabledSections(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(notificationRulesProvider(accountId));
    return [
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('Quick add', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      ListTile(
        leading: const Icon(Icons.person_add_alt),
        title: const Text('Add sender'),
        subtitle: const Text('Pop up for mail from one address'),
        onTap: () => _addSender(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.label_outline),
        title: const Text('Add mailing list / subject keyword'),
        subtitle: const Text('Pop up when the subject contains this text'),
        onTap: () => _addSubjectKeyword(context, ref),
      ),
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('Rules', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      rulesAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $e'),
        ),
        data: (rules) => rules.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No rules yet — add one below to receive popups.'),
              )
            : Column(
                children: [
                  for (final rule in rules) _ruleTile(context, ref, rule),
                ],
              ),
      ),
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('Advanced', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      ListTile(
        leading: const Icon(Icons.tune),
        title: const Text('Custom rule'),
        subtitle: const Text('Build a rule with the full filter editor'),
        onTap: () => _editRule(context, ref, null),
      ),
    ];
  }

  Widget _ruleTile(BuildContext context, WidgetRef ref, NotificationRule rule) {
    return ListTile(
      leading: const Icon(Icons.circle, size: 12),
      title: Text(ruleLabel(rule)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit',
            onPressed: () => _editRule(context, ref, rule),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Delete',
            onPressed: () async {
              await ref
                  .read(notificationRuleRepositoryProvider)
                  .deleteRule(rule.id);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    final accountRepo = ref.read(accountRepositoryProvider);
    final account = await accountRepo.getAccount(accountId);
    if (account == null) return;
    if (value) {
      // Silence the existing backlog so only mail arriving after opt-in pops up.
      await ref
          .read(notificationRuleRepositoryProvider)
          .markBaseline(accountId);
    }
    await accountRepo.updateAccount(
      account.copyWith(notificationsEnabled: value),
    );
  }

  Future<void> _addSender(BuildContext context, WidgetRef ref) async {
    final address = await _promptText(
      context,
      title: 'Add sender',
      label: 'Email address',
      keyboardType: TextInputType.emailAddress,
    );
    if (address == null || address.trim().isEmpty) return;
    final filter = FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.from_,
          comparison: FilterComparison.is_,
          value: address.trim(),
        ),
      ],
    );
    await ref.read(notificationRuleRepositoryProvider).addRule(
          accountId,
          filter,
        );
  }

  Future<void> _addSubjectKeyword(BuildContext context, WidgetRef ref) async {
    final text = await _promptText(
      context,
      title: 'Add mailing list / subject keyword',
      label: 'Subject contains',
    );
    if (text == null || text.trim().isEmpty) return;
    final filter = FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.subject,
          comparison: FilterComparison.contains,
          value: text.trim(),
        ),
      ],
    );
    await ref.read(notificationRuleRepositoryProvider).addRule(
          accountId,
          filter,
        );
  }

  Future<void> _editRule(
    BuildContext context,
    WidgetRef ref,
    NotificationRule? rule,
  ) async {
    final result = await Navigator.of(context).push<_RuleEditResult>(
      MaterialPageRoute(
        builder: (_) => _RuleEditorPage(
          accountId: accountId,
          initial: rule?.filter,
          initialName: rule?.name,
        ),
      ),
    );
    if (result == null) return;
    final repo = ref.read(notificationRuleRepositoryProvider);
    if (rule == null) {
      await repo.addRule(accountId, result.filter, name: result.name);
    } else {
      await repo.updateRule(rule.id, result.filter, name: result.name);
    }
    if (context.mounted) context.showAppSnackBar('Rule saved');
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    required String label,
    TextInputType? keyboardType,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: keyboardType,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// Human-readable one-line summary of a rule for the list. Uses the stored
/// [NotificationRule.name] when present, otherwise a compact description of a
/// single-leaf filter, falling back to "Custom rule" for anything richer.
String ruleLabel(NotificationRule rule) {
  final name = rule.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final children = rule.filter.children;
  if (children.length == 1) {
    final child = children.first;
    if (child is FilterLeaf) {
      final field = child.headerName ?? child.field.label;
      return '$field ${child.comparison.label} "${child.value}"';
    }
  }
  return 'Custom rule';
}

class _RuleEditResult {
  const _RuleEditResult({required this.filter, this.name});
  final FilterGroup filter;
  final String? name;
}

class _RuleEditorPage extends StatefulWidget {
  const _RuleEditorPage({
    required this.accountId,
    this.initial,
    this.initialName,
  });

  final String accountId;
  final FilterGroup? initial;
  final String? initialName;

  @override
  State<_RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<_RuleEditorPage> {
  late FilterGroup _group;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _group = widget.initial ?? FilterGroup.empty();
    _nameController = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification rule'),
        actions: [
          TextButton(
            onPressed: _group.isEmpty
                ? null
                : () {
                    final name = _nameController.text.trim();
                    Navigator.of(context).pop(
                      _RuleEditResult(
                        filter: _group,
                        name: name.isEmpty ? null : name,
                      ),
                    );
                  },
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
            ),
          ),
          const SizedBox(height: 16),
          FilterBuilderWidget(
            initialValue: _group,
            accountId: widget.accountId,
            availableFields: NotificationsScreen._availableFields,
            onChanged: (g) => setState(() => _group = g),
          ),
        ],
      ),
    );
  }
}
