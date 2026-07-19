import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

class SieveScriptsScreen extends ConsumerStatefulWidget {
  const SieveScriptsScreen({
    super.key,
    required this.accountId,
    this.isLocal = false,
  });

  final String accountId;

  /// True for locally-executed scripts; false for server-side (ManageSieve/JMAP).
  final bool isLocal;

  @override
  ConsumerState<SieveScriptsScreen> createState() => _SieveScriptsScreenState();
}

class _SieveScriptsScreenState extends ConsumerState<SieveScriptsScreen> {
  List<SieveScript>? _scripts;
  String? _error;
  bool _loading = true;

  String get _editRoute => widget.isLocal
      ? '/accounts/${widget.accountId}/sieve/local/edit'
      : '/accounts/${widget.accountId}/sieve/edit';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scripts = widget.isLocal
          ? await ref
              .read(localSieveRepositoryProvider)
              .listScripts(widget.accountId)
          : await ref
              .read(sieveRepositoryProvider)
              .listScripts(widget.accountId);
      if (mounted) {
        setState(() {
          _scripts = scripts;
          _loading = false;
        });
      }
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.list_failed',
              'Failed to list sieve scripts',
              accountId: widget.accountId,
              data: {'isLocal': widget.isLocal},
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
      // Refresh the cached ManageSieve availability flag so the menu can
      // disappear next time if the server has gone bad since the last probe
      // (e.g. its TLS cert/listener broke after the account was added).
      if (!widget.isLocal) {
        unawaited(_refreshManageSieveAvailability());
      }
    }
  }

  Future<void> _refreshManageSieveAvailability() async {
    try {
      final account = await ref
          .read(accountRepositoryProvider)
          .getAccount(widget.accountId);
      if (account == null || account.type != AccountType.imap) return;
      await ref.read(manageSieveProbeServiceProvider).probe(account);
    } catch (_) {
      // Best-effort — the user already sees the load error.
    }
  }

  Future<void> _activate(SieveScript script) async {
    try {
      if (widget.isLocal) {
        await ref
            .read(localSieveRepositoryProvider)
            .activateScript(widget.accountId, script.id);
      } else {
        await ref
            .read(sieveRepositoryProvider)
            .activateScript(widget.accountId, script.id);
      }
      await _load();
      if (!mounted) return;
      final reloaded = _scripts?.firstWhere(
        (s) => s.id == script.id,
        orElse: () => script,
      );
      final took = reloaded?.isActive ?? false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(
            took
                ? 'Activated "${script.name}"'
                : 'Activation may not have taken effect — please refresh.',
          ),
        ),
      );
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.activate_failed',
              'Failed to activate sieve script',
              accountId: widget.accountId,
              data: {
                'scriptId': script.id,
                'scriptName': script.name,
                'isLocal': widget.isLocal,
              },
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('Failed to activate: $e'),
          ),
        );
      }
    }
  }

  Future<void> _deactivate(SieveScript script) async {
    try {
      if (widget.isLocal) {
        await ref
            .read(localSieveRepositoryProvider)
            .deactivateScript(widget.accountId);
      } else {
        await ref
            .read(sieveRepositoryProvider)
            .deactivateScript(widget.accountId);
      }
      await _load();
      if (!mounted) return;
      final reloaded = _scripts?.firstWhere(
        (s) => s.id == script.id,
        orElse: () => script,
      );
      final took = !(reloaded?.isActive ?? true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(
            took
                ? 'Deactivated "${script.name}"'
                : 'Deactivation may not have taken effect — please refresh.',
          ),
        ),
      );
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.deactivate_failed',
              'Failed to deactivate sieve script',
              accountId: widget.accountId,
              data: {
                'scriptId': script.id,
                'scriptName': script.name,
                'isLocal': widget.isLocal,
              },
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('Failed to deactivate: $e'),
          ),
        );
      }
    }
  }

  Future<void> _delete(SieveScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete script'),
        content: Text('Delete "${script.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    try {
      if (widget.isLocal) {
        await ref
            .read(localSieveRepositoryProvider)
            .deleteScript(widget.accountId, script.id);
      } else {
        await ref
            .read(sieveRepositoryProvider)
            .deleteScript(widget.accountId, script.id);
      }
      await _load();
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.delete_failed',
              'Failed to delete sieve script',
              accountId: widget.accountId,
              data: {
                'scriptId': script.id,
                'scriptName': script.name,
                'isLocal': widget.isLocal,
              },
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('Failed to delete: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isLocal ? 'Local Filters' : 'Remote Filters'),
      ),
      body: _buildBody(),
      floatingActionButton: _canAdd
          ? FloatingActionButton(
              onPressed: () async {
                await context.push(_editRoute);
                await _load();
              },
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  // Hide "+" while loading or when listScripts failed: adding a filter on
  // top of an unreachable server (e.g. TLS error) would just fail on save.
  bool get _canAdd => !_loading && _error == null;

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final scripts = _scripts ?? [];
    return Column(
      children: [
        _SieveSourceBanner(isLocal: widget.isLocal),
        Expanded(
          child: scripts.isEmpty
              ? const Center(
                  child: Text('No filters yet. Tap + to create one.'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: scripts.length,
                    itemBuilder: (ctx, i) => _ScriptTile(
                      script: scripts[i],
                      accountId: widget.accountId,
                      editRoute: _editRoute,
                      onActivate: () => _activate(scripts[i]),
                      onDeactivate: () => _deactivate(scripts[i]),
                      onDelete: () => _delete(scripts[i]),
                      onEdited: _load,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _SieveSourceBanner extends StatelessWidget {
  const _SieveSourceBanner({required this.isLocal});

  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final text = isLocal
        ? 'Local Filters run Sieve scripts directly on this device. '
            'Remote Filters, which run on the mail server, are configured separately.'
        : 'Remote Filters run Sieve scripts on the mail server '
            '(ManageSieve or JMAP). '
            'Local Filters, which run on this device, are configured separately.';
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isLocal ? Icons.phone_android : Icons.dns,
            size: AppIconSize.sm,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScriptTile extends StatelessWidget {
  const _ScriptTile({
    required this.script,
    required this.accountId,
    required this.editRoute,
    required this.onActivate,
    required this.onDeactivate,
    required this.onDelete,
    required this.onEdited,
  });

  final SieveScript script;
  final String accountId;
  final String editRoute;
  final VoidCallback onActivate;
  final VoidCallback onDeactivate;
  final VoidCallback onDelete;
  final VoidCallback onEdited;

  @override
  Widget build(BuildContext context) {
    // Inactive scripts read as a warning: most users expect filters to be
    // active, so a subtle warning tint + orange "Inactive" label make an
    // all-inactive list impossible to miss.
    final active = script.isActive;
    final warningColor = Colors.orange.shade800;
    final activeColor = Colors.green.shade700;
    return ListTile(
      tileColor: active ? null : Colors.orange.withValues(alpha: 0.06),
      title: Text(script.name),
      subtitle: Text(
        active ? 'Active' : 'Inactive',
        style: TextStyle(color: active ? activeColor : warningColor),
      ),
      leading: Icon(
        active ? Icons.filter_list : Icons.warning_amber_rounded,
        color: active ? activeColor : warningColor,
      ),
      trailing: PopupMenuButton<_ScriptAction>(
        onSelected: (action) async {
          switch (action) {
            case _ScriptAction.edit:
              await context.push(editRoute, extra: script);
              onEdited();
            case _ScriptAction.activate:
              onActivate();
            case _ScriptAction.deactivate:
              onDeactivate();
            case _ScriptAction.delete:
              onDelete();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: _ScriptAction.edit, child: Text('Edit')),
          if (active)
            const PopupMenuItem(
              value: _ScriptAction.deactivate,
              child: Text('Set inactive'),
            )
          else
            const PopupMenuItem(
              value: _ScriptAction.activate,
              child: Text('Set active'),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _ScriptAction.delete,
            child: Text('Delete'),
          ),
        ],
      ),
      onTap: () async {
        await context.push(editRoute, extra: script);
        onEdited();
      },
    );
  }
}

enum _ScriptAction { edit, activate, deactivate, delete }
