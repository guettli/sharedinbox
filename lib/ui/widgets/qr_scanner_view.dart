import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:sharedinbox/di.dart';

/// Camera QR scanner with graceful fallbacks, shared by the account-sharing
/// flow (`AccountSendScreen` / `AccountReceiveScreen`).
///
/// Renders [fallbackBuilder] (a text-paste UI) instead of the camera when:
///  * the platform has no camera support ([_cameraScanSupported] is false);
///  * the scanner plugin is not registered (MissingPluginException at the
///    pre-flight probe, issue #204);
///  * the camera fails to start at runtime — e.g. a native NullPointerException
///    on some Android builds (issue #542) — surfaced via [MobileScanner]'s own
///    `errorBuilder`, which would otherwise leave the user on a dead-end error
///    screen.
///
/// [onDetect] receives the raw value of the first decoded barcode; it returns
/// `true` when the value was accepted (the parent transitions away and this
/// widget unmounts) or `false` to keep scanning (e.g. an invalid code). The
/// camera is paused while [onDetect] runs and resumed if it returns `false`.
/// [overlayBuilder] is stacked on top of the camera preview.
/// [logEvent]/[screen] identify the runtime-failure App Log entry.
class QrScannerView extends ConsumerStatefulWidget {
  const QrScannerView({
    super.key,
    required this.onDetect,
    required this.fallbackBuilder,
    required this.logEvent,
    required this.screen,
    this.overlayBuilder,
  });

  final Future<bool> Function(String raw) onDetect;
  final WidgetBuilder fallbackBuilder;
  final String logEvent;
  final String screen;
  final WidgetBuilder? overlayBuilder;

  /// Test seam: when non-null, replaces the [MobileScanner] widget so the
  /// camera error path can be exercised on hosts without a camera. Receives the
  /// scan callback and the error builder used when the camera fails to start.
  /// Null in production, where the real scanner is used.
  @visibleForTesting
  static Widget Function(
    BuildContext context,
    void Function(String raw) onDetect,
    Widget Function(BuildContext, MobileScannerException) errorBuilder,
  )? debugScannerBuilder;

  @override
  ConsumerState<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends ConsumerState<QrScannerView> {
  MobileScannerController? _controller;
  // True once the camera fails to start; pins the view to the text fallback.
  bool _scannerFailed = false;
  // Guards against re-entrant detections while [onDetect] is in flight.
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    if (QrScannerView.debugScannerBuilder == null && _cameraScanSupported()) {
      unawaited(_initScanner());
    }
  }

  @override
  void dispose() {
    final ctrl = _controller;
    if (ctrl != null) unawaited(ctrl.dispose());
    super.dispose();
  }

  // Pre-flight: probe the scanner's permission-state method to verify the
  // plugin is registered.  MissingPluginException is thrown on Android builds
  // where the plugin is not linked (issue #204).  All other exceptions mean
  // the plugin exists but something else failed — the MobileScanner widget
  // will surface those via its own error builder.
  Future<void> _initScanner() async {
    bool available = false;
    try {
      await const MethodChannel(
        'dev.steenbakker.mobile_scanner/scanner/method',
      ).invokeMethod<int>('state');
      available = true;
    } on MissingPluginException {
      // Plugin not registered on this device; text fallback will be shown.
    } catch (_) {
      // Plugin registered but state check failed; let the scanner widget
      // handle it via its errorBuilder.
      available = true;
    }
    if (!mounted) return;
    if (available) {
      setState(() => _controller = MobileScannerController());
    } else {
      setState(() => _scannerFailed = true);
    }
  }

  Future<void> _handleDetect(String raw) async {
    if (_processing) return;
    _processing = true;
    await _controller?.stop();
    final handled = await widget.onDetect(raw);
    // If handled, the parent transitions away and this widget unmounts (which
    // disposes the controller); otherwise resume scanning to allow a retry.
    if (!handled && mounted) {
      _processing = false;
      await _controller?.start();
    }
  }

  // Called by MobileScanner when the camera fails to start (e.g. a native
  // NullPointerException on some Android builds, issue #542). Logs once and
  // drops to the text-entry fallback so the transfer can still be completed by
  // pasting the code, instead of leaving the user on a dead-end error screen.
  Widget _scannerErrorFallback(BuildContext context, MobileScannerException e) {
    if (!_scannerFailed) {
      unawaited(
        ref.read(appLoggerProvider).error(
              widget.logEvent,
              'Camera scanner failed to start; falling back to manual paste',
              screen: widget.screen,
              error: e,
            ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _scannerFailed = true);
      });
    }
    return widget.fallbackBuilder(context);
  }

  @override
  Widget build(BuildContext context) {
    final debugBuilder = QrScannerView.debugScannerBuilder;
    if (debugBuilder == null && (!_cameraScanSupported() || _scannerFailed)) {
      return widget.fallbackBuilder(context);
    }
    if (debugBuilder == null && _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    void onDetect(String raw) => unawaited(_handleDetect(raw));

    return Stack(
      children: [
        if (debugBuilder != null)
          debugBuilder(context, onDetect, _scannerErrorFallback)
        else
          MobileScanner(
            controller: _controller!,
            errorBuilder: _scannerErrorFallback,
            onDetect: (capture) {
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (raw != null) onDetect(raw);
            },
          ),
        if (widget.overlayBuilder != null) widget.overlayBuilder!(context),
      ],
    );
  }
}

bool _cameraScanSupported() =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows;
