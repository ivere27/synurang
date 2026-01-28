import 'dart:async';
import 'package:flutter/material.dart';
import 'package:synurang/synurang.dart' hide Duration;

import 'src/transport_config.dart';
import 'src/server_manager.dart';
import 'src/dart_greeter_service.dart';
import 'src/widgets/header_controls.dart';
import 'src/widgets/test_card.dart';
import 'src/pages/file_test_page.dart';  // Import FileTestPage
import 'src/widgets/log_panel.dart';
import 'src/generated/example.pb.dart' as pb;

void main() async {
  configureSynurang(libraryName: 'synura_example');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SynuraExampleApp());
}

class SynuraExampleApp extends StatelessWidget {
  const SynuraExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Synurang Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0B14),
      ),
      home: const TestSuitePage(),
    );
  }
}

// =============================================================================
// Test Suite Page
// =============================================================================

class TestSuitePage extends StatefulWidget {
  const TestSuitePage({super.key});

  @override
  State<TestSuitePage> createState() => _TestSuitePageState();
}

class _TestSuitePageState extends State<TestSuitePage> {
  late final ServerManager _serverManager;
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();
  bool _showFileTests = false; // Toggle for File Test Page
  // Allow overriding token via --dart-define=TOKEN=... for testing
  String _token = const String.fromEnvironment('TOKEN', defaultValue: '');
  bool _isRunningAll = false;
  final bool _isRunningAllMixed = false;

  final Map<String, TestResult> _results = {
    'd2g_unary': TestResult(),
    'd2g_server_stream': TestResult(),
    'd2g_client_stream': TestResult(),
    'd2g_bidi_stream': TestResult(),
    'g2d_unary': TestResult(),
    'g2d_server_stream': TestResult(),
    'g2d_client_stream': TestResult(),
    'g2d_bidi_stream': TestResult(),
  };

  @override
  void initState() {
    super.initState();
    if (_token.isEmpty) {
      _token = generateToken();
    }
    _serverManager = ServerManager(onLog: _addLog, token: _token);
    _initServers();
  }

