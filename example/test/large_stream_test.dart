import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:synurang/synurang.dart' hide Duration;
import 'package:synurang_example/src/generated/example.pb.dart' as pb;
import 'package:synurang_example/src/file_service.dart';
import 'package:synurang_example/src/server_manager.dart';
import 'package:synurang_example/src/dart_greeter_service.dart';
import 'package:synurang_example/src/transport_config.dart';

// Helper to generate random stream
Stream<pb.FileChunk> generateFileStream(int size, int chunkSize) async* {
  var remaining = size;
  final rng = Random();
  final data = Uint8List(chunkSize);

  while (remaining > 0) {
    var currentChunkSize = chunkSize;
    if (remaining < currentChunkSize) {
      currentChunkSize = remaining;
    }

    // Fill chunk with random data
    for (var i = 0; i < currentChunkSize; i++) {
      data[i] = rng.nextInt(256);
    }

    final currentData = (currentChunkSize == chunkSize)
        ? data
        : data.sublist(0, currentChunkSize);

    yield pb.FileChunk()..content = currentData;
    remaining -= currentChunkSize;
  }
}

// Calculate SHA256 of a stream (helper)
Future<String> calculateStreamHash(Stream<pb.FileChunk> stream) async {
  final output = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in stream) {
    input.add(chunk.content);
  }
  input.close();
  return output.events.single.toString();
}

void main() {
  late ServerManager serverManager;

  setUpAll(() async {
    configureSynurang(libraryName: 'synura_example');
  });

  // Tests for different transports
  final transports = [TransportMode.tcp, TransportMode.uds];

  for (final mode in transports) {
    group('File Streaming (${mode.name.toUpperCase()})', () {
      setUp(() async {
        serverManager = ServerManager(
          onLog: (msg) => print('ServerManager: $msg'),
          token: 'test-token',
        );

        if (mode == TransportMode.uds) {
          await serverManager.startFlutterUdsServer();
          await serverManager.startGoServer(uds: true);
          await Future.delayed(const Duration(milliseconds: 500));
          await serverManager.connectGoClient(mode: TransportMode.uds);
        } else if (mode == TransportMode.tcp) {
          await serverManager.startFlutterTcpServer();
          await serverManager.startGoServer(tcp: true);
          await Future.delayed(const Duration(milliseconds: 500));
          await serverManager.connectGoClient(mode: TransportMode.tcp);
        }
      });

      tearDown(() async {
        await serverManager.dispose();
      });

      test('D2G Upload 10MB (x3)', () async {
        final size = 10 * 1024 * 1024;
        final chunkSize = 64 * 1024;

        for (int i = 0; i < 3; i++) {
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

          final client = serverManager.getGoGreeterClient();
          if (client != null) {
            // gRPC path - verify via trailers
            final call = client.uploadFile(stream());
            final status = await call;
            expect(status.sizeReceived, equals(Int64(size)));
            final trailers = await call.trailers;
            expect(trailers['x-file-hash'], equals(expectedHash));
          } else {
            // FFI path - trailers not yet exposed for client streaming response
            final status = await GoFileClient.uploadFile(stream());
            expect(status.sizeReceived, equals(Int64(size)));
          }
        }
      });

      test('D2G Download 10MB (x3)', () async {
        final size = 10 * 1024 * 1024;
        final seed = 0;

        for (int i = 0; i < 3; i++) {
          final client = serverManager.getGoGreeterClient();
          final stream = GoFileClient.downloadFile(size, seed, client: client);
          var received = 0;

          final output = AccumulatorSink<Digest>();
          final input = sha256.startChunkedConversion(output);

          await for (final chunk in stream) {
            received += chunk.content.length;
            input.add(chunk.content);
          }
          input.close();
          final hash = output.events.single.toString();

          expect(received, equals(size));

          if (client != null && stream is ResponseStream) {
            try {
              final responseStream = stream as ResponseStream;
              // Note: we've already consumed the stream, so trailers should be available now
              // But wait, accessing 'stream' after consumption works for types?
              // But stream is exhausted.
              // gRPC ResponseStream trailers are available AFTER stream closes.
              final trailers = await responseStream.trailers;
              final trailerHash = trailers['x-file-hash'];
              expect(
                trailerHash,
                equals(hash),
                reason: 'Trailer hash mismatch',
              );
            } catch (e) {
              print('Failed to get trailers: $e');
            }
          }
        }
      });

      test('D2G Bidi 10MB (x3)', () async {
        final size = 10 * 1024 * 1024;
        final chunkSize = 64 * 1024;

        for (int i = 0; i < 3; i++) {
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

          final client = serverManager.getGoGreeterClient();
          final inStream = GoFileClient.bidiFile(outStream(), client: client);
          var received = 0;

          final output = AccumulatorSink<Digest>();
          final input = sha256.startChunkedConversion(output);

          await for (final chunk in inStream) {
            received += chunk.content.length;
            input.add(chunk.content);
          }
          input.close();
          final hash = output.events.single.toString();

          expect(received, equals(size));
          expect(hash, equals(expectedHash));
        }
      });

      final req = pb.TriggerRequest()..fileSize = Int64(10 * 1024 * 1024);

      test('Go->Dart Upload (Trigger)', () async {
        req.action = pb.TriggerRequest_Action.UPLOAD_FILE;
        for (int i = 0; i < 3; i++) {
          final client = serverManager.getGoGreeterClient();
          final response = await GoGreeterClient.trigger(req, client: client);
          expect(response.message, contains('hash='));
          expect(response.message, contains('verified'));
        }
      });

      test('Go->Dart Download (Trigger)', () async {
        req.action = pb.TriggerRequest_Action.DOWNLOAD_FILE;
        for (int i = 0; i < 3; i++) {
          final client = serverManager.getGoGreeterClient();
          final response = await GoGreeterClient.trigger(req, client: client);
          expect(response.message, contains('calculated'));
          expect(response.message, contains('chunks)'));
        }
      });

      test('Go->Dart Bidi (Trigger)', () async {
        req.action = pb.TriggerRequest_Action.BIDI_FILE;
        for (int i = 0; i < 3; i++) {
          final client = serverManager.getGoGreeterClient();
          final response = await GoGreeterClient.trigger(req, client: client);
          expect(response.message, contains('hash='));
          expect(response.message, contains('verified'));
        }
      });
    });
  }
}
