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
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart' as $0;

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