  Future<void> _initServers() async {
    // Start with FFI-only (no UDS/TCP toggles selected)
    await _serverManager.startGoServer();
    // Connect using FfiClientChannel for FFI mode
    await _serverManager.connectGoClient(mode: TransportMode.ffi);
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add('[${_formatTime(DateTime.now())}] $message');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  void _updateResult(String key, TestResult result) {
    setState(() => _results[key] = result);
  }

  // ===========================================================================
  // Test Methods
  // ===========================================================================

  Future<void> _runD2GUnary() async {
    const key = 'd2g_unary';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Dart → Go Unary [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      pb.HelloResponse response;
      final client = _serverManager.getGoGreeterClient();
      // Debug log (can remove or keep simplistic)
      // _addLog('  Token: ${_serverManager.token}, Client: ${client != null ? "gRPC" : "FFI"}');

      if (client != null) {
        response = await client.bar(
          pb.HelloRequest()
            ..name = 'World'
            ..language = 'en',
        );
      } else {
        response = await GoGreeterClient.bar('World', language: 'en');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ D2G Unary: ${response.message} (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Unary failed: $e');
    }
  }

  Future<void> _runD2GServerStream() async {
    const key = 'd2g_server_stream';
    _updateResult(
      key,
      TestResult(status: TestStatus.running, streamMessages: []),
    );
    _addLog('Running: Dart → Go Server Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    final messages = <String>[];

    try {
      Stream<pb.HelloResponse> stream;
      final client = _serverManager.getGoGreeterClient();

      if (client != null) {
        stream = client.barServerStream(pb.HelloRequest()..name = 'World');
      } else {
        stream = GoGreeterClient.barServerStream('World');
      }

      await for (final response in stream) {
        messages.add(response.message);
        _updateResult(
          key,
          TestResult(
            status: TestStatus.running,
            streamMessages: List.from(messages),
          ),
        );
        _addLog('  📥 ${response.message}');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: '${messages.length} messages',
          durationMs: stopwatch.elapsedMilliseconds,
          streamMessages: messages,
        ),
      );
      _addLog(
        '✅ D2G Server Stream: ${messages.length} msgs (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Server Stream failed: $e');
    }
  }

  Future<void> _runD2GClientStream() async {
    const key = 'd2g_client_stream';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Dart → Go Client Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      final requests = Stream.fromIterable([
        pb.HelloRequest()..name = 'Alice',
        pb.HelloRequest()..name = 'Bob',
        pb.HelloRequest()..name = 'Charlie',
      ]);

      pb.HelloResponse response;
      final client = _serverManager.getGoGreeterClient();
      if (client != null) {
        response = await client.barClientStream(requests);
      } else {
        response = await GoGreeterClient.barClientStream(requests);
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ D2G Client Stream: ${response.message} (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Client Stream failed: $e');
    }
  }

  Future<void> _runD2GBidiStream() async {
    const key = 'd2g_bidi_stream';
    _updateResult(
      key,
      TestResult(status: TestStatus.running, streamMessages: []),
    );
    _addLog('Running: Dart → Go Bidi Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    final messages = <String>[];

    try {
      final requests = Stream.fromIterable([
        pb.HelloRequest()
          ..name = 'Alice'
          ..language = 'en',
        pb.HelloRequest()
          ..name = 'Bob'
          ..language = 'ko',
        pb.HelloRequest()
          ..name = 'Charlie'
          ..language = 'ja',
      ]);

      Stream<pb.HelloResponse> stream;
      final client = _serverManager.getGoGreeterClient();
      if (client != null) {
         stream = client.barBidiStream(requests);
      } else {
         stream = GoGreeterClient.barBidiStream(requests);
      }

      await for (final response in stream) {
        messages.add(response.message);
        _updateResult(
          key,
          TestResult(
            status: TestStatus.running,
            streamMessages: List.from(messages),
          ),
        );
        _addLog('  📥 ${response.message}');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: '${messages.length} messages',
          durationMs: stopwatch.elapsedMilliseconds,
          streamMessages: messages,
        ),
      );
      _addLog(
        '✅ D2G Bidi Stream: ${messages.length} msgs (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Bidi Stream failed: $e');
    }
  }

  Future<void> _runG2DUnary() async {
    const key = 'g2d_unary';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Go → Dart Unary [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      final trigger = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.UNARY
        ..payload = (pb.HelloRequest()
          ..name = 'Dart'
          ..language = 'en');
      final response = await GoGreeterClient.trigger(trigger);

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ G2D Unary: ${response.message} (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Unary failed: $e');
    }
  }

  Future<void> _runG2DServerStream() async {
    const key = 'g2d_server_stream';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Go → Dart Server Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      final trigger = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.SERVER_STREAM
        ..payload = (pb.HelloRequest()..name = 'StreamTest');
      final response = await GoGreeterClient.trigger(trigger);

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message.split('\n').first,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog('✅ G2D Server Stream (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Server Stream failed: $e');
    }
  }

  Future<void> _runG2DClientStream() async {
    const key = 'g2d_client_stream';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Go → Dart Client Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      final trigger = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.CLIENT_STREAM
        ..payload = (pb.HelloRequest()..name = 'ClientTest');
      final response = await GoGreeterClient.trigger(trigger);

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ G2D Client Stream: ${response.message} (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Client Stream failed: $e');
    }
  }

  Future<void> _runG2DBidiStream() async {
    const key = 'g2d_bidi_stream';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('Running: Go → Dart Bidi Stream [${_getTransportLabelForTest(key)}]...');

    final stopwatch = Stopwatch()..start();
    try {
      final trigger = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.BIDI_STREAM
        ..payload = (pb.HelloRequest()..name = 'BidiTest');
      final response = await GoGreeterClient.trigger(trigger);

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: response.message.split('\n').first,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog('✅ G2D Bidi Stream (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Bidi Stream failed: $e');
    }
  }

  Future<void> _runAllTests() async {
    _resetAll(); // Auto-reset before run
    setState(() => _isRunningAll = true);
    _addLog(
      '═══════════════════════ Running All Tests ═══════════════════════',
    );

    await Future.wait([
      _runD2GUnary(),
      _runD2GServerStream(),
      _runD2GClientStream(),
      _runD2GBidiStream(),
      _runG2DUnary(),
      _runG2DServerStream(),
      _runG2DClientStream(),
      _runG2DBidiStream(),
    ]);

    setState(() => _isRunningAll = false);
    _addLog(
      '═══════════════════════════════════════════════════════════════════',
    );
  }

  /// Run all tests with all transport combinations (FFI, UDS, TCP)
  Future<void> _runAllMixed() async {
    _resetAll(); // Auto-reset before run
    setState(() => _isRunningAll = true);

    // Helper to run full suite with delay
    Future<void> runSuite(String label) async {
      _addLog(
        '\n-------------------------------------------------------------',
      );
      _addLog('▸ $label');
      _addLog('-------------------------------------------------------------');
      await Future.delayed(const Duration(seconds: 1));
      await Future.wait([
        _runD2GUnary(),
        _runD2GServerStream(),
        _runD2GClientStream(),
        _runD2GBidiStream(),
        _runG2DUnary(),
        _runG2DServerStream(),
        _runG2DClientStream(),
        _runG2DBidiStream(),
      ]);
      await Future.delayed(const Duration(seconds: 2));
    }

    _addLog(
      '╔═══════════════════════════════════════════════════════════════════╗',
    );
    _addLog(
      '║            COMPREHENSIVE MIXED TRANSPORT TEST                    ║',
    );
    _addLog(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );

    // Test 1: FFI mode (default)
    // Ensure we start fresh with FFI
    await _serverManager.stopGoServer();
    await _serverManager.disconnectGoClient();
    await _serverManager.startGoServer(); // FFI Only
    await _serverManager.connectGoClient(mode: TransportMode.ffi); // Use FfiClientChannel
    setState(() {});

    await runSuite('Test 1: FFI Mode (Default)');

    // Test 2: Go TCP
    await _serverManager.stopGoServer();
    await _serverManager.startGoServer(tcp: true);
    await _serverManager.connectGoClient(mode: TransportMode.tcp);
    setState(() {});

    await runSuite('Test 2: Go TCP Server');

    // Test 3: Both UDS
    await _serverManager.stopGoServer();
    await _serverManager.startFlutterUdsServer();
    await _serverManager.startGoServer(uds: true);
    await _serverManager.connectGoClient(mode: TransportMode.uds);
    setState(() {});

    await runSuite('Test 3: Go UDS + Flutter UDS');

    // Test 4: Both TCP
    await _serverManager.stopGoServer();
    await _serverManager.stopFlutterUdsServer();
    await _serverManager.startFlutterTcpServer();
    await _serverManager.startGoServer(tcp: true);
    await _serverManager.connectGoClient(mode: TransportMode.tcp);
    setState(() {});

    await runSuite('Test 4: Go TCP + Flutter TCP');

    // Restore default state
    _addLog('\n▸ Restoring default FFI configuration...');
    await _serverManager.stopGoServer();
    await _serverManager.disconnectGoClient();
    await _serverManager.stopFlutterTcpServer();
    await _serverManager.startGoServer(); // FFI default
    await _serverManager.connectGoClient(mode: TransportMode.ffi); // Use FfiClientChannel
    setState(() {});

    setState(() => _isRunningAll = false);
    _addLog(
      '╔═══════════════════════════════════════════════════════════════════╗',
    );
    _addLog(
      '║            ALL MIXED TESTS COMPLETE                              ║',
    );
    _addLog(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );
  }

  void _resetAll() {
    setState(() {
      for (final key in _results.keys) {
        _results[key] = TestResult();
      }
      _logs.clear();
    });
    _addLog('Tests reset');
  }

  String _getTransportLabelForTest(String id) {
    final isG2D = id.startsWith('g2d');
    if (isG2D) {
      // G2D calls depend on Flutter server type
      if (_serverManager.flutterTcpRunning) return 'Via TCP';
      if (_serverManager.flutterUdsRunning) return 'Via UDS';
      return 'Via FFI';
    } else {
      // D2G calls depend on Go server type
      if (_serverManager.goTcpRunning) return 'Via TCP';
      if (_serverManager.goUdsRunning) return 'Via UDS';
      return 'Via FFI';
    }
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_showFileTests) {
      return FileTestPage(
        serverManager: _serverManager,
        onBack: () => setState(() => _showFileTests = false),
      );
    }

    final passed = _results.values
        .where((r) => r.status == TestStatus.passed)
        .length;
    final failed = _results.values
        .where((r) => r.status == TestStatus.failed)
        .length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            HeaderControls(
              token: _token,
              onTokenChanged: (t) => setState(() => _token = t),
              onGenerateToken: () => setState(() {
                _token = generateToken();
                _serverManager.token = _token;
                _addLog('Token regenerated: $_token');
              }),
              goUdsRunning: _serverManager.goUdsRunning,
              goTcpRunning: _serverManager.goTcpRunning,
              flutterUdsRunning: _serverManager.flutterUdsRunning,
              flutterTcpRunning: _serverManager.flutterTcpRunning,
              onToggleGoUds: () async {
                final wasRunning = _serverManager.goUdsRunning;
                // Always stop first
                await _serverManager.stopGoServer();
                await _serverManager.disconnectGoClient();

                if (!wasRunning) {
                  // Turn ON UDS
                  await _serverManager.startGoServer(uds: true);
                  await _serverManager.connectGoClient(mode: TransportMode.uds);
                } else {
                  // Turn OFF - start FFI only with FfiClientChannel
                  await _serverManager.startGoServer();
                  await _serverManager.connectGoClient(mode: TransportMode.ffi);
                }
                setState(() {});
              },
              onToggleGoTcp: () async {
                final wasRunning = _serverManager.goTcpRunning;
                // Always stop first
                await _serverManager.stopGoServer();
                await _serverManager.disconnectGoClient();

                if (!wasRunning) {
                  // Turn ON TCP
                  await _serverManager.startGoServer(tcp: true);
                  await _serverManager.connectGoClient(mode: TransportMode.tcp);
                } else {
                  // Turn OFF - start FFI only with FfiClientChannel
                  await _serverManager.startGoServer();
                  await _serverManager.connectGoClient(mode: TransportMode.ffi);
                }
                setState(() {});
              },
              onToggleFlutterUds: () async {
                if (_serverManager.flutterUdsRunning) {
                  await _serverManager.stopFlutterUdsServer();
                } else {
                  await _serverManager.startFlutterUdsServer();
                }
                // Restart Go server to use new viewSocketPath
                final wasGoUds = _serverManager.goUdsRunning;
                final wasGoTcp = _serverManager.goTcpRunning;
                // If Go server is running (either UDS, TCP, or FFI default)
                // We typically only restart if UDS/TCP toggles are on, OR we want to update FFI to know about flutter server
                // But simplified: restart whatever mode we are in
                await _serverManager.stopGoServer();
                if (wasGoUds || wasGoTcp) {
                  await _serverManager.startGoServer(
                    uds: wasGoUds,
                    tcp: wasGoTcp,
                  );
                  await _serverManager.connectGoClient(
                    mode: wasGoTcp ? TransportMode.tcp : TransportMode.uds,
                  );
                } else {
                  // Restart in FFI mode with FfiClientChannel
                  await _serverManager.startGoServer();
                  await _serverManager.connectGoClient(mode: TransportMode.ffi);
                }
                setState(() {});
              },
              onToggleFlutterTcp: () async {
                if (_serverManager.flutterTcpRunning) {
                  await _serverManager.stopFlutterTcpServer();
                } else {
                  await _serverManager.startFlutterTcpServer();
                }
                // Restart Go server to use new viewTcpPort
                final wasGoUds = _serverManager.goUdsRunning;
                final wasGoTcp = _serverManager.goTcpRunning;
                await _serverManager.stopGoServer();
                if (wasGoUds || wasGoTcp) {
                  await _serverManager.startGoServer(
                    uds: wasGoUds,
                    tcp: wasGoTcp,
                  );
                  await _serverManager.connectGoClient(
                    mode: wasGoTcp ? TransportMode.tcp : TransportMode.uds,
                  );
                } else {
                  // Restart in FFI mode with FfiClientChannel
                  await _serverManager.startGoServer();
                  await _serverManager.connectGoClient(mode: TransportMode.ffi);
                }
                setState(() {});
              },
              passedTests: passed,
              failedTests: failed,
              onRunAll: _runAllTests,
              onRunAllMixed: _runAllMixed,
              onReset: _resetAll,
              onFileTests: () => setState(() => _showFileTests = true),
              // If running mixed tests, spinner is shown on ALL button
              // If running individual tests, run button logic handles it
              isRunningAll: _isRunningAllMixed,
            ),
            Expanded(
              child: Row(
                children: [
                  // D2G Tests
                  Expanded(
                    child: _buildTestColumn('Dart → Go', [
                      ('d2g_unary', 'Unary', _runD2GUnary),
                      (
                        'd2g_server_stream',
                        'Server Stream',
                        _runD2GServerStream,
                      ),
                      (
                        'd2g_client_stream',
                        'Client Stream',
                        _runD2GClientStream,
                      ),
                      ('d2g_bidi_stream', 'Bidi Stream', _runD2GBidiStream),
                    ]),
                  ),
                  // G2D Tests
                  Expanded(
                    child: _buildTestColumn('Go → Dart', [
                      ('g2d_unary', 'Unary', _runG2DUnary),
                      (
                        'g2d_server_stream',
                        'Server Stream',
                        _runG2DServerStream,
                      ),
                      (
                        'g2d_client_stream',
                        'Client Stream',
                        _runG2DClientStream,
                      ),
                      ('g2d_bidi_stream', 'Bidi Stream', _runG2DBidiStream),
                    ]),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LogPanel(
                logs: _logs,
                scrollController: _logScrollController,
                onClear: () => setState(() => _logs.clear()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestColumn(
    String title,
    List<(String, String, VoidCallback)> tests,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...tests.map(
            (t) => TestCard(
              id: t.$1,
              title: t.$2,
              transport: _getTransportLabelForTest(t.$1),
              result: _results[t.$1]!,
              onRun: t.$3,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _serverManager.dispose();
    _logScrollController.dispose();
    super.dispose();
  }
}
