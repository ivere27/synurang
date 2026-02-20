// This is a generated file - do not edit.
//
// Generated from cache.proto.

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
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart' as $1;
import 'package:protobuf/well_known_types/google/protobuf/wrappers.pb.dart'
    as $2;

import 'cache.pb.dart' as $0;

export 'cache.pb.dart';

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

  $grpc.ResponseFuture<$0.GetCacheResponse> get(
    $0.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$get, request, options: options);
  }

  /// Implementation MUST be synchronous in FFI mode to support zero-copy.
  /// The memory backing the 'value' field is only valid for the duration of the call.
  $grpc.ResponseFuture<$1.Empty> put(
    $0.PutCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$put, request, options: options);
  }

  $grpc.ResponseFuture<$1.Empty> delete(
    $0.DeleteCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$delete, request, options: options);
  }

  $grpc.ResponseFuture<$1.Empty> clear(
    $0.ClearCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$clear, request, options: options);
  }

  $grpc.ResponseFuture<$2.BoolValue> contains(
    $0.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$contains, request, options: options);
  }

  $grpc.ResponseFuture<$0.GetCacheKeysResponse> keys(
    $0.GetCacheRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$keys, request, options: options);
  }

  $grpc.ResponseFuture<$1.Empty> setMaxEntries(
    $0.SetMaxEntriesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$setMaxEntries, request, options: options);
  }

  $grpc.ResponseFuture<$1.Empty> setMaxBytes(
    $0.SetMaxBytesRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$setMaxBytes, request, options: options);
  }

  $grpc.ResponseFuture<$0.GetStatsResponse> getStats(
    $0.GetStatsRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getStats, request, options: options);
  }

  $grpc.ResponseFuture<$1.Empty> compact(
    $1.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$compact, request, options: options);
  }

  // method descriptors

  static final _$get =
      $grpc.ClientMethod<$0.GetCacheRequest, $0.GetCacheResponse>(
          '/core.v1.CacheService/Get',
          ($0.GetCacheRequest value) => value.writeToBuffer(),
          $0.GetCacheResponse.fromBuffer);
  static final _$put = $grpc.ClientMethod<$0.PutCacheRequest, $1.Empty>(
      '/core.v1.CacheService/Put',
      ($0.PutCacheRequest value) => value.writeToBuffer(),
      $1.Empty.fromBuffer);
  static final _$delete = $grpc.ClientMethod<$0.DeleteCacheRequest, $1.Empty>(
      '/core.v1.CacheService/Delete',
      ($0.DeleteCacheRequest value) => value.writeToBuffer(),
      $1.Empty.fromBuffer);
  static final _$clear = $grpc.ClientMethod<$0.ClearCacheRequest, $1.Empty>(
      '/core.v1.CacheService/Clear',
      ($0.ClearCacheRequest value) => value.writeToBuffer(),
      $1.Empty.fromBuffer);
  static final _$contains =
      $grpc.ClientMethod<$0.GetCacheRequest, $2.BoolValue>(
          '/core.v1.CacheService/Contains',
          ($0.GetCacheRequest value) => value.writeToBuffer(),
          $2.BoolValue.fromBuffer);
  static final _$keys =
      $grpc.ClientMethod<$0.GetCacheRequest, $0.GetCacheKeysResponse>(
          '/core.v1.CacheService/Keys',
          ($0.GetCacheRequest value) => value.writeToBuffer(),
          $0.GetCacheKeysResponse.fromBuffer);
  static final _$setMaxEntries =
      $grpc.ClientMethod<$0.SetMaxEntriesRequest, $1.Empty>(
          '/core.v1.CacheService/SetMaxEntries',
          ($0.SetMaxEntriesRequest value) => value.writeToBuffer(),
          $1.Empty.fromBuffer);
  static final _$setMaxBytes =
      $grpc.ClientMethod<$0.SetMaxBytesRequest, $1.Empty>(
          '/core.v1.CacheService/SetMaxBytes',
          ($0.SetMaxBytesRequest value) => value.writeToBuffer(),
          $1.Empty.fromBuffer);
  static final _$getStats =
      $grpc.ClientMethod<$0.GetStatsRequest, $0.GetStatsResponse>(
          '/core.v1.CacheService/GetStats',
          ($0.GetStatsRequest value) => value.writeToBuffer(),
          $0.GetStatsResponse.fromBuffer);
  static final _$compact = $grpc.ClientMethod<$1.Empty, $1.Empty>(
      '/core.v1.CacheService/Compact',
      ($1.Empty value) => value.writeToBuffer(),
      $1.Empty.fromBuffer);
}

