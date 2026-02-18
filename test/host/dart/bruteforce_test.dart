@Timeout(Duration(minutes: 12))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:synurang/src/process.dart';
import 'package:test/test.dart';

import '../../../example/lib/src/generated/example.pb.dart' as pb;
import '../../../example/lib/src/generated/example.pbgrpc.dart' as pbgrpc;

void main() {
  group('Dart Host Bruteforce', () {
    test('plugin mode', () async {
      if (!_isBruteEnabledFor(const {'ffi'})) {
        return;
      }

      final duration = _envDuration('SYNURANG_BRUTE_DURATION', const Duration(minutes: 1));
      final workers = _envInt('SYNURANG_BRUTE_WORKERS', 4);
      final maxFdDelta = _envInt('SYNURANG_BRUTE_MAX_FD_DELTA', 48);
      final maxRssMbDelta = _envInt('SYNURANG_BRUTE_MAX_RSS_MB_DELTA', 256);

      final specs = [
        ('Go', _resolvePath('bin/libplugin_go.so')),
        ('C++', _resolvePath('bin/libplugin_cpp.so')),
        ('Rust', _resolvePath('bin/libplugin_rust.so')),
      ];

      final missing = specs.where((s) => !File(s.$2).existsSync()).toList();
      if (missing.isNotEmpty) {
        fail('missing plugin(s): ${missing.map((m) => m.$2).join(', ')} (run `make build_plugin_all`)');
      }

      final perPlugin = Duration(
        milliseconds: max(1, duration.inMilliseconds ~/ specs.length),
      );

      final baseline = await _captureResources();
      var totalOps = 0;
      var totalExpected = 0;
      var totalUnexpected = 0;

      for (var i = 0; i < specs.length; i++) {
        final name = specs[i].$1;
        final path = specs[i].$2;
        final plugin = _PluginBindings.load(path);
        try {
          final phase = await _runPluginPhase(
            plugin: plugin,
            pluginName: name,
            duration: perPlugin,
            workers: workers,
            seedBase: (i + 1) * 101,
          );
          totalOps += phase.ops;
          totalExpected += phase.expectedErrors;
          totalUnexpected += phase.unexpectedErrors;
          if (phase.unexpectedErrors > 0) {
            fail('plugin brute-force ($name) had ${phase.unexpectedErrors} unexpected errors');
          }
        } finally {
          plugin.closeAllStreamsBestEffort();
        }
      }

      if (totalOps == 0) {
        fail('plugin brute-force completed with zero successful operations');
      }

      final finalRes = await _captureResources();
      _assertNoResourceLeak(
        baseline: baseline,
        finalRes: finalRes,
        maxFdDelta: maxFdDelta,
        maxRssMbDelta: maxRssMbDelta,
      );

      // Keep a visible summary in test logs.
      stdout.writeln(
        'dart plugin bruteforce: ops=$totalOps expected=$totalExpected unexpected=$totalUnexpected '
        'fd_delta=${_deltaIfKnown(baseline.fdCount, finalRes.fdCount)} '
        'rss_delta_mb=${_deltaMbIfKnown(baseline.rssBytes, finalRes.rssBytes)}',
      );
    });

    test('process mode', () async {
      if (!_isBruteEnabledFor(const {'process'})) {
        return;
      }

      final totalDuration = _envDuration('SYNURANG_BRUTE_DURATION', const Duration(minutes: 1));
      final phaseDuration = _envDuration('SYNURANG_BRUTE_PHASE', const Duration(seconds: 20));
      final workers = _envInt('SYNURANG_BRUTE_WORKERS', 4);
      final maxFdDelta = _envInt('SYNURANG_BRUTE_MAX_FD_DELTA', 48);
      final maxRssMbDelta = _envInt('SYNURANG_BRUTE_MAX_RSS_MB_DELTA', 256);

      final executable = _resolvePath(_exeName('bin/process_child_tcp'));
      if (!File(executable).existsSync()) {
        fail('process child not found: $executable (run `make build_process_tcp_child`)');
      }

      final baseline = await _captureResources();

      final started = DateTime.now();
      var totalOps = 0;
      var totalExpected = 0;
      var totalUnexpected = 0;
      var rounds = 0;

      while (DateTime.now().difference(started) < totalDuration) {
        rounds++;
        final remaining = totalDuration - DateTime.now().difference(started);
        if (remaining <= const Duration(seconds: 1)) {
          break;
        }
        final phase = remaining < phaseDuration ? remaining : phaseDuration;

        SynurangProcess? proc;
        try {
          proc = await SynurangProcess.start(executable);
          final client = pbgrpc.GoGreeterServiceClient(proc.channel);
          final result = await _runProcessPhase(
            client: client,
            duration: phase,
            workers: workers,
            seedBase: rounds * 917,
          );
          totalOps += result.ops;
          totalExpected += result.expectedErrors;
          totalUnexpected += result.unexpectedErrors;
          if (result.unexpectedErrors > 0) {
            fail('process brute-force round $rounds had ${result.unexpectedErrors} unexpected errors');
          }
        } finally {
          if (proc != null) {
            await proc.shutdown();
          }
        }
      }

      if (totalOps == 0) {
        fail('process brute-force completed with zero successful operations');
      }

      final finalRes = await _captureResources();
      _assertNoResourceLeak(
        baseline: baseline,
        finalRes: finalRes,
        maxFdDelta: maxFdDelta,
        maxRssMbDelta: maxRssMbDelta,
      );

      stdout.writeln(
        'dart process bruteforce: rounds=$rounds ops=$totalOps expected=$totalExpected unexpected=$totalUnexpected '
        'fd_delta=${_deltaIfKnown(baseline.fdCount, finalRes.fdCount)} '
        'rss_delta_mb=${_deltaMbIfKnown(baseline.rssBytes, finalRes.rssBytes)}',
      );
    });
  });
}

