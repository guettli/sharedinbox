import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/di.dart';

class SieveScriptEditScreen extends ConsumerStatefulWidget {
  const SieveScriptEditScreen({
    super.key,
    required this.accountId,
    this.script,
  });

  final String accountId;

  /// Null when creating a new script.
  final SieveScript? script;

  @override
  ConsumerState<SieveScriptEditScreen> createState() =>
      _SieveScriptEditScreenState();
}

class _SieveScriptEditScreenState extends ConsumerState<SieveScriptEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _contentController;
  bool _loadingContent = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.script?.name ?? '');
    _contentController = TextEditingController();
    if (widget.script != null) {
      unawaited(_loadContent());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _loadContent() async {
    setState(() => _loadingContent = true);
    try {
      final content = await ref.read(sieveRepositoryProvider).getScriptContent(
            widget.accountId,
            widget.script!.blobId,
          );
      if (mounted) {
        _contentController.text = content;
        setState(() => _loadingContent = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loadingContent = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(sieveRepositoryProvider).saveScript(
            widget.accountId,
            id: widget.script?.id,
            name: name,
            content: _contentController.text,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.script == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New script' : 'Edit script'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _save,
              tooltip: 'Save',
            ),
        ],
      ),
      body: _loadingContent
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    enabled: !_saving,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _contentController,
                      decoration: const InputDecoration(
                        labelText: 'Script',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'monospace'),
                      enabled: !_saving,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
