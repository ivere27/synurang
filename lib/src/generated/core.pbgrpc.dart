// This is a generated file - do not edit.
//
// Generated from core.proto.

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
import 'package:synurang/src/generated/google/protobuf/empty.pb.dart' as $0;
import 'package:synurang/src/generated/google/protobuf/wrappers.pb.dart'
    as $2;

import 'core.pb.dart' as $1;

export 'core.pb.dart';

/// =============================================================================
/// HealthService - Basic health check
/// =============================================================================
@$pb.GrpcServiceName('core.v1.HealthService')
class HealthServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  HealthServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$1.PingResponse> ping(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$ping, request, options: options);
  }

  // method descriptors

  static final _$ping = $grpc.ClientMethod<$0.Empty, $1.PingResponse>(
      '/core.v1.HealthService/Ping',
      ($0.Empty value) => value.writeToBuffer(),
      $1.PingResponse.fromBuffer);
}

@$pb.GrpcServiceName('core.v1.HealthService')
abstract class HealthServiceBase extends $grpc.Service {
  $core.String get $name => 'core.v1.HealthService';

  HealthServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $1.PingResponse>(
        'Ping',
        ping_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($1.PingResponse value) => value.writeToBuffer()));
  }

  $async.Future<$1.PingResponse> ping_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return ping($call, await $request);
  }

  $async.Future<$1.PingResponse> ping($grpc.ServiceCall call, $0.Empty request);
}

/// =============================================================================
/// CacheService
/// =============================================================================
@$pb.GrpcServiceName('core.v1.CacheService')
class CacheServiceClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  CacheServiceClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$1.GetCacheResponse> get(
    $1.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$get, request, options: options);
  }

  /// Implementation MUST be synchronous in FFI mode to support zero-copy.
  /// The memory backing the 'value' field is only valid for the duration of the call.
  $grpc.ResponseFuture<$0.Empty> put(
    $1.PutCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$put, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> delete(
    $1.DeleteCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$delete, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> clear(
    $1.ClearCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$clear, request, options: options);
  }

  $grpc.ResponseFuture<$2.BoolValue> contains(
    $1.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$contains, request, options: options);
  }

  $grpc.ResponseFuture<$1.GetCacheKeysResponse> keys(
    $1.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$keys, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> setMaxEntries(
    $1.SetMaxEntriesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$setMaxEntries, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> setMaxBytes(
    $1.SetMaxBytesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$setMaxBytes, request, options: options);
  }

  $grpc.ResponseFuture<$1.GetStatsResponse> getStats(
    $1.GetStatsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getStats, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> compact(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$compact, request, options: options);
  }

  // method descriptors

  static final _$get =
      $grpc.ClientMethod<$1.GetCacheRequest, $1.GetCacheResponse>(
          '/core.v1.CacheService/Get',
          ($1.GetCacheRequest value) => value.writeToBuffer(),
          $1.GetCacheResponse.fromBuffer);
  static final _$put = $grpc.ClientMethod<$1.PutCacheRequest, $0.Empty>(
      '/core.v1.CacheService/Put',
      ($1.PutCacheRequest value) => value.writeToBuffer(),
      $0.Empty.fromBuffer);
  static final _$delete = $grpc.ClientMethod<$1.DeleteCacheRequest, $0.Empty>(
      '/core.v1.CacheService/Delete',
      ($1.DeleteCacheRequest value) => value.writeToBuffer(),
      $0.Empty.fromBuffer);
  static final _$clear = $grpc.ClientMethod<$1.ClearCacheRequest, $0.Empty>(
      '/core.v1.CacheService/Clear',
      ($1.ClearCacheRequest value) => value.writeToBuffer(),
      $0.Empty.fromBuffer);
  static final _$contains =
      $grpc.ClientMethod<$1.GetCacheRequest, $2.BoolValue>(
          '/core.v1.CacheService/Contains',
          ($1.GetCacheRequest value) => value.writeToBuffer(),
          $2.BoolValue.fromBuffer);
  static final _$keys =
      $grpc.ClientMethod<$1.GetCacheRequest, $1.GetCacheKeysResponse>(
          '/core.v1.CacheService/Keys',
          ($1.GetCacheRequest value) => value.writeToBuffer(),
          $1.GetCacheKeysResponse.fromBuffer);
  static final _$setMaxEntries =
      $grpc.ClientMethod<$1.SetMaxEntriesRequest, $0.Empty>(
          '/core.v1.CacheService/SetMaxEntries',
          ($1.SetMaxEntriesRequest value) => value.writeToBuffer(),
          $0.Empty.fromBuffer);
  static final _$setMaxBytes =
      $grpc.ClientMethod<$1.SetMaxBytesRequest, $0.Empty>(
          '/core.v1.CacheService/SetMaxBytes',
          ($1.SetMaxBytesRequest value) => value.writeToBuffer(),
          $0.Empty.fromBuffer);
  static final _$getStats =
      $grpc.ClientMethod<$1.GetStatsRequest, $1.GetStatsResponse>(
          '/core.v1.CacheService/GetStats',
          ($1.GetStatsRequest value) => value.writeToBuffer(),
          $1.GetStatsResponse.fromBuffer);
  static final _$compact = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/core.v1.CacheService/Compact',
      ($0.Empty value) => value.writeToBuffer(),
      $0.Empty.fromBuffer);
}