class _PhaseResult {
  final int ops;
  final int expectedErrors;
  final int unexpectedErrors;

  const _PhaseResult({
    required this.ops,
    required this.expectedErrors,
    required this.unexpectedErrors,
  });
}

Future<_PhaseResult> _runPluginPhase({
  required _PluginBindings plugin,
  required String pluginName,
  required Duration duration,
  required int workers,
  required int seedBase,
}) async {
  var ops = 0;
  var expected = 0;
  var unexpected = 0;
  var stop = false;

  final deadline = DateTime.now().add(duration);
  final futures = <Future<void>>[];

  for (var w = 0; w < workers; w++) {
    futures.add(Future<void>(() async {
      final rnd = Random(DateTime.now().microsecondsSinceEpoch ^ (w * 100103) ^ (seedBase * 9973));
      while (!stop && DateTime.now().isBefore(deadline)) {
        try {
          _runPluginRandomOp(plugin, pluginName, w, rnd);
          ops++;
        } catch (e) {
          if (_isExpectedPluginError(e)) {
            expected++;
          } else {
            unexpected++;
            if (unexpected <= 5) {
              stdout.writeln('dart plugin unexpected [$pluginName worker $w]: $e');
            }
            stop = true;
            return;
          }
        }
        await Future<void>.delayed(Duration(milliseconds: 1 + rnd.nextInt(5)));
      }
    }));
  }

  await Future.wait(futures);
  return _PhaseResult(ops: ops, expectedErrors: expected, unexpectedErrors: unexpected);
}

void _runPluginRandomOp(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final x = rnd.nextInt(100);
  if (x < 40) {
    _pluginUnary(plugin, pluginName, workerId, rnd);
  } else if (x < 62) {
    _pluginServerStream(plugin, pluginName, workerId, rnd);
  } else if (x < 78) {
    _pluginClientStream(plugin, pluginName, workerId, rnd);
  } else if (x < 88) {
    _pluginBidi(plugin, pluginName, workerId, rnd);
  } else {
    _pluginChaos(plugin, pluginName, workerId, rnd);
  }
}

void _pluginUnary(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final marker = 'u-$pluginName-$workerId-${rnd.nextInt(1 << 30)}';
  final resp = plugin.invoke('/example.v1.GoGreeterService/Bar', _encodeHelloRequest(marker));
  final msg = _decodeHelloMessage(resp);
  if (msg.isEmpty || msg.startsWith('<') || !msg.contains(marker)) {
    throw StateError('unary mismatch');
  }
}

