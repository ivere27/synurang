import 'dart:io' show File, InternetAddress, InternetAddressType;
import 'package:grpc/grpc.dart' as grpc;
import 'package:synurang/synurang.dart' hide Duration;
import 'transport_config.dart';
import 'dart_greeter_service.dart';
import 'generated/example.pbgrpc.dart' as pbgrpc;

// =============================================================================
// Server Manager - Manages Flutter and Go gRPC server lifecycle
// =============================================================================

class ServerManager {
  final void Function(String) onLog;

  // Server state
  grpc.Server? _flutterUdsServer;
  grpc.Server? _flutterTcpServer;
  grpc.ClientChannel? _goClientChannel;
  String? _flutterSocketPath;
  String? _goSocketPath;

  // Configuration
  String token;
  bool goUdsRunning = false;
  bool goTcpRunning = false;
  bool flutterUdsRunning = false;
  bool flutterTcpRunning = false;

  ServerManager({required this.onLog, required this.token});

  // ===========================================================================
  // Flutter gRPC Server (UDS)
  // ===========================================================================

  Future<void> startFlutterUdsServer() async {
    if (_flutterUdsServer != null) {
      onLog('Flutter UDS server already running');
      return;
    }

    _flutterSocketPath = await getTempSocketPath('flutter_view');
    final service = DartGreeterServiceImplForGrpc(
      onLog: (msg) => onLog('📥 [UDS] $msg'),
    );

    final server = grpc.Server.create(
      services: [service],
      codecRegistry: grpc.CodecRegistry(
        codecs: const [grpc.GzipCodec(), grpc.IdentityCodec()],
      ),
    );

    final socketFile = File(_flutterSocketPath!);
    if (await socketFile.exists()) await socketFile.delete();

    final address = InternetAddress(
      _flutterSocketPath!,
      type: InternetAddressType.unix,
    );
    await server.serve(address: address, port: 0);
    _flutterUdsServer = server;
    flutterUdsRunning = true;
    onLog('✅ Flutter UDS server started: $_flutterSocketPath');
  }

  Future<void> stopFlutterUdsServer() async {
    if (_flutterUdsServer == null) return;
    await _flutterUdsServer!.shutdown();
    _flutterUdsServer = null;
    flutterUdsRunning = false;

    if (_flutterSocketPath != null) {
      final file = File(_flutterSocketPath!);
      if (await file.exists()) await file.delete();
      // Cleanup temp directory
      try {
        await file.parent.delete();
      } catch (e) {
        // Ignore if not empty or other error
      }
      _flutterSocketPath = null;
    }
    onLog('Flutter UDS server stopped');
  }

  // ===========================================================================
  // Flutter gRPC Server (TCP)
  // ===========================================================================

  Future<void> startFlutterTcpServer() async {
    if (_flutterTcpServer != null) {
      onLog('Flutter TCP server already running');
      return;
    }

    final service = DartGreeterServiceImplForGrpc(
      onLog: (msg) => onLog('📥 [TCP] $msg'),
    );

    final server = grpc.Server.create(
      services: [service],
      codecRegistry: grpc.CodecRegistry(
        codecs: const [grpc.GzipCodec(), grpc.IdentityCodec()],
      ),
    );

    await server.serve(port: kDefaultFlutterTcpPort);
    _flutterTcpServer = server;
    flutterTcpRunning = true;
    onLog('✅ Flutter TCP server started on port $kDefaultFlutterTcpPort');
  }

  Future<void> stopFlutterTcpServer() async {
    if (_flutterTcpServer == null) return;
    await _flutterTcpServer!.shutdown();
    _flutterTcpServer = null;
    flutterTcpRunning = false;
    onLog('Flutter TCP server stopped');
  }

  // ===========================================================================
  // Go gRPC Server (via FFI)
  // ===========================================================================

