import 'package:flutter/material.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';

enum _MissingFolderChoice { chooseExisting, createNew }

/// Resolves a mailbox by role, prompting the user to choose or create one when
/// the role is not found.  Returns the target [Mailbox], or null if cancelled.
Future<Mailbox?> resolveMailboxByRole(
  BuildContext context,
  MailboxRepository mailboxRepo,
  String accountId,
  String currentMailboxPath,
  String role, {
  required String dialogTitle,
  required String createFolderName,
}) async {
  Mailbox? mailbox = await mailboxRepo.findMailboxByRole(accountId, role);
  if (!context.mounted) return null;
  if (mailbox != null) return mailbox;

  final choice = await showDialog<_MissingFolderChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(dialogTitle),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, _MissingFolderChoice.chooseExisting),
          child: const Text('Choose existing folder'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, _MissingFolderChoice.createNew),
          child: Text('Create "$createFolderName"'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return null;

  switch (choice) {
    case _MissingFolderChoice.chooseExisting:
      final mailboxes = await mailboxRepo.observeMailboxes(accountId).first;
      if (!context.mounted) return null;
      final chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Move to…',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final m
                in mailboxes.where((m) => m.path != currentMailboxPath))
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(m.name),
                onTap: () => Navigator.pop(ctx, m.path),
              ),
          ],
        ),
      );
      if (chosen == null || !context.mounted) return null;
      mailbox = mailboxes.firstWhere((m) => m.path == chosen);
    case _MissingFolderChoice.createNew:
      mailbox = await mailboxRepo.createMailboxWithRole(
        accountId,
        createFolderName,
        role,
      );
      if (!context.mounted) return null;
  }

  return mailbox;
}
