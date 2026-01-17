// This is a generated file - do not edit.
//
// Generated from example.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'example.pb.dart' as $0;

export 'example.pb.dart';

/// =============================================================================
/// GoGreeterService - Go-side server, Dart client calls this
/// =============================================================================
@$pb.GrpcServiceName('example.v1.GoGreeterService')
class GoGreeterServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  GoGreeterServiceClient(super.channel, {super.options, super.interceptors});

  /// Simple RPC - single request, single response
  $grpc.ResponseFuture<$0.HelloResponse> bar(
    $0.HelloRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$bar, request, options: options);
  }

  /// Server-side streaming RPC - single request, stream of responses
  $grpc.ResponseStream<$0.HelloResponse> barServerStream(
    $0.HelloRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$barServerStream, $async.Stream.fromIterable([request]),
        options: options);
  }

  /// Client-side streaming RPC - stream of requests, single response
  $grpc.ResponseFuture<$0.HelloResponse> barClientStream(
    $async.Stream<$0.HelloRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$barClientStream, request, options: options)
        .single;
  }

  /// Bidirectional streaming RPC - stream of requests, stream of responses
  $grpc.ResponseStream<$0.HelloResponse> barBidiStream(
    $async.Stream<$0.HelloRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$barBidiStream, request, options: options);
  }

  /// File Streaming RPCs
  $grpc.ResponseFuture<$0.FileStatus> uploadFile(
    $async.Stream<$0.FileChunk> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$uploadFile, request, options: options).single;
  }

  $grpc.ResponseStream<$0.FileChunk> downloadFile(
    $0.DownloadFileRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$downloadFile, $async.Stream.fromIterable([request]),
        options: options);
  }

  $grpc.ResponseStream<$0.FileChunk> bidiFile(
    $async.Stream<$0.FileChunk> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$bidiFile, request, options: options);
  }

  /// Trigger - Generic entry point to trigger Go -> Dart calls (Demo specific)
  $grpc.ResponseFuture<$0.HelloResponse> trigger(
    $0.TriggerRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$trigger, request, options: options);
  }

  $grpc.ResponseFuture<$0.GoroutinesResponse> getGoroutines(
    $0.GoroutinesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getGoroutines, request, options: options);
  }

  // method descriptors

  static final _$bar = $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
      '/example.v1.GoGreeterService/Bar',
      ($0.HelloRequest value) => value.writeToBuffer(),
      $0.HelloResponse.fromBuffer);
  static final _$barServerStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.GoGreeterService/BarServerStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$barClientStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.GoGreeterService/BarClientStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$barBidiStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.GoGreeterService/BarBidiStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$uploadFile = $grpc.ClientMethod<$0.FileChunk, $0.FileStatus>(
      '/example.v1.GoGreeterService/UploadFile',
      ($0.FileChunk value) => value.writeToBuffer(),
      $0.FileStatus.fromBuffer);
  static final _$downloadFile =
      $grpc.ClientMethod<$0.DownloadFileRequest, $0.FileChunk>(
          '/example.v1.GoGreeterService/DownloadFile',
          ($0.DownloadFileRequest value) => value.writeToBuffer(),
          $0.FileChunk.fromBuffer);
  static final _$bidiFile = $grpc.ClientMethod<$0.FileChunk, $0.FileChunk>(
      '/example.v1.GoGreeterService/BidiFile',
      ($0.FileChunk value) => value.writeToBuffer(),
      $0.FileChunk.fromBuffer);
  static final _$trigger =
      $grpc.ClientMethod<$0.TriggerRequest, $0.HelloResponse>(
          '/example.v1.GoGreeterService/Trigger',
          ($0.TriggerRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$getGoroutines =
      $grpc.ClientMethod<$0.GoroutinesRequest, $0.GoroutinesResponse>(
          '/example.v1.GoGreeterService/GetGoroutines',
          ($0.GoroutinesRequest value) => value.writeToBuffer(),
          $0.GoroutinesResponse.fromBuffer);
}

@$pb.GrpcServiceName('example.v1.GoGreeterService')
abstract class GoGreeterServiceBase extends $grpc.Service {
  $core.String get $name => 'example.v1.GoGreeterService';

  GoGreeterServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'Bar',
        bar_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'BarServerStream',
        barServerStream_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'BarClientStream',
        barClientStream,
        true,
        false,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'BarBidiStream',
        barBidiStream,
        true,
        true,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.FileChunk, $0.FileStatus>(
        'UploadFile',
        uploadFile,
        true,
        false,
        ($core.List<$core.int> value) => $0.FileChunk.fromBuffer(value),
        ($0.FileStatus value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DownloadFileRequest, $0.FileChunk>(
        'DownloadFile',
        downloadFile_Pre,
        false,
        true,
        ($core.List<$core.int> value) =>
            $0.DownloadFileRequest.fromBuffer(value),
        ($0.FileChunk value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.FileChunk, $0.FileChunk>(
        'BidiFile',
        bidiFile,
        true,
        true,
        ($core.List<$core.int> value) => $0.FileChunk.fromBuffer(value),
        ($0.FileChunk value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TriggerRequest, $0.HelloResponse>(
        'Trigger',
        trigger_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.TriggerRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GoroutinesRequest, $0.GoroutinesResponse>(
        'GetGoroutines',
        getGoroutines_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GoroutinesRequest.fromBuffer(value),
        ($0.GoroutinesResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.HelloResponse> bar_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.HelloRequest> $request) async {
    return bar($call, await $request);
  }

  $async.Future<$0.HelloResponse> bar(
      $grpc.ServiceCall call, $0.HelloRequest request);

  $async.Stream<$0.HelloResponse> barServerStream_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.HelloRequest> $request) async* {
    yield* barServerStream($call, await $request);
  }

  $async.Stream<$0.HelloResponse> barServerStream(
      $grpc.ServiceCall call, $0.HelloRequest request);

  $async.Future<$0.HelloResponse> barClientStream(
      $grpc.ServiceCall call, $async.Stream<$0.HelloRequest> request);

  $async.Stream<$0.HelloResponse> barBidiStream(
      $grpc.ServiceCall call, $async.Stream<$0.HelloRequest> request);

  $async.Future<$0.FileStatus> uploadFile(
      $grpc.ServiceCall call, $async.Stream<$0.FileChunk> request);

  $async.Stream<$0.FileChunk> downloadFile_Pre($grpc.ServiceCall $call,
      $async.Future<$0.DownloadFileRequest> $request) async* {
    yield* downloadFile($call, await $request);
  }

  $async.Stream<$0.FileChunk> downloadFile(
      $grpc.ServiceCall call, $0.DownloadFileRequest request);

  $async.Stream<$0.FileChunk> bidiFile(
      $grpc.ServiceCall call, $async.Stream<$0.FileChunk> request);

  $async.Future<$0.HelloResponse> trigger_Pre($grpc.ServiceCall $call,
      $async.Future<$0.TriggerRequest> $request) async {
    return trigger($call, await $request);
  }

  $async.Future<$0.HelloResponse> trigger(
      $grpc.ServiceCall call, $0.TriggerRequest request);

  $async.Future<$0.GoroutinesResponse> getGoroutines_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$0.GoroutinesRequest> $request) async {
    return getGoroutines($call, await $request);
  }

  $async.Future<$0.GoroutinesResponse> getGoroutines(
      $grpc.ServiceCall call, $0.GoroutinesRequest request);
}

/// =============================================================================
/// DartGreeterService - Dart-side server, Go client calls this
/// =============================================================================
@$pb.GrpcServiceName('example.v1.DartGreeterService')
class DartGreeterServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  DartGreeterServiceClient(super.channel, {super.options, super.interceptors});

  /// Simple RPC - single request, single response
  $grpc.ResponseFuture<$0.HelloResponse> foo(
    $0.HelloRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$foo, request, options: options);
  }

  /// Server-side streaming RPC - single request, stream of responses
  $grpc.ResponseStream<$0.HelloResponse> fooServerStream(
    $0.HelloRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$fooServerStream, $async.Stream.fromIterable([request]),
        options: options);
  }

  /// Client-side streaming RPC - stream of requests, single response
  $grpc.ResponseFuture<$0.HelloResponse> fooClientStream(
    $async.Stream<$0.HelloRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$fooClientStream, request, options: options)
        .single;
  }

  /// Bidirectional streaming RPC - stream of requests, stream of responses
  $grpc.ResponseStream<$0.HelloResponse> fooBidiStream(
    $async.Stream<$0.HelloRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$fooBidiStream, request, options: options);
  }

  /// File Streaming RPCs
  $grpc.ResponseFuture<$0.FileStatus> dartUploadFile(
    $async.Stream<$0.FileChunk> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$dartUploadFile, request, options: options)
        .single;
  }

  $grpc.ResponseStream<$0.FileChunk> dartDownloadFile(
    $0.DownloadFileRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$dartDownloadFile, $async.Stream.fromIterable([request]),
        options: options);
  }

  $grpc.ResponseStream<$0.FileChunk> dartBidiFile(
    $async.Stream<$0.FileChunk> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$dartBidiFile, request, options: options);
  }

  // method descriptors

  static final _$foo = $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
      '/example.v1.DartGreeterService/Foo',
      ($0.HelloRequest value) => value.writeToBuffer(),
      $0.HelloResponse.fromBuffer);
  static final _$fooServerStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.DartGreeterService/FooServerStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$fooClientStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.DartGreeterService/FooClientStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$fooBidiStream =
      $grpc.ClientMethod<$0.HelloRequest, $0.HelloResponse>(
          '/example.v1.DartGreeterService/FooBidiStream',
          ($0.HelloRequest value) => value.writeToBuffer(),
          $0.HelloResponse.fromBuffer);
  static final _$dartUploadFile =
      $grpc.ClientMethod<$0.FileChunk, $0.FileStatus>(
          '/example.v1.DartGreeterService/DartUploadFile',
          ($0.FileChunk value) => value.writeToBuffer(),
          $0.FileStatus.fromBuffer);
  static final _$dartDownloadFile =
      $grpc.ClientMethod<$0.DownloadFileRequest, $0.FileChunk>(
          '/example.v1.DartGreeterService/DartDownloadFile',
          ($0.DownloadFileRequest value) => value.writeToBuffer(),
          $0.FileChunk.fromBuffer);
  static final _$dartBidiFile = $grpc.ClientMethod<$0.FileChunk, $0.FileChunk>(
      '/example.v1.DartGreeterService/DartBidiFile',
      ($0.FileChunk value) => value.writeToBuffer(),
      $0.FileChunk.fromBuffer);
}