void _pluginServerStream(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final stream = plugin.openStream('/example.v1.GoGreeterService/BarServerStream');
  try {
    final marker = 'ss-$pluginName-$workerId-${rnd.nextInt(1 << 30)}';
    stream.send(_encodeHelloRequest(marker));
    stream.closeSend();

    var received = 0;
    while (true) {
      final packet = stream.recv();
      if (packet.eof) break;
      final msg = _decodeHelloMessage(packet.data!);
      if (msg.isEmpty || msg.startsWith('<')) {
        throw StateError('server-stream parse failure');
      }
      received++;
    }
    if (received == 0) {
      throw StateError('server-stream returned zero messages');
    }
  } finally {
    stream.close();
  }
}

void _pluginClientStream(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final stream = plugin.openStream('/example.v1.GoGreeterService/BarClientStream');
  try {
    final count = 1 + rnd.nextInt(20);
    for (var i = 0; i < count; i++) {
      stream.send(_encodeHelloRequest('cs-$pluginName-$workerId-$i-${rnd.nextInt(1 << 30)}'));
    }
    stream.closeSend();
    final packet = stream.recv();
    if (packet.eof || packet.data == null) {
      throw StateError('client-stream got eof');
    }
    final msg = _decodeHelloMessage(packet.data!);
    if (msg.isEmpty || msg.startsWith('<')) {
      throw StateError('client-stream parse failure');
    }
  } finally {
    stream.close();
  }
}

void _pluginBidi(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final stream = plugin.openStream('/example.v1.GoGreeterService/BarBidiStream');
  try {
    final count = 1 + rnd.nextInt(12);
    var received = 0;
    for (var i = 0; i < count; i++) {
      stream.send(_encodeHelloRequest('bs-$pluginName-$workerId-$i-${rnd.nextInt(1 << 30)}'));
      final packet = stream.recv();
      if (packet.eof) break;
      final msg = _decodeHelloMessage(packet.data!);
      if (msg.isEmpty || msg.startsWith('<')) {
        throw StateError('bidi parse failure');
      }
      received++;
    }
    stream.closeSend();
    if (received == 0) {
      throw StateError('bidi returned zero responses');
    }
  } finally {
    stream.close();
  }
}

void _pluginChaos(_PluginBindings plugin, String pluginName, int workerId, Random rnd) {
  final x = rnd.nextInt(100);
  if (x < 15) {
    final s = plugin.openStream('/example.v1.GoGreeterService/BarBidiStream');
    s.close();
    return;
  }
  if (x < 30) {
    final s = plugin.openStream('/example.v1.GoGreeterService/BarBidiStream');
    s.send(_encodeHelloRequest('chaos-dc'));
    s.close();
    s.close();
    return;
  }
  if (x < 43) {
    final s = plugin.openStream('/example.v1.GoGreeterService/BarClientStream');
    try {
      s.send(_encodeHelloRequest('chaos-sac-$workerId'));
      s.closeSend();
      try {
        s.send(_encodeHelloRequest('after-close'));
      } catch (_) {
        // expected
      }
    } finally {
      s.close();
    }
    return;
  }
  if (x < 56) {
    final s = plugin.openStream('/example.v1.GoGreeterService/BarServerStream');
    try {
      s.send(_encodeHelloRequest('chaos-rac-$workerId'));
      s.closeSend();
      final first = s.recv();
      if (!first.eof) {
        s.close();
        try {
          s.recv();
        } catch (_) {
          // expected
        }
      }
    } finally {
      s.close();
    }
    return;
  }
  if (x < 70) {
    final size = 64 * 1024 + rnd.nextInt(192 * 1024);
    final payload = _encodeHelloRequestWithLanguage('boundary', 'B' * size);
    final resp = plugin.invoke('/example.v1.GoGreeterService/Bar', payload);
    if (resp.isEmpty) {
      throw StateError('boundary payload: empty response');
    }
    return;
  }
  if (x < 82) {
    _pluginBidi(plugin, pluginName, workerId, rnd);
    return;
  }
  if (x < 92) {
    final count = 2 + rnd.nextInt(6);
    for (var i = 0; i < count; i++) {
      final s = plugin.openStream('/example.v1.GoGreeterService/BarBidiStream');
      s.close();
    }
    return;
  }

  _pluginUnary(plugin, pluginName, workerId, rnd);
}

