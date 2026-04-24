import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/di.dart';

class SieveScriptsScreen extends ConsumerStatefulWidget {
  const SieveScriptsScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<SieveScriptsScreen> createState() => _SieveScriptsScreenState();
}

class _SieveScriptsScreenState extends ConsumerState<SieveScriptsScreen> {
  List<SieveScript>? _scripts;
  String? _error;
  bool _loading = true;

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
      final scripts =
          await ref.read(sieveRepositoryProvider).listScripts(widget.accountId);
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
      await ref
          .read(sieveRepositoryProvider)
          .activateScript(widget.accountId, script.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to activate: $e')),
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
      await ref
          .read(sieveRepositoryProvider)
          .deleteScript(widget.accountId, script.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Email filters')),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await context.push(
            '/accounts/${widget.accountId}/sieve/edit',
          );
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
              FilledButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final scripts = _scripts ?? [];
    if (scripts.isEmpty) {
      return const Center(
        child: Text('No Sieve scripts. Tap + to create one.'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: scripts.length,
        itemBuilder: (ctx, i) => _ScriptTile(
          script: scripts[i],
          accountId: widget.accountId,
          onActivate: () => _activate(scripts[i]),
          onDelete: () => _delete(scripts[i]),
          onEdited: _load,
        ),
      ),
    );
  }
}

class _ScriptTile extends StatelessWidget {
  const _ScriptTile({
    required this.script,
    required this.accountId,
    required this.onActivate,
    required this.onDelete,
    required this.onEdited,
  });

  final SieveScript script;
  final String accountId;
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
              await context.push(
                '/accounts/$accountId/sieve/edit',
                extra: script,
              );
              onEdited();
            case _ScriptAction.activate:
              onActivate();
            case _ScriptAction.delete:
              onDelete();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: _ScriptAction.edit,
            child: Text('Edit'),
          ),
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
        await context.push(
          '/accounts/$accountId/sieve/edit',
          extra: script,
        );
        onEdited();
      },
    );
  }
}

enum _ScriptAction { edit, activate, delete }