@$pb.GrpcServiceName('example.v1.DartGreeterService')
abstract class DartGreeterServiceBase extends $grpc.Service {
  $core.String get $name => 'example.v1.DartGreeterService';

  DartGreeterServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'Foo',
        foo_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'FooServerStream',
        fooServerStream_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'FooClientStream',
        fooClientStream,
        true,
        false,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.HelloRequest, $0.HelloResponse>(
        'FooBidiStream',
        fooBidiStream,
        true,
        true,
        ($core.List<$core.int> value) => $0.HelloRequest.fromBuffer(value),
        ($0.HelloResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.FileChunk, $0.FileStatus>(
        'DartUploadFile',
        dartUploadFile,
        true,
        false,
        ($core.List<$core.int> value) => $0.FileChunk.fromBuffer(value),
        ($0.FileStatus value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DownloadFileRequest, $0.FileChunk>(
        'DartDownloadFile',
        dartDownloadFile_Pre,
        false,
        true,
        ($core.List<$core.int> value) =>
            $0.DownloadFileRequest.fromBuffer(value),
        ($0.FileChunk value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.FileChunk, $0.FileChunk>(
        'DartBidiFile',
        dartBidiFile,
        true,
        true,
        ($core.List<$core.int> value) => $0.FileChunk.fromBuffer(value),
        ($0.FileChunk value) => value.writeToBuffer()));
  }

  $async.Future<$0.HelloResponse> foo_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.HelloRequest> $request) async {
    return foo($call, await $request);
  }

  $async.Future<$0.HelloResponse> foo(
      $grpc.ServiceCall call, $0.HelloRequest request);

  $async.Stream<$0.HelloResponse> fooServerStream_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.HelloRequest> $request) async* {
    yield* fooServerStream($call, await $request);
  }

  $async.Stream<$0.HelloResponse> fooServerStream(
      $grpc.ServiceCall call, $0.HelloRequest request);

  $async.Future<$0.HelloResponse> fooClientStream(
      $grpc.ServiceCall call, $async.Stream<$0.HelloRequest> request);

  $async.Stream<$0.HelloResponse> fooBidiStream(
      $grpc.ServiceCall call, $async.Stream<$0.HelloRequest> request);

  $async.Future<$0.FileStatus> dartUploadFile(
      $grpc.ServiceCall call, $async.Stream<$0.FileChunk> request);

  $async.Stream<$0.FileChunk> dartDownloadFile_Pre($grpc.ServiceCall $call,
      $async.Future<$0.DownloadFileRequest> $request) async* {
    yield* dartDownloadFile($call, await $request);
  }

  $async.Stream<$0.FileChunk> dartDownloadFile(
      $grpc.ServiceCall call, $0.DownloadFileRequest request);

  $async.Stream<$0.FileChunk> dartBidiFile(
      $grpc.ServiceCall call, $async.Stream<$0.FileChunk> request);
}
