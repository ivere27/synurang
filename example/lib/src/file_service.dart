import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'package:grpc/grpc.dart';
import 'package:synurang/synurang.dart' hide Duration;
import 'package:fixnum/fixnum.dart';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';

import 'generated/example.pb.dart' as pb;
import 'generated/example.pbgrpc.dart' as pbgrpc;

// =============================================================================
// FileService Handler (Handles Go -> Dart calls)
// =============================================================================

class FileServiceHandler {
  final void Function(String)? onLog;

  FileServiceHandler({this.onLog});

  void _log(String msg) {
    print(msg);
    onLog?.call(msg);
  }

  // Handle UploadFile (Go sends stream to Dart)
  Future<pb.FileStatus> uploadFile(
    ServiceCall call,
    Stream<pb.FileChunk> request,
  ) async {
    _log('Dart: UploadFile called');

    var sizeReceived = 0;

    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);

    await for (final chunk in request) {
      input.add(chunk.content);
      sizeReceived += chunk.content.length;
    }
    input.close();

    final hash = output.events.single.toString();
    call.trailers?['x-file-hash'] = hash;

    return pb.FileStatus()..sizeReceived = Int64(sizeReceived);
  }

  // Handle DownloadFile (Dart generates stream for Go)
  Stream<pb.FileChunk> downloadFile(
    ServiceCall call,
    pb.DownloadFileRequest request,
  ) async* {
    _log('Dart: DownloadFile called size=${request.size}');

    var remaining = request.size.toInt();
    final bufSize = 64 * 1024;

    final rng = Random();
    final chunkData = Uint8List(bufSize);
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);

    while (remaining > 0) {
      var chunkSize = bufSize;
      if (remaining < chunkSize) {
        chunkSize = remaining;
      }

      for (var i = 0; i < chunkSize; i++) {
        chunkData[i] = rng.nextInt(256);
      }

      final dataToSend = (chunkSize == bufSize)
          ? chunkData
          : chunkData.sublist(0, chunkSize);

      input.add(dataToSend);

      yield pb.FileChunk()..content = dataToSend;
      remaining -= chunkSize;

      await Future.delayed(Duration.zero);
    }
    input.close();
    final hash = output.events.single.toString();

    call.trailers?['x-file-hash'] = hash;
  }

  // Handle BidiFile (Echo)
  Stream<pb.FileChunk> bidiFile(
    ServiceCall call,
    Stream<pb.FileChunk> request,
  ) async* {
    _log('Dart: BidiFile called');

    await for (final chunk in request) {
      yield chunk;
    }
  }
}

// =============================================================================
// GoFileClient (Handles Dart -> Go calls via FFI)
// =============================================================================

class GoFileClient {
  static const _service = '/example.v1.GoGreeterService';

  static Future<pb.FileStatus> uploadFile(
    Stream<pb.FileChunk> chunks, {
    pbgrpc.GoGreeterServiceClient? client,
  }) async {
    if (client != null) {
      return client.uploadFile(chunks);
    }
    final bytes = await invokeBackendClientStream(
      '$_service/UploadFile',
      chunks.map((c) => c.writeToBuffer()),
    );
    return pb.FileStatus.fromBuffer(bytes);
  }

  static Stream<pb.FileChunk> downloadFile(
    int size,
    int seed, {
    pbgrpc.GoGreeterServiceClient? client,
  }) {
    final request = pb.DownloadFileRequest()..size = Int64(size);

    if (client != null) {
      return client.downloadFile(request);
    }

    return invokeBackendServerStream(
      '$_service/DownloadFile',
      request.writeToBuffer(),
    ).map((bytes) => pb.FileChunk.fromBuffer(bytes));
  }

  static Stream<pb.FileChunk> bidiFile(
    Stream<pb.FileChunk> chunks, {
    pbgrpc.GoGreeterServiceClient? client,
  }) {
    if (client != null) {
      return client.bidiFile(chunks);
    }
    return invokeBackendBidiStream(
      '$_service/BidiFile',
      chunks.map((c) => c.writeToBuffer()),
    ).map((bytes) => pb.FileChunk.fromBuffer(bytes));
  }
}