  Future<void> startGoServer({bool uds = false, bool tcp = false}) async {
    String engineSocketPath = '';
    String engineTcpPort = '';
    String viewSocketPath = '';
    String viewTcpPort = '';

    if (uds) {
      _goSocketPath = await getTempSocketPath('go_engine');
      engineSocketPath = _goSocketPath!;
      goUdsRunning = true;
      onLog('Go UDS server: $engineSocketPath');
    }

    if (tcp) {
      engineTcpPort = kDefaultGoTcpPort.toString();
      goTcpRunning = true;
      onLog('Go TCP server: port $engineTcpPort');
    }

    // If Flutter servers are running, configure Go to connect to them
    if (flutterUdsRunning && _flutterSocketPath != null) {
      viewSocketPath = _flutterSocketPath!;
    }
    if (flutterTcpRunning) {
      viewTcpPort = kDefaultFlutterTcpPort.toString();
    }

    await startGrpcServerAsync(
      engineSocketPath: engineSocketPath,
      engineTcpPort: engineTcpPort,
      viewSocketPath: viewSocketPath,
      viewTcpPort: viewTcpPort,
      token: token,
    );

    // Wait for Go to create the socket file
    if (uds && _goSocketPath != null) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (await File(_goSocketPath!).exists()) break;
      }
    }

    // Register Dart handler for FFI callbacks
    startDartGreeterHandler(onLog: (msg) => onLog('📥 [FFI] $msg'));
    onLog('✅ Go server started (UDS: $goUdsRunning, TCP: $goTcpRunning)');
  }

  Future<void> stopGoServer() async {
    await stopGrpcServerAsync();
    goUdsRunning = false;
    goTcpRunning = false;
    if (_goSocketPath != null) {
      final file = File(_goSocketPath!);
      if (await file.exists()) await file.delete();
      // Cleanup temp directory
      try {
        await file.parent.delete();
      } catch (e) {
        // Ignore
      }
      _goSocketPath = null;
    }
    onLog('Go server stopped');
  }

  // ===========================================================================
  // Go gRPC Client (for Flutter→Go when UDS/TCP)
  // ===========================================================================

  Future<void> connectGoClient({TransportMode mode = TransportMode.ffi}) async {
    await disconnectGoClient();

    if (mode == TransportMode.ffi) {
      _goClientChannel = FfiClientChannel();
      onLog('Flutter→Go gRPC client connected via FFI');
    } else if (mode == TransportMode.uds && _goSocketPath != null) {
      _goClientChannel = grpc.ClientChannel(
        InternetAddress(_goSocketPath!, type: InternetAddressType.unix),
        port: 0,
        options: const grpc.ChannelOptions(
          credentials: grpc.ChannelCredentials.insecure(),
        ),
      );
      onLog('Flutter→Go gRPC client connected via UDS');
    } else if (mode == TransportMode.tcp) {
      _goClientChannel = grpc.ClientChannel(
        'localhost',
        port: kDefaultGoTcpPort,
        options: const grpc.ChannelOptions(
          credentials: grpc.ChannelCredentials.insecure(),
        ),
      );
      onLog('Flutter→Go gRPC client connected via TCP');
    }
  }

  Future<void> disconnectGoClient() async {
    if (_goClientChannel != null) {
      await _goClientChannel!.shutdown();
      _goClientChannel = null;
    }
  }

  pbgrpc.GoGreeterServiceClient? getGoGreeterClient() {
    if (_goClientChannel == null) return null;
    return pbgrpc.GoGreeterServiceClient(
      _goClientChannel!,
      options: grpc.CallOptions(metadata: {'authorization': 'Bearer $token'}),
    );
  }

  grpc.ClientChannel? get goClientChannel => _goClientChannel;
  String? get flutterSocketPath => _flutterSocketPath;
  String? get goSocketPath => _goSocketPath;

  // ===========================================================================
  // Cleanup
  // ===========================================================================

  Future<void> dispose() async {
    await disconnectGoClient();
    await stopFlutterUdsServer();
    await stopFlutterTcpServer();
    await stopGoServer();
  }
}
