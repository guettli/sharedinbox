import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

/// Loads blob [itemId] of the entry's collection; null when it cannot be
/// had now (offline, not synced yet).
typedef EntryImageLoader = Future<({String contentType, Uint8List bytes})?>
    Function(String itemId);

/// Renders the Markdown body of an entry (#1376).
///
/// Task-list checkboxes call [onToggleTask] with their index in document
/// order (see `markdown_tasks.dart`); without it they are read-only.
/// `si-img:` images are blobs (#1377), resolved by [loadImage] from the
/// blob cache and downloaded on demand, with a placeholder meanwhile. No
/// image URL is ever fetched: `cid:`, `http(s):` and the rest stay a
/// placeholder, so encrypted notes load no remote content.
class EntryMarkdown extends StatelessWidget {
  const EntryMarkdown({
    super.key,
    required this.body,
    this.onToggleTask,
    this.loadImage,
  });

  final String body;
  final ValueChanged<int>? onToggleTask;
  final EntryImageLoader? loadImage;

  @override
  Widget build(BuildContext context) {
    // The checkbox builder runs once per checkbox, in document order, each
    // time the body is parsed.
    var next = 0;
    return MarkdownBody(
      data: body,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      onTapLink: (text, href, title) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri == null) return;
        if (uri.scheme != 'http' && uri.scheme != 'https') return;
        unawaited(_launch(context, uri));
      },
      checkboxBuilder: (checked) {
        final index = next++;
        final onToggle = onToggleTask;
        return Checkbox(
          key: Key('entryTask_$index'),
          value: checked,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: onToggle == null ? null : (_) => onToggle(index),
        );
      },
      imageBuilder: (uri, title, alt) {
        final id = siImageId(uri);
        final load = loadImage;
        if (id == null || load == null) {
          return _ImagePlaceholder(alt: alt ?? title ?? '');
        }
        return _SiImage(
          key: ValueKey(id),
          itemId: id,
          alt: alt ?? title ?? '',
          load: load,
        );
      },
    );
  }

  Future<void> _launch(BuildContext context, Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      if (!context.mounted) return;
      context.showAppSnackBar('Could not open browser.');
    } catch (e) {
      if (!context.mounted) return;
      context.showAppSnackBar('Error: ${userErrorMessage(e)}');
    }
  }
}

/// The largest width an image is shown at.
const _maxImageWidth = 480.0;

/// Blob [itemId], loaded once per [itemId]; a placeholder while it loads,
/// and one to tap for another try when it could not be had.
class _SiImage extends StatefulWidget {
  const _SiImage({
    super.key,
    required this.itemId,
    required this.alt,
    required this.load,
  });

  final String itemId;
  final String alt;
  final EntryImageLoader load;

  @override
  State<_SiImage> createState() => _SiImageState();
}

class _SiImageState extends State<_SiImage> {
  late Future<({String contentType, Uint8List bytes})?> _image;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  @override
  void didUpdateWidget(_SiImage old) {
    super.didUpdateWidget(old);
    if (old.itemId == widget.itemId) return;
    _image = _load();
  }

  Future<({String contentType, Uint8List bytes})?> _load() async {
    try {
      return await widget.load(widget.itemId);
    } catch (_) {
      // Shown as the retry placeholder.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _ImagePlaceholder(
            key: const Key('entryImageLoading'),
            alt: widget.alt,
            loading: true,
          );
        }
        final image = snapshot.data;
        if (image == null) {
          return InkWell(
            key: const Key('entryImageRetry'),
            onTap: () => setState(() {
              _image = _load();
            }),
            child: _ImagePlaceholder(alt: widget.alt, retry: true),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxImageWidth),
          child: Image.memory(
            image.bytes,
            key: Key('entryImage_${widget.itemId}'),
            semanticLabel: widget.alt.isEmpty ? null : widget.alt,
            errorBuilder: (_, __, ___) => _ImagePlaceholder(alt: widget.alt),
          ),
        );
      },
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({
    Key? key,
    required this.alt,
    this.loading = false,
    this.retry = false,
  }) : super(key: key ?? const Key('entryImagePlaceholder'));

  final String alt;
  final bool loading;
  final bool retry;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading)
          const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(retry ? Icons.refresh : Icons.image_outlined),
        if (alt.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: Text(alt)),
        ],
      ],
    );
  }
}