@$pb.GrpcServiceName('core.v1.CacheService')
abstract class CacheServiceBase extends $grpc.Service {
  $core.String get $name => 'core.v1.CacheService';

  CacheServiceBase() {
    $addMethod($grpc.ServiceMethod<$1.GetCacheRequest, $1.GetCacheResponse>(
        'Get',
        get_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.GetCacheRequest.fromBuffer(value),
        ($1.GetCacheResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.PutCacheRequest, $0.Empty>(
        'Put',
        put_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.PutCacheRequest.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.DeleteCacheRequest, $0.Empty>(
        'Delete',
        delete_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $1.DeleteCacheRequest.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.ClearCacheRequest, $0.Empty>(
        'Clear',
        clear_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.ClearCacheRequest.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.GetCacheRequest, $2.BoolValue>(
        'Contains',
        contains_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.GetCacheRequest.fromBuffer(value),
        ($2.BoolValue value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.GetCacheRequest, $1.GetCacheKeysResponse>(
        'Keys',
        keys_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.GetCacheRequest.fromBuffer(value),
        ($1.GetCacheKeysResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.SetMaxEntriesRequest, $0.Empty>(
        'SetMaxEntries',
        setMaxEntries_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $1.SetMaxEntriesRequest.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.SetMaxBytesRequest, $0.Empty>(
        'SetMaxBytes',
        setMaxBytes_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $1.SetMaxBytesRequest.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.GetStatsRequest, $1.GetStatsResponse>(
        'GetStats',
        getStats_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.GetStatsRequest.fromBuffer(value),
        ($1.GetStatsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'Compact',
        compact_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
  }

  $async.Future<$1.GetCacheResponse> get_Pre($grpc.ServiceCall $call,
      $async.Future<$1.GetCacheRequest> $request) async {
    return get($call, await $request);
  }

  $async.Future<$1.GetCacheResponse> get(
      $grpc.ServiceCall call, $1.GetCacheRequest request);

  $async.Future<$0.Empty> put_Pre($grpc.ServiceCall $call,
      $async.Future<$1.PutCacheRequest> $request) async {
    return put($call, await $request);
  }

  $async.Future<$0.Empty> put(
      $grpc.ServiceCall call, $1.PutCacheRequest request);

  $async.Future<$0.Empty> delete_Pre($grpc.ServiceCall $call,
      $async.Future<$1.DeleteCacheRequest> $request) async {
    return delete($call, await $request);
  }

  $async.Future<$0.Empty> delete(
      $grpc.ServiceCall call, $1.DeleteCacheRequest request);

  $async.Future<$0.Empty> clear_Pre($grpc.ServiceCall $call,
      $async.Future<$1.ClearCacheRequest> $request) async {
    return clear($call, await $request);
  }

  $async.Future<$0.Empty> clear(
      $grpc.ServiceCall call, $1.ClearCacheRequest request);

  $async.Future<$2.BoolValue> contains_Pre($grpc.ServiceCall $call,
      $async.Future<$1.GetCacheRequest> $request) async {
    return contains($call, await $request);
  }

  $async.Future<$2.BoolValue> contains(
      $grpc.ServiceCall call, $1.GetCacheRequest request);

  $async.Future<$1.GetCacheKeysResponse> keys_Pre($grpc.ServiceCall $call,
      $async.Future<$1.GetCacheRequest> $request) async {
    return keys($call, await $request);
  }

  $async.Future<$1.GetCacheKeysResponse> keys(
      $grpc.ServiceCall call, $1.GetCacheRequest request);

  $async.Future<$0.Empty> setMaxEntries_Pre($grpc.ServiceCall $call,
      $async.Future<$1.SetMaxEntriesRequest> $request) async {
    return setMaxEntries($call, await $request);
  }

  $async.Future<$0.Empty> setMaxEntries(
      $grpc.ServiceCall call, $1.SetMaxEntriesRequest request);

  $async.Future<$0.Empty> setMaxBytes_Pre($grpc.ServiceCall $call,
      $async.Future<$1.SetMaxBytesRequest> $request) async {
    return setMaxBytes($call, await $request);
  }

  $async.Future<$0.Empty> setMaxBytes(
      $grpc.ServiceCall call, $1.SetMaxBytesRequest request);

  $async.Future<$1.GetStatsResponse> getStats_Pre($grpc.ServiceCall $call,
      $async.Future<$1.GetStatsRequest> $request) async {
    return getStats($call, await $request);
  }

  $async.Future<$1.GetStatsResponse> getStats(
      $grpc.ServiceCall call, $1.GetStatsRequest request);

  $async.Future<$0.Empty> compact_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return compact($call, await $request);
  }

  $async.Future<$0.Empty> compact($grpc.ServiceCall call, $0.Empty request);
}