Future<_PhaseResult> _runProcessPhase({
  required pbgrpc.GoGreeterServiceClient client,
  required Duration duration,
  required int workers,
  required int seedBase,
}) async {
  var ops = 0;
  var expected = 0;
  var unexpected = 0;
  var stop = false;

  final deadline = DateTime.now().add(duration);
  final futures = <Future<void>>[];

  for (var w = 0; w < workers; w++) {
    futures.add(Future<void>(() async {
      final rnd = Random(DateTime.now().microsecondsSinceEpoch ^ (w * 100003) ^ (seedBase * 7919));
      while (!stop && DateTime.now().isBefore(deadline)) {
        try {
          await _runProcessRandomOp(client, rnd, w);
          ops++;
        } catch (e) {
          if (_isExpectedProcessError(e)) {
            expected++;
          } else {
            unexpected++;
            if (unexpected <= 5) {
              stdout.writeln('dart process unexpected [worker $w]: $e');
            }
            stop = true;
            return;
          }
        }
        await Future<void>.delayed(Duration(milliseconds: 1 + rnd.nextInt(5)));
      }
    }));
  }

  await Future.wait(futures);
  return _PhaseResult(ops: ops, expectedErrors: expected, unexpectedErrors: unexpected);
}

Future<void> _runProcessRandomOp(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final x = rnd.nextInt(100);
  if (x < 35) {
    await _processUnary(client, rnd, workerId);
  } else if (x < 57) {
    await _processServerStream(client, rnd, workerId);
  } else if (x < 75) {
    await _processClientStream(client, rnd, workerId);
  } else if (x < 88) {
    await _processBidi(client, rnd, workerId);
  } else {
    await _processChaos(client, rnd, workerId);
  }
}

grpc.CallOptions _opts(Duration timeout) => grpc.CallOptions(timeout: timeout);

Duration _randomTimeout(Random rnd) {
  final n = rnd.nextInt(100);
  if (n < 15) return Duration(milliseconds: 2 + rnd.nextInt(4));
  if (n < 65) return Duration(milliseconds: 20 + rnd.nextInt(80));
  return Duration(milliseconds: 100 + rnd.nextInt(350));
}

Future<void> _processUnary(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final marker = 'u-$workerId-${rnd.nextInt(1 << 30)}';
  final resp = await client.bar(
    pb.HelloRequest()..name = marker,
    options: _opts(_randomTimeout(rnd)),
  );
  if (resp.message.isEmpty || !resp.message.contains(marker)) {
    throw StateError('unary mismatch');
  }
}

Future<void> _processServerStream(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final marker = 'ss-$workerId-${rnd.nextInt(1 << 30)}';
  final stream = client.barServerStream(
    pb.HelloRequest()..name = marker,
    options: _opts(_randomTimeout(rnd)),
  );

  var received = 0;
  await for (final msg in stream) {
    if (msg.message.isEmpty) {
      throw StateError('server-stream empty message');
    }
    received++;
  }
  if (received == 0) {
    throw StateError('server-stream returned zero messages');
  }
}

Future<void> _processClientStream(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final count = 1 + rnd.nextInt(20);
  final reqs = List<pb.HelloRequest>.generate(
    count,
    (i) => pb.HelloRequest()..name = 'cs-$workerId-$i-${rnd.nextInt(1 << 30)}',
  );
  final resp = await client.barClientStream(
    Stream<pb.HelloRequest>.fromIterable(reqs),
    options: _opts(_randomTimeout(rnd)),
  );
  if (resp.message.isEmpty) {
    throw StateError('client-stream empty response');
  }
}

