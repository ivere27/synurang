/// Native shared/static libraries cannot be loaded by a browser. Pass a
/// JavaScript WASM or Worker transport to JsModuleHost on the web.
abstract final class NativeModuleHost {
  static Never load(String path,
          {String? shimPath,
          String symbol = 'Synurang_GetApi',
          int capacity = 16}) =>
      throw UnsupportedError('NativeModuleHost requires a native Dart target');
}