@$pb.GrpcServiceName('core.v1.CacheService')
abstract class CacheServiceBase extends $grpc.Service {
  $core.String get $name => 'core.v1.CacheService';

  CacheServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.GetCacheRequest, $0.GetCacheResponse>(
        'Get',
        get_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetCacheRequest.fromBuffer(value),
        ($0.GetCacheResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.PutCacheRequest, $1.Empty>(
        'Put',
        put_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.PutCacheRequest.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DeleteCacheRequest, $1.Empty>(
        'Delete',
        delete_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.DeleteCacheRequest.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ClearCacheRequest, $1.Empty>(
        'Clear',
        clear_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ClearCacheRequest.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetCacheRequest, $2.BoolValue>(
        'Contains',
        contains_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetCacheRequest.fromBuffer(value),
        ($2.BoolValue value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetCacheRequest, $0.GetCacheKeysResponse>(
        'Keys',
        keys_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetCacheRequest.fromBuffer(value),
        ($0.GetCacheKeysResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.SetMaxEntriesRequest, $1.Empty>(
        'SetMaxEntries',
        setMaxEntries_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.SetMaxEntriesRequest.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.SetMaxBytesRequest, $1.Empty>(
        'SetMaxBytes',
        setMaxBytes_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $0.SetMaxBytesRequest.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.GetStatsRequest, $0.GetStatsResponse>(
        'GetStats',
        getStats_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.GetStatsRequest.fromBuffer(value),
        ($0.GetStatsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.Empty, $1.Empty>(
        'Compact',
        compact_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.Empty.fromBuffer(value),
        ($1.Empty value) => value.writeToBuffer()));
  }

  $async.Future<$0.GetCacheResponse> get_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetCacheRequest> $request) async {
    return get($call, await $request);
  }

  $async.Future<$0.GetCacheResponse> get(
      $grpc.ServiceCall call, $0.GetCacheRequest request);

  $async.Future<$1.Empty> put_Pre($grpc.ServiceCall $call,
      $async.Future<$0.PutCacheRequest> $request) async {
    return put($call, await $request);
  }

  $async.Future<$1.Empty> put(
      $grpc.ServiceCall call, $0.PutCacheRequest request);

  $async.Future<$1.Empty> delete_Pre($grpc.ServiceCall $call,
      $async.Future<$0.DeleteCacheRequest> $request) async {
    return delete($call, await $request);
  }

  $async.Future<$1.Empty> delete(
      $grpc.ServiceCall call, $0.DeleteCacheRequest request);

  $async.Future<$1.Empty> clear_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ClearCacheRequest> $request) async {
    return clear($call, await $request);
  }

  $async.Future<$1.Empty> clear(
      $grpc.ServiceCall call, $0.ClearCacheRequest request);

  $async.Future<$2.BoolValue> contains_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetCacheRequest> $request) async {
    return contains($call, await $request);
  }

  $async.Future<$2.BoolValue> contains(
      $grpc.ServiceCall call, $0.GetCacheRequest request);

  $async.Future<$0.GetCacheKeysResponse> keys_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetCacheRequest> $request) async {
    return keys($call, await $request);
  }

  $async.Future<$0.GetCacheKeysResponse> keys(
      $grpc.ServiceCall call, $0.GetCacheRequest request);

  $async.Future<$1.Empty> setMaxEntries_Pre($grpc.ServiceCall $call,
      $async.Future<$0.SetMaxEntriesRequest> $request) async {
    return setMaxEntries($call, await $request);
  }

  $async.Future<$1.Empty> setMaxEntries(
      $grpc.ServiceCall call, $0.SetMaxEntriesRequest request);

  $async.Future<$1.Empty> setMaxBytes_Pre($grpc.ServiceCall $call,
      $async.Future<$0.SetMaxBytesRequest> $request) async {
    return setMaxBytes($call, await $request);
  }

  $async.Future<$1.Empty> setMaxBytes(
      $grpc.ServiceCall call, $0.SetMaxBytesRequest request);

  $async.Future<$0.GetStatsResponse> getStats_Pre($grpc.ServiceCall $call,
      $async.Future<$0.GetStatsRequest> $request) async {
    return getStats($call, await $request);
  }

  $async.Future<$0.GetStatsResponse> getStats(
      $grpc.ServiceCall call, $0.GetStatsRequest request);

  $async.Future<$1.Empty> compact_Pre(
      $grpc.ServiceCall $call, $async.Future<$1.Empty> $request) async {
    return compact($call, await $request);
  }

  $async.Future<$1.Empty> compact($grpc.ServiceCall call, $1.Empty request);
}
