// The mailbox overlay of SYNC-REDESIGN.md §7 (phases 5a and 5b), as pure
// functions: the mailbox ops, their fold into `mailboxes.local_name`,
// `local_parent` and `local_hidden`, and the display path the folder tree
// shows. No database access here, so the
// mailbox state writer and its tests share it.

import 'package:sharedinbox/data/db/keyword_fold.dart' show foldableOpStates;

/// `pending_changes.resource_type` of a mailbox op; its `resource_id` is a
/// `mailboxes.id` (frozen: a rename or a create's ack changes the row's
/// `path`, never its id).
const mailboxResourceType = 'Mailbox';

/// Creates the mailbox. Payload: [mailboxOpName] (the leaf name),
/// [mailboxOpParent] (the parent's `path`, absent at top level) and
/// [mailboxOpRole] (absent for none).
const createMailboxOp = 'create_mailbox';

/// Renames the mailbox (its leaf; the parent stays). Payload:
/// [mailboxOpName], the new name.
const renameMailboxOp = 'rename_mailbox';

/// Moves the mailbox below another one (its leaf name stays). Payload:
/// [mailboxOpParent], the new parent's `path` (null: top level), and
/// [mailboxOpFromParent], the parent it showed below when the move was
/// queued (null: top level), for Undo. Phase 5b.
const moveMailboxOp = 'move_mailbox';

/// Deletes the mailbox. Payload: [mailboxOpRemoveEmails], whether the user
/// confirmed deleting the mail it has (without it the server refuses a
/// folder with mail, so mail that arrived later is never deleted
/// silently). Phase 5b.
const deleteMailboxOp = 'delete_mailbox';

/// The mailbox ops that name the folder: their latest foldable one gives
/// `local_name`.
const mailboxNameOpTypes = [createMailboxOp, renameMailboxOp];

/// Every mailbox op.
const mailboxOpTypes = [
  createMailboxOp,
  renameMailboxOp,
  moveMailboxOp,
  deleteMailboxOp,
];

const mailboxOpName = 'name';
const mailboxOpParent = 'parent';
const mailboxOpRole = 'role';
const mailboxOpFromParent = 'fromParent';
const mailboxOpRemoveEmails = 'removeEmails';

/// Payload key an acked IMAP rename or move, and an acked delete, records:
/// the server path the folder had before, so a mailbox listing that started
/// before the ack (and still lists that path) does not bring the old folder
/// back.
const mailboxOpFromPath = 'fromPath';

/// The `path` prefix of a JMAP mailbox created offline, until the create's
/// ack gives it the server's id. `~` is not in the JMAP id alphabet
/// (RFC 8620 §1.2), so it cannot collide with a server id.
const localJmapMailboxPrefix = '~new:';

/// Payload keys of an email op that name a folder (a mailbox `path`).
const emailOpFolderKeys = ['dest', 'src', 'mailboxPath'];

/// One queued op of a mailbox, as far as the fold needs it.
class MailboxFoldOp {
  const MailboxFoldOp({
    required this.seq,
    required this.type,
    required this.name,
    required this.state,
    this.parent,
  });

  /// `pending_changes.id`: the fold applies ops in this order.
  final int seq;

  /// `pending_changes.change_type`.
  final String type;

  /// The payload's [mailboxOpName]; null when it has none.
  final String? name;

  /// `pending_changes.state`.
  final String state;

  /// A move's new parent `path`; `''` for the top level. Null for the
  /// other ops.
  final String? parent;
}

