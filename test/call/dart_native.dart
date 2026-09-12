import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:synurang/module.dart';

import 'dart_conformance.dart';

Future<void> releasedCalls(String module, String shimPath) async {
  final directory = Directory.systemTemp.createTempSync('synurang-release-');
  final marker = File('${directory.path}/cleanup');
  final host = NativeModuleHost.load(module, shimPath: shimPath);
  try {
    final calls = <ByteCall>[];
    for (var i = 0; i < 96; ++i) {
      final call = await host
          .open(const Method('/test.Release/Watch', responseStream: true));
      calls.add(call);
      await call.send(Uint8List.fromList(utf8.encode(marker.path)));
      if (!(await call.recv())!.isEmpty)
        throw StateError('Expected ready acknowledgement');
    }
    await Future.wait(calls.map((call) => call.close()));
    final watch = Stopwatch()..start();
    while (true) {
      final events = marker.existsSync() ? marker.readAsStringSync() : '';
      if ('C'.allMatches(events).length == calls.length &&
          'D'.allMatches(events).length == calls.length) break;
      if (watch.elapsed > const Duration(seconds: 2)) {
        throw StateError('Release cleanup stopped before host close');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  } finally {
    await host.close();
    directory.deleteSync(recursive: true);
  }
  print('Dart release drains without another call or host close');
}

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2) {
    throw ArgumentError('Usage: dart_native.dart MODULE_DIRECTORY SHIM_PATH');
  }
  final releaseModule = Platform.environment['SYNURANG_TEST_RELEASE_MODULE'];
  if (releaseModule != null) await releasedCalls(releaseModule, arguments[1]);
  final providers =
      arguments.length == 2 ? ['c', 'cpp', 'rust'] : arguments.sublist(2);
  for (final provider in providers) {
    await conformance(() => NativeModuleHost.load(
        '${arguments[0]}/${provider}_module.so',
        shimPath: arguments[1],
        capacity: 2));
    print('Dart native $provider conformance passed');
  }
  final library = DynamicLibrary.open('${arguments[0]}/c_module.so');
  final api = library.lookupFunction<Pointer<Void> Function(),
      Pointer<Void> Function()>('Synurang_GetApi')();
  await conformance(
      () => NativeModuleHost.linked(api, shimPath: arguments[1], capacity: 2));
  print('Dart supplied API table conformance passed');
  library.close();
  await conformance(dartProvider);
  print('Dart in-process provider conformance passed');
}
