import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';

class AddressEmailsScreen extends ConsumerStatefulWidget {
  const AddressEmailsScreen({
    super.key,
    required this.accountId,
    required this.address,
  });

  final String accountId;
  final String address;

  @override
  ConsumerState<AddressEmailsScreen> createState() =>
      _AddressEmailsScreenState();
}

class _AddressEmailsScreenState extends ConsumerState<AddressEmailsScreen> {
  List<Email>? _emails;
  bool _loading = true;

  late final EmailThreadListController _selection;

  @override
  void initState() {
    super.initState();
    _selection = EmailThreadListController()..addListener(_onSelectionChange);
    unawaited(_load());
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChange)
      ..dispose();
    super.dispose();
  }

  void _onSelectionChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final emails = await ref
        .read(emailRepositoryProvider)
        .getEmailsByAddress(widget.accountId, widget.address);
    if (mounted) {
      setState(() {
        _emails = emails;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selection.isSelecting;
    return Scaffold(
      appBar: selecting
          ? buildSelectionAppBar(_selection)
          : AppBar(title: Text(widget.address)),
      bottomNavigationBar: selecting
          ? buildSelectionBottomBar(
              context,
              ref,
              _selection,
              onAfterAction: _onAfterBatchAction,
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : EmailThreadList(
              controller: _selection,
              items: _emails!.map(EmailThread.fromEmail).toList(),
              enableSwipe: false,
              showLocationLabel: true,
            ),
    );
  }

  void _onAfterBatchAction(List<String> actedThreadIds) {
    if (_emails == null || !mounted) return;
    final actedSet = actedThreadIds.toSet();
    final remaining =
        _emails!.where((e) => !actedSet.contains(e.threadId ?? e.id)).toList();
    setState(() => _emails = remaining);
  }
}
