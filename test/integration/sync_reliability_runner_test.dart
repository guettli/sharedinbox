import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../scripts/sync_reliability.dart' as reliability;

void main() {
  test('sync reliability script runner', timeout: Timeout.none, () async {
    final rawArgs = Platform.environment['SYNC_RELIABILITY_ARGS'];
    final args = rawArgs == null || rawArgs.isEmpty
        ? const <String>[]
        : const LineSplitter().convert(rawArgs);
    await reliability.runSyncReliability(args);
  });
}
