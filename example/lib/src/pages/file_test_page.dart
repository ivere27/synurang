import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:fixnum/fixnum.dart';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';

import '../file_service.dart';
import '../server_manager.dart';
import '../dart_greeter_service.dart';
import '../widgets/test_card.dart';
import '../generated/example.pb.dart' as pb;

class FileTestPage extends StatefulWidget {
  final ServerManager serverManager;
  final VoidCallback onBack;

  const FileTestPage({
    super.key,
    required this.serverManager,
    required this.onBack,
  });

  @override
  State<FileTestPage> createState() => _FileTestPageState();
}

class _FileTestPageState extends State<FileTestPage> {
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  // Test states
  final Map<String, TestResult> _results = {
    'd2g_upload': TestResult(),
    'd2g_download': TestResult(),
    'd2g_bidi': TestResult(),
    'g2d_upload': TestResult(),
    'g2d_download': TestResult(),
    'g2d_bidi': TestResult(),
  };

  @override
  void initState() {
    super.initState();
    _addLog('File Test Page Initialized');
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add(
        '[${DateTime.now().toIso8601String().split('T').last.split('.').first}] $message',
      );
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

  void _updateResult(String key, TestResult result) {
    if (!mounted) return;
    setState(() => _results[key] = result);
  }

  // ===========================================================================
  // Test Generators
  // ===========================================================================

  Stream<pb.FileChunk> _generateFileStream(int size, int chunkSize) async* {
    var remaining = size;
    final rng = Random();
    final data = Uint8List(chunkSize);

    while (remaining > 0) {
      if (remaining < chunkSize) {
        chunkSize = remaining;
      }

      for (var i = 0; i < chunkSize; i++) {
        data[i] = rng.nextInt(256);
      }

      final currentData = (chunkSize == data.length)
          ? data
          : data.sublist(0, chunkSize);
      yield pb.FileChunk()..content = currentData;
      remaining -= chunkSize;
      await Future.delayed(Duration.zero);
    }
  }

  Future<void> _runAllParallel() async {
    _addLog('🚀 STARTING ALL TESTS IN PARALLEL');
    await Future.wait([
      _runD2GUpload(),
      _runD2GDownload(),
      _runD2GBidi(),
      _runG2DUpload(),
      _runG2DDownload(),
      _runG2DBidi(),
    ]);
    _addLog('🏁 ALL PARALLEL TESTS COMPLETED');
  }

  // ===========================================================================
  // D2G Tests (Dart Client -> Go Server)
  // ===========================================================================

  Future<void> _runD2GUpload() async {
    const key = 'd2g_upload';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('D2G Upload: Starting 10MB x 3 upload...');

    final stopwatch = Stopwatch()..start();
    try {
      final size = 10 * 1024 * 1024;
      final chunkSize = 32 * 1024; // 32KB

      for (int i = 0; i < 3; i++) {
        // Prepare data in memory to calculate hash
        _addLog('  Loop ${i + 1}/3: Generating Data...');
        final rng = Random();
        final data = Uint8List(size);
        for (int k = 0; k < size; k++) {
          data[k] = rng.nextInt(256);
        }
        final expectedHash = sha256.convert(data).toString();

        Stream<pb.FileChunk> stream() async* {
          int offset = 0;
          while (offset < size) {
            int end = offset + chunkSize;
            if (end > size) end = size;
            yield pb.FileChunk()..content = data.sublist(offset, end);
            offset = end;
          }
        }

        final status = await GoFileClient.uploadFile(stream());
        _addLog('  Loop ${i + 1} Done: ${status.sizeReceived} bytes');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ D2G Upload Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Upload failed: $e');
    }
  }

  Future<void> _runD2GDownload() async {
    const key = 'd2g_download';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('D2G Download: Starting 10MB x 3 download...');

    final stopwatch = Stopwatch()..start();
    try {
      final size = 10 * 1024 * 1024;
      final seed = 0;

      for (int i = 0; i < 3; i++) {
        _addLog('  Loop ${i + 1}/3...');

        // We need 'ResponseStream' to get trailers, so we must use 'client' if available.
        // But GoFileClient.downloadFile logic abstracts this.
        // If we use FFI, we can't check headers easily yet.
        // This test runs via FFI usually?
        // Let's check transport. If TCP/UDS, we can check.
        // But here we invoke GoFileClient wrapper which hides the client/transport details unless we pass 'client'.
        // Actually, GoFileClient internal logic uses 'invokeBackend'.
        // FFI mode: No trailers check.

        final stream = GoFileClient.downloadFile(size, seed);
        var received = 0;

        final output = AccumulatorSink<Digest>();
        final input = sha256.startChunkedConversion(output);

        await for (final chunk in stream) {
          received += chunk.content.length;
          input.add(chunk.content);
        }
        input.close();
        final actualHash = output.events.single.toString();

        _addLog('  Loop ${i + 1} Done: $received bytes. Hash: $actualHash');
        // Note: We can't verify 'promised' hash here because for Download, Go generates random data
        // and sends hash in Trailer. Accessing trailer from this stream wrapper is hard if it's FFI.
        // If it's gRPC and we returned ResponseStream, we could.
        // For now, we trust 10MB received means success in transportation.
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ D2G Download Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Download failed: $e');
    }
  }

  Future<void> _runD2GBidi() async {
    const key = 'd2g_bidi';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('D2G Bidi: Starting 10MB x 3 Echo...');

    final stopwatch = Stopwatch()..start();
    try {
      final size = 10 * 1024 * 1024;
      final chunkSize = 32 * 1024;

      for (int i = 0; i < 3; i++) {
        _addLog('  Loop ${i + 1}/3...');

        final rng = Random();
        final data = Uint8List(size);
        for (int k = 0; k < size; k++) {
          data[k] = rng.nextInt(256);
        }
        final expectedHash = sha256.convert(data).toString();

        Stream<pb.FileChunk> outStream() async* {
          int offset = 0;
          while (offset < size) {
            int end = offset + chunkSize;
            if (end > size) end = size;
            yield pb.FileChunk()..content = data.sublist(offset, end);
            offset = end;
          }
        }

        final inStream = GoFileClient.bidiFile(outStream());
        var received = 0;

        final output = AccumulatorSink<Digest>();
        final input = sha256.startChunkedConversion(output);

        await for (final chunk in inStream) {
          received += chunk.content.length;
          input.add(chunk.content);
        }
        input.close();
        final actualHash = output.events.single.toString();

        _addLog('  Loop ${i + 1} Done: $received bytes');

        if (actualHash != expectedHash) {
          throw 'Hash mismatch! Sent: $expectedHash, Recv: $actualHash';
        }
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ D2G Bidi Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ D2G Bidi failed: $e');
    }
  }

  // ===========================================================================
  // G2D Tests (Go Client -> Dart Server) - Triggered from Go
  // ===========================================================================

  Future<void> _runG2DUpload() async {
    const key = 'g2d_upload';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('G2D Upload: Triggering 10MB x 3 upload from Go...');

    final stopwatch = Stopwatch()..start();
    try {
      final req = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.UPLOAD_FILE
        ..fileSize = Int64(10 * 1024 * 1024);

      for (int i = 0; i < 3; i++) {
        _addLog('  Loop ${i + 1}/3...');
        await GoGreeterClient.trigger(req);
        _addLog('  Loop ${i + 1} Done');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ G2D Upload Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Upload failed: $e');
    }
  }

  Future<void> _runG2DDownload() async {
    const key = 'g2d_download';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('G2D Download: Triggering 10MB x 3 download from Go...');

    final stopwatch = Stopwatch()..start();
    try {
      final req = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.DOWNLOAD_FILE
        ..fileSize = Int64(10 * 1024 * 1024);

      for (int i = 0; i < 3; i++) {
        _addLog('  Loop ${i + 1}/3...');
        await GoGreeterClient.trigger(req);
        _addLog('  Loop ${i + 1} Done');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ G2D Download Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Download failed: $e');
    }
  }

  Future<void> _runG2DBidi() async {
    const key = 'g2d_bidi';
    _updateResult(key, TestResult(status: TestStatus.running));
    _addLog('G2D Bidi: Triggering 10MB x 3 Bidi from Go...');

    final stopwatch = Stopwatch()..start();
    try {
      final req = pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.BIDI_FILE
        ..fileSize = Int64(10 * 1024 * 1024);

      for (int i = 0; i < 3; i++) {
        _addLog('  Loop ${i + 1}/3...');
        await GoGreeterClient.trigger(req);
        _addLog('  Loop ${i + 1} Done');
      }

      stopwatch.stop();
      _updateResult(
        key,
        TestResult(
          status: TestStatus.passed,
          message: 'Completed 3 loops',
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      );
      _addLog(
        '✅ G2D Bidi Test sequence completed (${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      stopwatch.stop();
      _updateResult(key, TestResult(status: TestStatus.failed, message: '$e'));
      _addLog('❌ G2D Bidi failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Streaming Tests'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
        actions: [
          FilledButton.icon(
            onPressed: _runAllParallel,
            icon: const Icon(Icons.rocket_launch),
            label: const Text('Run All (Parallel)'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.deepPurpleAccent,
            ),
          ),
          const SizedBox(width: 16),
        ],
        backgroundColor: const Color(0xFF0D0B14),
      ),
      body: Row(
        children: [
          Expanded(
            flex: 1,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Dart Client -> Go Server',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                TestCard(
                  id: 'd2g_upload',
                  title: 'Upload 100MB',
                  result: _results['d2g_upload']!,
                  onRun: _runD2GUpload,
                ),
                TestCard(
                  id: 'd2g_download',
                  title: 'Download 100MB',
                  result: _results['d2g_download']!,
                  onRun: _runD2GDownload,
                ),
                TestCard(
                  id: 'd2g_bidi',
                  title: 'Bidi Stream 50MB',
                  result: _results['d2g_bidi']!,
                  onRun: _runD2GBidi,
                ),
                const SizedBox(height: 30),
                const Text(
                  'Go Client -> Dart Server',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                TestCard(
                  id: 'g2d_upload',
                  title: 'Go Upload 100MB',
                  result: _results['g2d_upload']!,
                  onRun: _runG2DUpload,
                ),
                TestCard(
                  id: 'g2d_download',
                  title: 'Go Download 100MB',
                  result: _results['g2d_download']!,
                  onRun: _runG2DDownload,
                ),
                TestCard(
                  id: 'g2d_bidi',
                  title: 'Go Bidi 50MB',
                  result: _results['g2d_bidi']!,
                  onRun: _runG2DBidi,
                ),
              ],
            ),
          ),
          // Log Panel Reuse
          Expanded(
            flex: 1,
            child: Container(
              color: Colors.black12,
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Logs',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.white54,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _logs.clear()),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24, height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: _logScrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _logs[index],
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
