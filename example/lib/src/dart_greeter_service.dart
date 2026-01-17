import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:synurang/synurang.dart' hide Duration;
import 'package:synurang/src/generated/core.pb.dart' as core_pb;
import 'file_service.dart';

import 'generated/example.pb.dart' as pb;
import 'generated/example.pbgrpc.dart' as pbgrpc;
import 'package:synurang/src/generated/google/protobuf/timestamp.pb.dart'
    as timestamp_pb;

// =============================================================================
// DartGreeterService Implementation (Dart-side gRPC server, Go calls this)
// =============================================================================

/// Dart implementation of DartGreeterService with all 4 RPC types
class DartGreeterServiceImpl extends pbgrpc.DartGreeterServiceBase {
  final void Function(String)? onLog;
  late final FileServiceHandler _fileHandler;

  DartGreeterServiceImpl({this.onLog}) {
    _fileHandler = FileServiceHandler(onLog: onLog);
  }

  void _log(String msg) {
    print(msg);
    onLog?.call(msg);
  }

  /// Simple RPC - single request, single response
  @override
  Future<pb.HelloResponse> foo(
    ServiceCall call,
    pb.HelloRequest request,
  ) async {
    _log(
      'Dart: Foo called with name=${request.name}, '
      'language=${request.language}',
    );

    final greeting = _getGreeting(request.language, request.name);

    return pb.HelloResponse()
      ..message = greeting
      ..from = 'dart'
      ..timestamp = timestamp_pb.Timestamp.fromDateTime(DateTime.now());
  }

