import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/di.dart';

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
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
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
    } catch (e) {
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
    } catch (e) {
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
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await context.push(_editRoute);
          await _load();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isLocal ? Icons.phone_android : Icons.dns,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
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
    required this.onDelete,
    required this.onEdited,
  });

  final SieveScript script;
  final String accountId;
  final String editRoute;
  final VoidCallback onActivate;
  final VoidCallback onDelete;
  final VoidCallback onEdited;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(script.name),
      subtitle: script.isActive ? const Text('Active') : null,
      leading: Icon(
        Icons.filter_list,
        color: script.isActive ? Colors.green : null,
      ),
      trailing: PopupMenuButton<_ScriptAction>(
        onSelected: (action) async {
          switch (action) {
            case _ScriptAction.edit:
              await context.push(editRoute, extra: script);
              onEdited();
            case _ScriptAction.activate:
              onActivate();
            case _ScriptAction.delete:
              onDelete();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: _ScriptAction.edit, child: Text('Edit')),
          if (!script.isActive)
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

enum _ScriptAction { edit, activate, delete }
