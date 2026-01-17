import 'dart:io' show Directory, Platform;

// =============================================================================
// Transport Mode Configuration
// =============================================================================

/// Transport mode options (FFI is the default for maximum performance)
enum TransportMode { ffi, uds, tcp }

/// Default ports for TCP connections
const int kDefaultGoTcpPort = 18000;
const int kDefaultFlutterTcpPort = 10050;

/// Get a unique socket path for a service, checking environment override first
Future<String> getTempSocketPath(String name) async {
  // Check for compile-time overrides via --dart-define
  if (name == 'go_engine' && const bool.hasEnvironment('GO_SOCKET')) {
    return const String.fromEnvironment('GO_SOCKET');
  }
  if (name == 'flutter_view' && const bool.hasEnvironment('FLUTTER_SOCKET')) {
    return const String.fromEnvironment('FLUTTER_SOCKET');
  }

  // Check for runtime overrides (OS environment variables)
  String envKey = name == 'go_engine' ? 'GO_SOCKET' : 'FLUTTER_SOCKET';
  if (Platform.environment.containsKey(envKey)) {
    return Platform.environment[envKey]!;
  }

  final tmpDir = await Directory.systemTemp.createTemp('synura_');
  return '${tmpDir.path}/$name.sock';
}

/// Generate a random token for authentication
String generateToken() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return 'token-${now.toRadixString(36)}';
}