  /// Server-side streaming RPC - sends multiple responses
  @override
  Stream<pb.HelloResponse> fooServerStream(
    ServiceCall call,
    pb.HelloRequest request,
  ) async* {
    _log('Dart: FooServerStream called with name=${request.name}');

    final languages = ['en', 'ko', 'es', 'fr'];

    for (var i = 0; i < languages.length; i++) {
      final greeting = _getGreeting(languages[i], request.name);
      yield pb.HelloResponse()
        ..message = '[${i + 1}/4] $greeting'
        ..from = 'dart'
        ..timestamp = timestamp_pb.Timestamp.fromDateTime(DateTime.now());

      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Client-side streaming RPC - receives multiple requests
  @override
  Future<pb.HelloResponse> fooClientStream(
    ServiceCall call,
    Stream<pb.HelloRequest> request,
  ) async {
    _log('Dart: FooClientStream called');

    final names = <String>[];

    await for (final req in request) {
      _log('Dart: FooClientStream received name=${req.name}');
      names.add(req.name);
    }

    return pb.HelloResponse()
      ..message = 'Hello to all: ${names.join(", ")}! (from Dart)'
      ..from = 'dart'
      ..timestamp = timestamp_pb.Timestamp.fromDateTime(DateTime.now());
  }

  /// Bidirectional streaming RPC - both sides stream
  @override
  Stream<pb.HelloResponse> fooBidiStream(
    ServiceCall call,
    Stream<pb.HelloRequest> request,
  ) async* {
    _log('Dart: FooBidiStream called');

    await for (final req in request) {
      _log('Dart: FooBidiStream received name=${req.name}');

      // Echo back a greeting immediately
      final greeting = _getGreeting(req.language, req.name);
      yield pb.HelloResponse()
        ..message = greeting
        ..from = 'dart'
        ..timestamp = timestamp_pb.Timestamp.fromDateTime(DateTime.now());
    }
  }

  // ===========================================================================
  // File Service RPCs (Delegated to FileServiceHandler)
  // ===========================================================================

  @override
  Future<pb.FileStatus> dartUploadFile(
      ServiceCall call, Stream<pb.FileChunk> request) {
    return _fileHandler.uploadFile(call, request);
  }

  @override
  Stream<pb.FileChunk> dartDownloadFile(
      ServiceCall call, pb.DownloadFileRequest request) {
    return _fileHandler.downloadFile(call, request);
  }

  @override
  Stream<pb.FileChunk> dartBidiFile(
      ServiceCall call, Stream<pb.FileChunk> request) {
    return _fileHandler.bidiFile(call, request);
  }

  String _getGreeting(String language, String name) {
    switch (language) {
      case 'ko':
        return '안녕하세요, $name님! (from Dart)';

      case 'es':
        return '¡Hola, $name! (from Dart)';
      case 'fr':
        return 'Bonjour, $name! (from Dart)';
      default:
        return 'Hello, $name! (from Dart)';
    }
  }
}

/// Alias for gRPC server use (same implementation, clearer naming)
typedef DartGreeterServiceImplForGrpc = DartGreeterServiceImpl;

// =============================================================================
// GoGreeterService Client (Dart calls Go's GoGreeterService)
// =============================================================================

/// Client to call Go's GoGreeterService via FFI
class GoGreeterClient {
  /// Simple RPC - Call Go's Bar method
  static Future<pb.HelloResponse> bar(
    String name, {
    String language = 'en',
  }) async {
    final request = pb.HelloRequest()
      ..name = name
      ..language = language;

    final responseBytes = await invokeBackendAsync(
      '/example.v1.GoGreeterService/Bar',
      request.writeToBuffer(),
    );

    return pb.HelloResponse.fromBuffer(responseBytes);
  }

  static Future<pb.GoroutinesResponse> getGoroutines({
    bool asString = false,
  }) async {
    final request = pb.GoroutinesRequest()..asString = asString;
    final responseBytes = await invokeBackendAsync(
      '/example.v1.GoGreeterService/GetGoroutines',
      request.writeToBuffer(),
    );
    return pb.GoroutinesResponse.fromBuffer(responseBytes);
  }

  /// Ping the Go health service
  static Future<core_pb.PingResponse> ping() async {
    final responseBytes = await invokeBackendAsync(
      '/core.v1.HealthService/Ping',
      Uint8List(0),
    );
    return core_pb.PingResponse.fromBuffer(responseBytes);
  }

  /// Server Streaming RPC via FFI - Go sends multiple greetings
  static Stream<pb.HelloResponse> barServerStream(String name) {
    final request = pb.HelloRequest()..name = name;
    return invokeBackendServerStream(
      '/example.v1.GoGreeterService/BarServerStream',
      request.writeToBuffer(),
    ).map((bytes) => pb.HelloResponse.fromBuffer(bytes));
  }

  /// Client Streaming RPC via FFI - Send multiple names, get aggregated response
  static Future<pb.HelloResponse> barClientStream(
    Stream<pb.HelloRequest> requests,
  ) async {
    final bytes = await invokeBackendClientStream(
      '/example.v1.GoGreeterService/BarClientStream',
      requests.map((r) => r.writeToBuffer()),
    );
    return pb.HelloResponse.fromBuffer(bytes);
  }

  /// Bidirectional Streaming RPC via FFI - Echo pattern
  static Stream<pb.HelloResponse> barBidiStream(
    Stream<pb.HelloRequest> requests,
  ) {
    return invokeBackendBidiStream(
      '/example.v1.GoGreeterService/BarBidiStream',
      requests.map((r) => r.writeToBuffer()),
    ).map((bytes) => pb.HelloResponse.fromBuffer(bytes));
  }

  /// Trigger a Go -> Dart call
  static Future<pb.HelloResponse> trigger(
    pb.TriggerRequest request, {
    pbgrpc.GoGreeterServiceClient? client,
  }) async {
    if (client != null) {
      return client.trigger(request);
    }
    final responseBytes = await invokeBackendAsync(
      '/example.v1.GoGreeterService/Trigger',
      request.writeToBuffer(),
    );
    return pb.HelloResponse.fromBuffer(responseBytes);
  }
}

// =============================================================================
// Dart Handler Registration (Go -> Dart calls via FFI)
// =============================================================================

/// Start the Dart gRPC handler for Go -> Dart calls
void startDartGreeterHandler({void Function(String)? onLog}) {
  final service = DartGreeterServiceImpl(onLog: onLog);

  registerDartHandler((String method, Uint8List data) {
    // Check for Stream ID suffix (format: "method:streamId")
    if (method.contains(':')) {
      final parts = method.split(':');
      final realMethod = parts[0];
      final streamId = int.tryParse(parts[1]);

      if (streamId != null) {
        if (realMethod == '/example.v1.DartGreeterService/FooServerStream') {
          // Handle Server Stream
          final request = pb.HelloRequest.fromBuffer(data);
          final stream = service.fooServerStream(DummyServiceCall(), request);

          // Listen to stream and send data back to Go
          stream.listen(
            (response) {
              final bytes = response.writeToBuffer();
              sendStreamData(streamId, bytes);
            },
            onDone: () {
              closeStream(streamId);
            },
            onError: (e) {
              print('Dart: Stream error: $e');
              closeStream(streamId);
            },
          );

          // Return immediate ACK
          return Uint8List(0);
        } else if (realMethod ==
            '/example.v1.DartGreeterService/FooClientStream') {
          // Handle Client Stream (Go streams to Dart)
          final controller = StreamController<Uint8List>();
          registerStreamController(streamId, controller);
          if (data.isNotEmpty) {
            controller.add(data);
          }

          final requestStream = controller.stream.map(
            (bytes) => pb.HelloRequest.fromBuffer(bytes),
          );

          // Process stream asynchronously
          service
              .fooClientStream(DummyServiceCall(), requestStream)
              .then((response) {
                final bytes = response.writeToBuffer();
                sendStreamData(streamId, bytes); // Send single response
                closeStream(streamId);
              })
              .catchError((e) {
                print('Dart: Client stream error: $e');
                closeStream(streamId);
              });

          return Uint8List(0);
        } else if (realMethod ==
            '/example.v1.DartGreeterService/FooBidiStream') {
          // Handle Bidi Stream
          final controller = StreamController<Uint8List>();
          registerStreamController(streamId, controller);
          if (data.isNotEmpty) {
            controller.add(data);
          }

          final requestStream = controller.stream.map(
            (bytes) => pb.HelloRequest.fromBuffer(bytes),
          );
          final responseStream = service.fooBidiStream(
            DummyServiceCall(),
            requestStream,
          );

          responseStream.listen(
            (response) {
              final bytes = response.writeToBuffer();
              sendStreamData(streamId, bytes);
            },
            onDone: () {
              closeStream(streamId); // Close sending side when done
            },
            onError: (e) {
              print('Dart: Bidi stream error: $e');
              closeStream(streamId);
            },
          );

          return Uint8List(0);
        } else if (realMethod ==
            '/example.v1.DartGreeterService/DartUploadFile') {
          // Handle UploadFile (Go sends stream to Dart)
          final controller = StreamController<Uint8List>();
          registerStreamController(streamId, controller);
          if (data.isNotEmpty) {
            controller.add(data);
          }

          final requestStream = controller.stream.map(
            (bytes) => pb.FileChunk.fromBuffer(bytes),
          );

          service
              .dartUploadFile(DummyServiceCall(), requestStream)
              .then((response) {
                final bytes = response.writeToBuffer();
                sendStreamData(streamId, bytes); // Send single response (status)
                closeStream(streamId);
              })
              .catchError((e) {
                print('Dart: UploadFile error: $e');
                closeStream(streamId);
              });

          return Uint8List(0);
        } else if (realMethod ==
            '/example.v1.DartGreeterService/DartDownloadFile') {
          // Handle DownloadFile (Go requests stream from Dart)
          final request = pb.DownloadFileRequest.fromBuffer(data);
          final stream = service.dartDownloadFile(DummyServiceCall(), request);

          stream.listen(
            (response) {
              final bytes = response.writeToBuffer();
              sendStreamData(streamId, bytes);
            },
            onDone: () {
              closeStream(streamId);
            },
            onError: (e) {
              print('Dart: DownloadFile error: $e');
              closeStream(streamId);
            },
          );

          return Uint8List(0);
        } else if (realMethod ==
            '/example.v1.DartGreeterService/DartBidiFile') {
          // Handle BidiFile
          final controller = StreamController<Uint8List>();
          registerStreamController(streamId, controller);
          if (data.isNotEmpty) {
            controller.add(data);
          }

          final requestStream = controller.stream.map(
            (bytes) => pb.FileChunk.fromBuffer(bytes),
          );
          final responseStream = service.dartBidiFile(
            DummyServiceCall(),
            requestStream,
          );

          responseStream.listen(
            (response) {
              final bytes = response.writeToBuffer();
              sendStreamData(streamId, bytes);
            },
            onDone: () {
              closeStream(streamId);
            },
            onError: (e) {
              print('Dart: BidiFile error: $e');
              closeStream(streamId);
            },
          );

          return Uint8List(0);
        }
      }
    }

    switch (method) {
      case '/example.v1.DartGreeterService/Foo':
        final request = pb.HelloRequest.fromBuffer(data);
        final response = _handleFoo(service, request);
        return response.writeToBuffer();
      default:
        throw Exception('Unknown method: $method');
    }
  });
}

// Dummy ServiceCall for local invocation
class DummyServiceCall implements ServiceCall {
  final Map<String, String> _trailers = {};

  @override
  Map<String, String> get clientMetadata => {};
  @override
  DateTime? get deadline => null;
  @override
  bool get isCanceled => false;
  @override
  Map<String, String>? get headers => null;
  @override
  Map<String, String>? get trailers => _trailers;
  @override
  X509Certificate? get clientCertificate => null;
  @override
  bool get isTimedOut => false;
  @override
  InternetAddress? get remoteAddress => null;
  @override
  void sendHeaders() {}
  @override
  void sendTrailers({int? status, String? message}) {}
}

pb.HelloResponse _handleFoo(
  DartGreeterServiceImpl service,
  pb.HelloRequest request,
) {
  final greeting = service._getGreeting(request.language, request.name);
  return pb.HelloResponse()
    ..message = greeting
    ..from = 'dart'
    ..timestamp = timestamp_pb.Timestamp.fromDateTime(DateTime.now());
}