Future<void> _processBidi(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final count = 1 + rnd.nextInt(12);
  final reqs = List<pb.HelloRequest>.generate(
    count,
    (i) => pb.HelloRequest()..name = 'bs-$workerId-$i-${rnd.nextInt(1 << 30)}',
  );
  final respStream = client.barBidiStream(
    Stream<pb.HelloRequest>.fromIterable(reqs),
    options: _opts(_randomTimeout(rnd)),
  );
  var received = 0;
  await for (final msg in respStream) {
    if (msg.message.isEmpty) {
      throw StateError('bidi empty response');
    }
    received++;
  }
  if (received == 0) {
    throw StateError('bidi returned zero responses');
  }
}

Future<void> _processChaos(pbgrpc.GoGreeterServiceClient client, Random rnd, int workerId) async {
  final x = rnd.nextInt(100);
  if (x < 25) {
    try {
      await client.bar(
        pb.HelloRequest()..name = 'chaos-immediate-cancel',
        options: _opts(const Duration(milliseconds: 1)),
      );
    } catch (_) {
      // expected sometimes
    }
    return;
  }
  if (x < 50) {
    final count = 1 + rnd.nextInt(4);
    final reqs = List<pb.HelloRequest>.generate(
      count,
      (i) => pb.HelloRequest()..name = 'chaos-cs-$workerId-$i-${rnd.nextInt(1 << 30)}',
    );
    try {
      await client.barClientStream(
        Stream<pb.HelloRequest>.fromIterable(reqs),
        options: _opts(Duration(milliseconds: 20 + rnd.nextInt(80))),
      );
    } catch (_) {
      // expected sometimes
    }
    return;
  }
  if (x < 75) {
    final size = 64 * 1024 + rnd.nextInt(192 * 1024);
    await client.bar(
      pb.HelloRequest()
        ..name = 'boundary'
        ..language = 'B' * size,
      options: _opts(Duration(milliseconds: 500 + rnd.nextInt(1500))),
    );
    return;
  }
  if (x < 90) {
    await _processServerStream(client, rnd, workerId);
    return;
  }

  await _processUnary(client, rnd, workerId);
}

bool _isExpectedPluginError(Object err) {
  final msg = err.toString().toLowerCase();
  return msg.contains('plugin is closed') ||
      msg.contains('stream send failed') ||
      msg.contains('stream error') ||
      msg.contains('empty stream response') ||
      msg.contains('broken pipe') ||
      msg.contains('connection reset') ||
      msg.contains('eof');
}

bool _isExpectedProcessError(Object err) {
  if (err is TimeoutException) return true;
  if (err is grpc.GrpcError) {
    switch (err.code) {
      case grpc.StatusCode.cancelled:
      case grpc.StatusCode.deadlineExceeded:
      case grpc.StatusCode.unavailable:
      case grpc.StatusCode.aborted:
        return true;
      default:
        break;
    }
  }
  final msg = err.toString().toLowerCase();
  return msg.contains('deadline exceeded') ||
      msg.contains('cancel') ||
      msg.contains('connection closing') ||
      msg.contains('transport is closing') ||
      msg.contains('socket exception') ||
      msg.contains('broken pipe') ||
      msg.contains('eof') ||
      msg.contains('connection error') ||
      msg.contains('forcefully terminated');
}

class _ResourceSnapshot {
  final int fdCount;
  final int rssBytes;
  final bool hasFd;
  final bool hasRss;

  const _ResourceSnapshot({
    required this.fdCount,
    required this.rssBytes,
    required this.hasFd,
    required this.hasRss,
  });
}

Future<_ResourceSnapshot> _captureResources() async {
  var fdCount = -1;
  var hasFd = false;
  if (Platform.isLinux) {
    try {
      fdCount = await Directory('/proc/self/fd').list().length;
      hasFd = true;
    } catch (_) {
      // ignore
    }
  }

  var rssBytes = -1;
  var hasRss = false;
  try {
    rssBytes = ProcessInfo.currentRss;
    hasRss = rssBytes >= 0;
  } catch (_) {
    // ignore
  }

  return _ResourceSnapshot(fdCount: fdCount, rssBytes: rssBytes, hasFd: hasFd, hasRss: hasRss);
}

