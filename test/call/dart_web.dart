import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:synurang/module.dart';

import 'dart_conformance.dart';

@JS('dartCreateHost')
external JSPromise<JSObject> createHost(JSString provider, JSBoolean worker);
@JS('dartTestReverse')
external JSPromise<JSAny?> testReverse(JSFunction factory);
@JS('dartResult')
external JSObject get result;

Future<void> main() async {
  final passed = <String>[];
  try {
    for (final worker in [false, true]) {
      for (final provider in ['c', 'cpp', 'rust', 'go']) {
        await conformance(() async => JsModuleHost.fromTransport(
            await createHost(provider.toJS, worker.toJS).toDart));
        passed.add('Dart web $provider ${worker ? "worker" : "direct"}');
      }
    }
    await conformance(dartProvider);
    passed.add('Dart web in-process provider');
    await testReverse((() => exportTransport(dartProvider())).toJS).toDart;
    passed.add('JavaScript client to Dart reverse-call provider');
  } catch (error, stack) {
    result.setProperty('error'.toJS, '$error\n$stack'.toJS);
  } finally {
    result.setProperty('passed'.toJS, passed.map((e) => e.toJS).toList().toJS);
    result.setProperty('done'.toJS, true.toJS);
  }
}
