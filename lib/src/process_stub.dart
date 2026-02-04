// Stub implementation for non-IO platforms (web)
// This file is used when dart.library.io is not available.

import 'process.dart';

Future<SynurangProcess> startProcess(
  String executable, {
  List<String>? arguments,
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  throw UnsupportedError('SynurangProcess is not supported on this platform');
}