void _assertNoResourceLeak({
  required _ResourceSnapshot baseline,
  required _ResourceSnapshot finalRes,
  required int maxFdDelta,
  required int maxRssMbDelta,
}) {
  if (baseline.hasFd && finalRes.hasFd) {
    final fdDelta = finalRes.fdCount - baseline.fdCount;
    if (fdDelta > maxFdDelta) {
      fail(
        'fd leak suspected: baseline=${baseline.fdCount} final=${finalRes.fdCount} '
        'delta=$fdDelta allowed=$maxFdDelta',
      );
    }
  }

  if (baseline.hasRss && finalRes.hasRss) {
    final rssDeltaMb = ((finalRes.rssBytes - baseline.rssBytes) / (1024 * 1024)).floor();
    if (rssDeltaMb > maxRssMbDelta) {
      fail(
        'rss leak suspected: baseline_mb=${(baseline.rssBytes / (1024 * 1024)).floor()} '
        'final_mb=${(finalRes.rssBytes / (1024 * 1024)).floor()} '
        'delta_mb=$rssDeltaMb allowed_mb=$maxRssMbDelta',
      );
    }
  }
}

int _deltaIfKnown(int base, int fin) => (base >= 0 && fin >= 0) ? (fin - base) : -1;
int _deltaMbIfKnown(int base, int fin) =>
    (base >= 0 && fin >= 0) ? ((fin - base) ~/ (1024 * 1024)) : -1;

Duration _envDuration(String key, Duration fallback) {
  final raw = Platform.environment[key];
  if (raw == null || raw.trim().isEmpty) return fallback;
  final text = raw.trim().toLowerCase();
  final m = RegExp(r'^(\d+)(ms|s|m)?$').firstMatch(text);
  if (m == null) {
    throw ArgumentError('invalid duration for $key: $raw');
  }
  final n = int.parse(m.group(1)!);
  final unit = m.group(2) ?? 's';
  switch (unit) {
    case 'ms':
      return Duration(milliseconds: n);
    case 's':
      return Duration(seconds: n);
    case 'm':
      return Duration(minutes: n);
    default:
      return fallback;
  }
}

int _envInt(String key, int fallback) {
  final raw = Platform.environment[key];
  if (raw == null || raw.trim().isEmpty) return fallback;
  return int.tryParse(raw.trim()) ?? fallback;
}

bool _isBruteEnabledFor(Set<String> allowedModes) {
  if (Platform.environment['SYNURANG_BRUTE'] != '1') {
    return false;
  }

  final raw = Platform.environment['SYNURANG_BRUTE_MODE'];
  if (raw == null || raw.trim().isEmpty) {
    return true;
  }

  final mode = raw.trim().toLowerCase();
  if (mode == 'all') return true;
  if (mode == 'plugin') return allowedModes.contains('ffi');
  if (mode == 'tcp') return allowedModes.contains('process');
  return allowedModes.contains(mode);
}