/// Folds a mailbox's ops into its `local_name`: the name of the latest
/// foldable ([foldableOpStates]) create or rename, or null when there is
/// none (the row shows the server's name).
String? foldMailboxName(Iterable<MailboxFoldOp> ops) {
  String? name;
  final sorted = [
    for (final op in ops)
      if (foldableOpStates.contains(op.state) &&
          mailboxNameOpTypes.contains(op.type) &&
          op.name != null)
        op,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  for (final op in sorted) {
    name = op.name;
  }
  return name;
}

/// Folds a mailbox's ops into its `local_parent`: the new parent of the
/// latest foldable move (`''` for the top level), or null when there is
/// none (the folder shows below the server's parent).
String? foldMailboxParent(Iterable<MailboxFoldOp> ops) {
  MailboxFoldOp? latest;
  for (final op in ops) {
    if (op.type != moveMailboxOp || !foldableOpStates.contains(op.state)) {
      continue;
    }
    if (latest == null || op.seq > latest.seq) latest = op;
  }
  return latest == null ? null : latest.parent ?? '';
}

/// Folds a mailbox's ops into its `local_hidden`: a foldable delete hides
/// the folder (everywhere: lists, counts, pickers, sync); a failed or
/// discarded one shows it again.
bool foldMailboxHidden(Iterable<MailboxFoldOp> ops) => ops.any(
      (op) => op.type == deleteMailboxOp && foldableOpStates.contains(op.state),
    );

/// Whether a mailbox created offline ([isLocal]) shows: only while its
/// `create_mailbox` op folds. A failed (or discarded) create hides it; its
/// mail goes back where the server has it.
bool localMailboxShown(Iterable<MailboxFoldOp> ops) => ops.any(
      (op) => op.type == createMailboxOp && foldableOpStates.contains(op.state),
    );

/// Whether the server's read of a mailbox ([srvName], and [srvParent], the
/// parent's `path`, null at the top level) agrees with an acked op: the
/// folder exists under the op's name, or below a move's parent.
bool mailboxReadAgrees(
  MailboxFoldOp op,
  String? srvName, {
  String? srvParent,
}) {
  if (op.type == moveMailboxOp) return (srvParent ?? '') == (op.parent ?? '');
  return srvName != null && srvName == op.name;
}

/// One mailbox row, as far as the display path needs it.
class DisplayPathRow {
  const DisplayPathRow({
    required this.path,
    required this.name,
    this.localName,
    this.srvName,
    this.parentId,
    this.localParent,
  });

  final String path;

  /// The server's name (`srv_name`), the leaf of an IMAP [path].
  final String? srvName;

  /// The effective name.
  final String name;

  /// The pending name (`local_name`): on IMAP it replaces the path's leaf.
  final String? localName;

  /// JMAP: the parent's `path` (server id or local stand-in).
  final String? parentId;

  /// IMAP: the parent a pending move puts the folder below (`''`: the top
  /// level); its subfolders follow. JMAP folds it into [parentId].
  final String? localParent;
}

/// The `display_path` of every row in [rows] (one account), keyed by
/// `path`: the human-readable path the folder tree splits on `/`.
///
/// JMAP ([jmap]): the effective names along the `parentId` chain joined
/// with `/`; an ancestor that is not cached truncates the path rather than
/// showing its opaque id (#605).
///
/// IMAP: the server path, as sync always stored it, with the leaf of every
/// folder that has a pending name (a rename, or a folder created offline)
/// replaced by that name, and the parent of every folder with a pending
/// move replaced by the display path of its new parent, also inside its
/// subfolders' paths. A folder's
/// parent is the cached folder with the longest path that is a prefix of
/// its path followed by the account's hierarchy [separator] (so on a `/`
/// server "Mr. Smith" is no subfolder of "Mr").
Map<String, String> displayPaths(
  List<DisplayPathRow> rows, {
  required bool jmap,
  String separator = '/',
}) {
  final byPath = {for (final r in rows) r.path: r};
  final out = <String, String>{};
  if (jmap) {
    for (final r in rows) {
      final parts = <String>[];
      String? current = r.path;
      final seen = <String>{};
      while (current != null && current.isNotEmpty && seen.add(current)) {
        final row = byPath[current];
        if (row == null) break;
        parts.insert(0, row.name);
        current = row.parentId;
      }
      out[r.path] = parts.join('/');
    }
    return out;
  }
  final sortedPaths = byPath.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  DisplayPathRow? parentOf(DisplayPathRow row) {
    for (final p in sortedPaths) {
      if (p.length >= row.path.length) continue;
      if (!row.path.startsWith(p)) continue;
      if (row.path.startsWith(separator, p.length)) return byPath[p];
    }
    return null;
  }

  String display(DisplayPathRow row, Set<String> visiting) {
    final known = out[row.path];
    if (known != null) return known;
    if (!visiting.add(row.path)) return row.path;
    final parent = parentOf(row);
    final String result;
    final local = row.localName;
    final srv = row.srvName;
    final moved = row.localParent;
    if (moved != null) {
      // A pending move: below its new parent (or at the top level), with
      // its own (pending or server) leaf name.
      final cut = row.path.lastIndexOf(separator);
      final leaf = local ??
          (cut < 0 ? row.path : row.path.substring(cut + separator.length));
      final target = moved.isEmpty ? null : byPath[moved];
      final base = moved.isEmpty
          ? ''
          : target == null
              ? moved
              : display(target, visiting);
      result = base.isEmpty ? leaf : '$base$separator$leaf';
    } else if (parent == null) {
      // A top-level folder, or one whose parent is not cached: only a
      // known leaf is replaced.
      if (local == null) {
        result = row.path;
      } else if (srv != null && row.path.endsWith(srv)) {
        result = '${row.path.substring(0, row.path.length - srv.length)}'
            '$local';
      } else {
        result = local;
      }
    } else {
      final leaf = row.path.substring(parent.path.length + separator.length);
      result = '${display(parent, visiting)}$separator${local ?? leaf}';
    }
    out[row.path] = result;
    return result;
  }

  for (final r in rows) {
    display(r, <String>{});
  }
  return out;
}

/// The parent a mailbox shows below on JMAP: its pending move's parent
/// ([localParent], `''` for the top level) when it has one, else the
/// server's ([parentId]). IMAP keeps the hierarchy in the path: null there.
String? effectiveMailboxParent({
  required String? parentId,
  required String? localParent,
}) {
  if (localParent == null) return parentId;
  return localParent.isEmpty ? null : localParent;
}
