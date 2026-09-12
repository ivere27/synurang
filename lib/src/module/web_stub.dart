abstract final class JsModuleHost {
  static Never fromTransport(Object transport) => throw UnsupportedError(
      'JsModuleHost requires Dart JavaScript interop on the web');
}

Never exportTransport(Object host) => throw UnsupportedError(
    'exportTransport requires Dart JavaScript interop on the web');