String _resolvePath(String rel) {
  if (pIsAbs(rel)) return rel;
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = File('${dir.path}/$rel');
    if (candidate.existsSync()) return candidate.path;
    if (File('${dir.path}/go.mod').existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return File('${Directory.current.path}/$rel').path;
}

String _exeName(String base) => Platform.isWindows ? '$base.exe' : base;

bool pIsAbs(String path) {
  if (path.startsWith('/')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

Uint8List _encodeHelloRequest(String name) {
  final bytes = utf8.encode(name);
  final out = BytesBuilder();
  out.addByte(0x0a);
  out.add(_encodeVarint(bytes.length));
  out.add(bytes);
  return out.toBytes();
}

Uint8List _encodeHelloRequestWithLanguage(String name, String language) {
  final out = BytesBuilder();
  final nameBytes = utf8.encode(name);
  if (nameBytes.isNotEmpty) {
    out.addByte(0x0a);
    out.add(_encodeVarint(nameBytes.length));
    out.add(nameBytes);
  }
  final langBytes = utf8.encode(language);
  if (langBytes.isNotEmpty) {
    out.addByte(0x12);
    out.add(_encodeVarint(langBytes.length));
    out.add(langBytes);
  }
  return out.toBytes();
}

List<int> _encodeVarint(int n) {
  var x = n;
  final out = <int>[];
  while (x >= 0x80) {
    out.add((x & 0x7f) | 0x80);
    x >>= 7;
  }
  out.add(x & 0x7f);
  return out;
}

String _decodeHelloMessage(Uint8List data) {
  if (data.length < 2 || data[0] != 0x0a) return '<parse error>';
  final decoded = _decodeVarint(data, 1);
  if (decoded == null) return '<varint error>';
  final len = decoded.$1;
  final offset = decoded.$2;
  if (data.length < offset + len) return '<truncated>';
  return utf8.decode(data.sublist(offset, offset + len), allowMalformed: true);
}

(int, int)? _decodeVarint(Uint8List data, int offset) {
  var value = 0;
  var shift = 0;
  var idx = offset;
  while (idx < data.length) {
    final b = data[idx];
    idx++;
    value |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) return (value, idx);
    shift += 7;
    if (shift > 35) return null;
  }
  return null;
}

typedef _InvokeNative = Pointer<Int8> Function(
  Pointer<Int8> method,
  Pointer<Int8> data,
  Int32 dataLen,
  Pointer<Int32> respLen,
);
typedef _InvokeDart = Pointer<Int8> Function(
  Pointer<Int8> method,
  Pointer<Int8> data,
  int dataLen,
  Pointer<Int32> respLen,
);

typedef _FreeNative = Void Function(Pointer<Int8> ptr);
typedef _FreeDart = void Function(Pointer<Int8> ptr);

typedef _StreamOpenNative = Uint64 Function(Pointer<Int8> method);
typedef _StreamOpenDart = int Function(Pointer<Int8> method);

typedef _StreamSendNative = Int32 Function(Uint64 handle, Pointer<Int8> data, Int32 dataLen);
typedef _StreamSendDart = int Function(int handle, Pointer<Int8> data, int dataLen);

typedef _StreamRecvNative = Pointer<Int8> Function(
  Uint64 handle,
  Pointer<Int32> respLen,
  Pointer<Int32> status,
);
typedef _StreamRecvDart = Pointer<Int8> Function(
  int handle,
  Pointer<Int32> respLen,
  Pointer<Int32> status,
);

typedef _StreamCloseSendNative = Void Function(Uint64 handle);
typedef _StreamCloseSendDart = void Function(int handle);

typedef _StreamCloseNative = Void Function(Uint64 handle);
typedef _StreamCloseDart = void Function(int handle);

class _PluginBindings {
  final DynamicLibrary _lib;
  final _InvokeDart _invoke;
  final _FreeDart _free;
  final _StreamOpenDart _open;
  final _StreamSendDart _send;
  final _StreamRecvDart _recv;
  final _StreamCloseSendDart _closeSend;
  final _StreamCloseDart _close;
  final Set<int> _openHandles = <int>{};

  _PluginBindings._(
    this._lib,
    this._invoke,
    this._free,
    this._open,
    this._send,
    this._recv,
    this._closeSend,
    this._close,
  );

  factory _PluginBindings.load(String path) {
    final lib = DynamicLibrary.open(path);
    return _PluginBindings._(
      lib,
      lib.lookupFunction<_InvokeNative, _InvokeDart>('Synurang_Invoke_GoGreeterService'),
      lib.lookupFunction<_FreeNative, _FreeDart>('Synurang_Free'),
      lib.lookupFunction<_StreamOpenNative, _StreamOpenDart>('Synurang_Stream_GoGreeterService_Open'),
      lib.lookupFunction<_StreamSendNative, _StreamSendDart>('Synurang_Stream_Send'),
      lib.lookupFunction<_StreamRecvNative, _StreamRecvDart>('Synurang_Stream_Recv'),
      lib.lookupFunction<_StreamCloseSendNative, _StreamCloseSendDart>('Synurang_Stream_CloseSend'),
      lib.lookupFunction<_StreamCloseNative, _StreamCloseDart>('Synurang_Stream_Close'),
    );
  }

  Uint8List invoke(String method, Uint8List req) {
    final methodPtr = method.toNativeUtf8().cast<Int8>();
    final dataPtr = calloc<Int8>(req.length);
    final respLen = calloc<Int32>();
    try {
      for (var i = 0; i < req.length; i++) {
        dataPtr[i] = req[i];
      }
      final respPtr = _invoke(methodPtr, dataPtr, req.length, respLen);
      if (respPtr.address == 0) {
        throw StateError('plugin returned null');
      }
      final raw = _copy(respPtr, respLen.value);
      _free(respPtr);
      return _decodePluginResponse(raw);
    } finally {
      calloc.free(methodPtr);
      calloc.free(dataPtr);
      calloc.free(respLen);
    }
  }

  _PluginStream openStream(String method) {
    final methodPtr = method.toNativeUtf8().cast<Int8>();
    try {
      final handle = _open(methodPtr);
      if (handle == 0) {
        throw StateError('failed to open stream');
      }
      _openHandles.add(handle);
      return _PluginStream._(this, handle);
    } finally {
      calloc.free(methodPtr);
    }
  }

  void _onStreamClosed(int handle) {
    _openHandles.remove(handle);
  }

  void closeAllStreamsBestEffort() {
    final handles = _openHandles.toList(growable: false);
    for (final h in handles) {
      try {
        _close(h);
      } catch (_) {
        // ignore best effort
      }
    }
    _openHandles.clear();
  }

  Uint8List _copy(Pointer<Int8> ptr, int len) {
    if (len <= 0) return Uint8List(0);
    return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(len));
  }

  Uint8List _decodePluginResponse(Uint8List raw) {
    if (raw.isEmpty) {
      throw StateError('empty plugin response');
    }
    if (raw[0] == 1) {
      throw StateError(utf8.decode(raw.sublist(1), allowMalformed: true));
    }
    return Uint8List.fromList(raw.sublist(1));
  }
}

class _StreamPacket {
  final Uint8List? data;
  final bool eof;

  const _StreamPacket(this.data, this.eof);
}

class _PluginStream {
  final _PluginBindings _plugin;
  final int _handle;
  bool _closed = false;

  _PluginStream._(this._plugin, this._handle);

  void send(Uint8List data) {
    if (_closed) throw StateError('stream closed');
    final ptr = calloc<Int8>(data.length);
    try {
      for (var i = 0; i < data.length; i++) {
        ptr[i] = data[i];
      }
      final rc = _plugin._send(_handle, ptr, data.length);
      if (rc != 0) {
        throw StateError('stream send failed: $rc');
      }
    } finally {
      calloc.free(ptr);
    }
  }

  _StreamPacket recv() {
    if (_closed) throw StateError('stream closed');
    final respLen = calloc<Int32>();
    final status = calloc<Int32>();
    try {
      final ptr = _plugin._recv(_handle, respLen, status);
      if (status.value == 1) {
        if (ptr.address != 0) {
          _plugin._free(ptr);
        }
        return const _StreamPacket(null, true);
      }
      if (status.value != 0) {
        String msg = 'stream error: ${status.value}';
        if (ptr.address != 0 && respLen.value > 0) {
          final raw = ptr.cast<Uint8>().asTypedList(respLen.value);
          msg = utf8.decode(raw, allowMalformed: true);
          _plugin._free(ptr);
        }
        throw StateError(msg);
      }
      if (ptr.address == 0 || respLen.value <= 0) {
        throw StateError('empty stream response');
      }
      final raw = Uint8List.fromList(ptr.cast<Uint8>().asTypedList(respLen.value));
      _plugin._free(ptr);
      if (raw.isEmpty) {
        throw StateError('empty stream packet');
      }
      if (raw[0] == 1) {
        throw StateError(utf8.decode(raw.sublist(1), allowMalformed: true));
      }
      return _StreamPacket(Uint8List.fromList(raw.sublist(1)), false);
    } finally {
      calloc.free(respLen);
      calloc.free(status);
    }
  }

  void closeSend() {
    if (_closed) return;
    _plugin._closeSend(_handle);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _plugin._close(_handle);
    _plugin._onStreamClosed(_handle);
  }
}
