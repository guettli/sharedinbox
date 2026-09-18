import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:sharedinbox/core/services/image_shrink_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// What [ShrinkImageDialog] returns when the user accepts a shrunk image: the
/// re-encoded JPEG bytes and the settings that produced them (so the caller can
/// seed the next dialog with the same choices).
class ShrinkImageResult {
  const ShrinkImageResult({required this.bytes, required this.settings});

  final Uint8List bytes;
  final ImageShrinkSettings settings;
}

/// Dialog that previews shrinking an image: shows the original size, exposes
/// sliders for resolution, JPEG quality and colour reduction, and re-encodes
/// live so the resulting size is visible before the user commits.
///
/// Returns a [ShrinkImageResult] when the user keeps the shrunk version, or
/// `null` when they keep the original / cancel.
class ShrinkImageDialog extends StatefulWidget {
  const ShrinkImageDialog({
    super.key,
    required this.path,
    required this.service,
    this.initialSettings = ImageShrinkSettings.defaults,
  });

  final String path;
  final ImageShrinkService service;
  final ImageShrinkSettings initialSettings;

  static Future<ShrinkImageResult?> show(
    BuildContext context, {
    required String path,
    required ImageShrinkService service,
    ImageShrinkSettings initialSettings = ImageShrinkSettings.defaults,
  }) {
    return showDialog<ShrinkImageResult>(
      context: context,
      builder: (_) => ShrinkImageDialog(
        path: path,
        service: service,
        initialSettings: initialSettings,
      ),
    );
  }

  @override
  State<ShrinkImageDialog> createState() => _ShrinkImageDialogState();
}

class _ShrinkImageDialogState extends State<ShrinkImageDialog> {
  static const _minDimension = 200;

  late int _maxDimension = widget.initialSettings.maxDimension;
  late int _jpegQuality = widget.initialSettings.jpegQuality;
  bool _reduceColors = false;
  int _maxColors = 64;

  ImageProbe? _probe;
  bool _probing = true;
  Uint8List? _preview;
  bool _computing = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProbe());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  ImageShrinkSettings get _settings => ImageShrinkSettings(
        maxDimension: _maxDimension,
        jpegQuality: _jpegQuality,
        maxColors: _reduceColors ? _maxColors : 0,
      );

  Future<void> _loadProbe() async {
    final probe = await widget.service.probe(widget.path);
    if (!mounted) return;
    setState(() {
      _probe = probe;
      _probing = false;
      if (probe == null) {
        _error = 'This file is not a supported image.';
      } else {
        // Don't upscale — cap the slider at the original longest edge.
        final longest = probe.width > probe.height ? probe.width : probe.height;
        if (_maxDimension > longest) _maxDimension = longest;
      }
    });
    if (probe != null) await _recompute();
  }

  void _scheduleRecompute() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_recompute());
    });
  }

  Future<void> _recompute() async {
    if (_probe == null) return;
    setState(() => _computing = true);
    final bytes = await widget.service.shrink(widget.path, _settings);
    if (!mounted) return;
    setState(() {
      _preview = bytes;
      _computing = false;
      if (bytes == null) _error = 'Could not process this image.';
    });
  }

  (int, int) _resultDimensions(ImageProbe probe) {
    final longest = probe.width > probe.height ? probe.width : probe.height;
    if (longest <= _maxDimension) return (probe.width, probe.height);
    final scale = _maxDimension / longest;
    return ((probe.width * scale).round(), (probe.height * scale).round());
  }

  @override
  Widget build(BuildContext context) {
    final probe = _probe;
    return AlertDialog(
      title: const Text('Shrink image'),
      content: SizedBox(
        width: 360,
        child: _probing
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            : probe == null
                ? Text(_error ?? 'This file is not a supported image.')
                : _buildControls(context, probe),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep original'),
        ),
        FilledButton(
          onPressed: probe == null || _computing || _preview == null
              ? null
              : () => Navigator.of(context).pop(
                    ShrinkImageResult(bytes: _preview!, settings: _settings),
                  ),
          child: const Text('Use shrunk'),
        ),
      ],
    );
  }

  Widget _buildControls(BuildContext context, ImageProbe probe) {
    final theme = Theme.of(context);
    final (resultW, resultH) = _resultDimensions(probe);
    final preview = _preview;
    final longest = probe.width > probe.height ? probe.width : probe.height;
    final sliderMax = longest.toDouble();
    // For images smaller than the usual floor, let the slider go down to 1px so
    // its range stays valid (min < max) instead of collapsing.
    final sliderMin = longest <= _minDimension ? 1.0 : _minDimension.toDouble();
    final sliderValue = _maxDimension < sliderMin
        ? sliderMin
        : (_maxDimension > longest ? sliderMax : _maxDimension.toDouble());
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Original: ${probe.width} × ${probe.height} • '
            '${fmtSize(probe.sizeBytes)}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _computing || preview == null
                ? 'Result: $resultW × $resultH • …'
                : 'Result: $resultW × $resultH • ${fmtSize(preview.length)}'
                    '${_savingsLabel(probe.sizeBytes, preview.length)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Divider(height: AppSpacing.lg),
          Text('Max resolution (longest edge): $_maxDimension px'),
          Slider(
            value: sliderValue,
            min: sliderMin,
            max: sliderMax,
            label: '$_maxDimension px',
            onChanged: (v) {
              setState(() => _maxDimension = v.round());
              _scheduleRecompute();
            },
          ),
          Text('JPEG quality: $_jpegQuality'),
          Slider(
            value: _jpegQuality.toDouble(),
            min: 1,
            max: 100,
            label: '$_jpegQuality',
            onChanged: (v) {
              setState(() => _jpegQuality = v.round());
              _scheduleRecompute();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reduce colours'),
            value: _reduceColors,
            onChanged: (v) {
              setState(() => _reduceColors = v);
              _scheduleRecompute();
            },
          ),
          if (_reduceColors) ...[
            Text('Colours: $_maxColors'),
            Slider(
              value: _maxColors.toDouble(),
              min: 2,
              max: 256,
              label: '$_maxColors',
              onChanged: (v) {
                setState(() => _maxColors = v.round());
                _scheduleRecompute();
              },
            ),
          ],
        ],
      ),
    );
  }

  String _savingsLabel(int original, int result) {
    if (original <= 0 || result >= original) return '';
    final pct = (100 * (original - result) / original).round();
    return ' (−$pct%)';
  }
}
