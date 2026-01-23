// This is a generated file - do not edit.
//
// Generated from core.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $3;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class PingResponse extends $pb.GeneratedMessage {
  factory PingResponse({
    $3.Timestamp? timestamp,
    $core.String? version,
  }) {
    final result = create();
    if (timestamp != null) result.timestamp = timestamp;
    if (version != null) result.version = version;
    return result;
  }

  PingResponse._();

  factory PingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PingResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOM<$3.Timestamp>(1, _omitFieldNames ? '' : 'timestamp',
        subBuilder: $3.Timestamp.create)
    ..aOS(2, _omitFieldNames ? '' : 'version')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PingResponse copyWith(void Function(PingResponse) updates) =>
      super.copyWith((message) => updates(message as PingResponse))
          as PingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PingResponse create() => PingResponse._();
  @$core.override
  PingResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PingResponse>(create);
  static PingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $3.Timestamp get timestamp => $_getN(0);
  @$pb.TagNumber(1)
  set timestamp($3.Timestamp value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTimestamp() => $_has(0);
  @$pb.TagNumber(1)
  void clearTimestamp() => $_clearField(1);
  @$pb.TagNumber(1)
  $3.Timestamp ensureTimestamp() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.String get version => $_getSZ(1);
  @$pb.TagNumber(2)
  set version($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearVersion() => $_clearField(2);
}

class SetMaxEntriesRequest extends $pb.GeneratedMessage {
  factory SetMaxEntriesRequest({
    $core.String? storeName,
    $fixnum.Int64? maxEntries,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    if (maxEntries != null) result.maxEntries = maxEntries;
    return result;
  }

  SetMaxEntriesRequest._();

  factory SetMaxEntriesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SetMaxEntriesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetMaxEntriesRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..aInt64(2, _omitFieldNames ? '' : 'maxEntries')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMaxEntriesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMaxEntriesRequest copyWith(void Function(SetMaxEntriesRequest) updates) =>
      super.copyWith((message) => updates(message as SetMaxEntriesRequest))
          as SetMaxEntriesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SetMaxEntriesRequest create() => SetMaxEntriesRequest._();
  @$core.override
  SetMaxEntriesRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SetMaxEntriesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetMaxEntriesRequest>(create);
  static SetMaxEntriesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get maxEntries => $_getI64(1);
  @$pb.TagNumber(2)
  set maxEntries($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxEntries() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxEntries() => $_clearField(2);
}

class SetMaxBytesRequest extends $pb.GeneratedMessage {
  factory SetMaxBytesRequest({
    $core.String? storeName,
    $fixnum.Int64? maxBytes,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    if (maxBytes != null) result.maxBytes = maxBytes;
    return result;
  }

  SetMaxBytesRequest._();

  factory SetMaxBytesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory SetMaxBytesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetMaxBytesRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..aInt64(2, _omitFieldNames ? '' : 'maxBytes')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMaxBytesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMaxBytesRequest copyWith(void Function(SetMaxBytesRequest) updates) =>
      super.copyWith((message) => updates(message as SetMaxBytesRequest))
          as SetMaxBytesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SetMaxBytesRequest create() => SetMaxBytesRequest._();
  @$core.override
  SetMaxBytesRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static SetMaxBytesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetMaxBytesRequest>(create);
  static SetMaxBytesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get maxBytes => $_getI64(1);
  @$pb.TagNumber(2)
  set maxBytes($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxBytes() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxBytes() => $_clearField(2);
}

class GetStatsRequest extends $pb.GeneratedMessage {
  factory GetStatsRequest({
    $core.String? storeName,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    return result;
  }

  GetStatsRequest._();

  factory GetStatsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetStatsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetStatsRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetStatsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetStatsRequest copyWith(void Function(GetStatsRequest) updates) =>
      super.copyWith((message) => updates(message as GetStatsRequest))
          as GetStatsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetStatsRequest create() => GetStatsRequest._();
  @$core.override
  GetStatsRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetStatsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetStatsRequest>(create);
  static GetStatsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);
}

class GetStatsResponse extends $pb.GeneratedMessage {
  factory GetStatsResponse({
    $fixnum.Int64? count,
    $fixnum.Int64? sizeBytes,
  }) {
    final result = create();
    if (count != null) result.count = count;
    if (sizeBytes != null) result.sizeBytes = sizeBytes;
    return result;
  }

  GetStatsResponse._();

  factory GetStatsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetStatsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetStatsResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aInt64(1, _omitFieldNames ? '' : 'count')
    ..aInt64(2, _omitFieldNames ? '' : 'sizeBytes')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetStatsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetStatsResponse copyWith(void Function(GetStatsResponse) updates) =>
      super.copyWith((message) => updates(message as GetStatsResponse))
          as GetStatsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetStatsResponse create() => GetStatsResponse._();
  @$core.override
  GetStatsResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetStatsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetStatsResponse>(create);
  static GetStatsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get count => $_getI64(0);
  @$pb.TagNumber(1)
  set count($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCount() => $_has(0);
  @$pb.TagNumber(1)
  void clearCount() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sizeBytes => $_getI64(1);
  @$pb.TagNumber(2)
  set sizeBytes($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSizeBytes() => $_has(1);
  @$pb.TagNumber(2)
  void clearSizeBytes() => $_clearField(2);
}

class GetCacheRequest extends $pb.GeneratedMessage {
  factory GetCacheRequest({
    $core.String? storeName,
    $core.String? key,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    if (key != null) result.key = key;
    return result;
  }

  GetCacheRequest._();

  factory GetCacheRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetCacheRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetCacheRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..aOS(2, _omitFieldNames ? '' : 'key')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheRequest copyWith(void Function(GetCacheRequest) updates) =>
      super.copyWith((message) => updates(message as GetCacheRequest))
          as GetCacheRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetCacheRequest create() => GetCacheRequest._();
  @$core.override
  GetCacheRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetCacheRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetCacheRequest>(create);
  static GetCacheRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get key => $_getSZ(1);
  @$pb.TagNumber(2)
  set key($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearKey() => $_clearField(2);
}

class GetCacheResponse extends $pb.GeneratedMessage {
  factory GetCacheResponse({
    $core.List<$core.int>? value,
  }) {
    final result = create();
    if (value != null) result.value = value;
    return result;
  }

  GetCacheResponse._();

  factory GetCacheResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetCacheResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetCacheResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'value', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheResponse copyWith(void Function(GetCacheResponse) updates) =>
      super.copyWith((message) => updates(message as GetCacheResponse))
          as GetCacheResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetCacheResponse create() => GetCacheResponse._();
  @$core.override
  GetCacheResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetCacheResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetCacheResponse>(create);
  static GetCacheResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get value => $_getN(0);
  @$pb.TagNumber(1)
  set value($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => $_clearField(1);
}

class GetCacheKeysResponse extends $pb.GeneratedMessage {
  factory GetCacheKeysResponse({
    $core.Iterable<$core.String>? keys,
  }) {
    final result = create();
    if (keys != null) result.keys.addAll(keys);
    return result;
  }

  GetCacheKeysResponse._();

  factory GetCacheKeysResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GetCacheKeysResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetCacheKeysResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'keys')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheKeysResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCacheKeysResponse copyWith(void Function(GetCacheKeysResponse) updates) =>
      super.copyWith((message) => updates(message as GetCacheKeysResponse))
          as GetCacheKeysResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetCacheKeysResponse create() => GetCacheKeysResponse._();
  @$core.override
  GetCacheKeysResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GetCacheKeysResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetCacheKeysResponse>(create);
  static GetCacheKeysResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get keys => $_getList(0);
}

class PutCacheRequest extends $pb.GeneratedMessage {
  factory PutCacheRequest({
    $core.String? storeName,
    $core.String? key,
    $core.List<$core.int>? value,
    $fixnum.Int64? ttlSeconds,
    $fixnum.Int64? cost,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    if (key != null) result.key = key;
    if (value != null) result.value = value;
    if (ttlSeconds != null) result.ttlSeconds = ttlSeconds;
    if (cost != null) result.cost = cost;
    return result;
  }

  PutCacheRequest._();

  factory PutCacheRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory PutCacheRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PutCacheRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..aOS(2, _omitFieldNames ? '' : 'key')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'value', $pb.PbFieldType.OY)
    ..aInt64(4, _omitFieldNames ? '' : 'ttlSeconds')
    ..aInt64(5, _omitFieldNames ? '' : 'cost')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PutCacheRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PutCacheRequest copyWith(void Function(PutCacheRequest) updates) =>
      super.copyWith((message) => updates(message as PutCacheRequest))
          as PutCacheRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PutCacheRequest create() => PutCacheRequest._();
  @$core.override
  PutCacheRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static PutCacheRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PutCacheRequest>(create);
  static PutCacheRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get key => $_getSZ(1);
  @$pb.TagNumber(2)
  set key($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearKey() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get value => $_getN(2);
  @$pb.TagNumber(3)
  set value($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasValue() => $_has(2);
  @$pb.TagNumber(3)
  void clearValue() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get ttlSeconds => $_getI64(3);
  @$pb.TagNumber(4)
  set ttlSeconds($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTtlSeconds() => $_has(3);
  @$pb.TagNumber(4)
  void clearTtlSeconds() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get cost => $_getI64(4);
  @$pb.TagNumber(5)
  set cost($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCost() => $_has(4);
  @$pb.TagNumber(5)
  void clearCost() => $_clearField(5);
}

class DeleteCacheRequest extends $pb.GeneratedMessage {
  factory DeleteCacheRequest({
    $core.String? storeName,
    $core.String? key,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    if (key != null) result.key = key;
    return result;
  }

  DeleteCacheRequest._();

  factory DeleteCacheRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory DeleteCacheRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteCacheRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..aOS(2, _omitFieldNames ? '' : 'key')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteCacheRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteCacheRequest copyWith(void Function(DeleteCacheRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteCacheRequest))
          as DeleteCacheRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static DeleteCacheRequest create() => DeleteCacheRequest._();
  @$core.override
  DeleteCacheRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static DeleteCacheRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteCacheRequest>(create);
  static DeleteCacheRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get key => $_getSZ(1);
  @$pb.TagNumber(2)
  set key($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearKey() => $_clearField(2);
}

class ClearCacheRequest extends $pb.GeneratedMessage {
  factory ClearCacheRequest({
    $core.String? storeName,
  }) {
    final result = create();
    if (storeName != null) result.storeName = storeName;
    return result;
  }

  ClearCacheRequest._();

  factory ClearCacheRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ClearCacheRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearCacheRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'storeName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearCacheRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearCacheRequest copyWith(void Function(ClearCacheRequest) updates) =>
      super.copyWith((message) => updates(message as ClearCacheRequest))
          as ClearCacheRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClearCacheRequest create() => ClearCacheRequest._();
  @$core.override
  ClearCacheRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ClearCacheRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClearCacheRequest>(create);
  static ClearCacheRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get storeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set storeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasStoreName() => $_has(0);
  @$pb.TagNumber(1)
  void clearStoreName() => $_clearField(1);
}

/// =============================================================================
/// Error handling
/// =============================================================================
class Error extends $pb.GeneratedMessage {
  factory Error({
    $core.int? code,
    $core.String? message,
    $core.int? grpcCode,
  }) {
    final result = create();
    if (code != null) result.code = code;
    if (message != null) result.message = message;
    if (grpcCode != null) result.grpcCode = grpcCode;
    return result;
  }

  Error._();

  factory Error.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Error.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Error',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'core.v1'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'code')
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..aI(3, _omitFieldNames ? '' : 'grpcCode')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error copyWith(void Function(Error) updates) =>
      super.copyWith((message) => updates(message as Error)) as Error;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Error create() => Error._();
  @$core.override
  Error createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Error getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Error>(create);
  static Error? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get code => $_getIZ(0);
  @$pb.TagNumber(1)
  set code($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearCode() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get grpcCode => $_getIZ(2);
  @$pb.TagNumber(3)
  set grpcCode($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasGrpcCode() => $_has(2);
  @$pb.TagNumber(3)
  void clearGrpcCode() => $_clearField(3);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
