// This is a generated file - do not edit.
//
// Generated from core.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use pingResponseDescriptor instead')
const PingResponse$json = {
  '1': 'PingResponse',
  '2': [
    {
      '1': 'timestamp',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'timestamp'
    },
    {'1': 'version', '3': 2, '4': 1, '5': 9, '10': 'version'},
  ],
};

/// Descriptor for `PingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pingResponseDescriptor = $convert.base64Decode(
    'CgxQaW5nUmVzcG9uc2USOAoJdGltZXN0YW1wGAEgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbW'
    'VzdGFtcFIJdGltZXN0YW1wEhgKB3ZlcnNpb24YAiABKAlSB3ZlcnNpb24=');

@$core.Deprecated('Use setMaxEntriesRequestDescriptor instead')
const SetMaxEntriesRequest$json = {
  '1': 'SetMaxEntriesRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
    {'1': 'max_entries', '3': 2, '4': 1, '5': 3, '10': 'maxEntries'},
  ],
};

/// Descriptor for `SetMaxEntriesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setMaxEntriesRequestDescriptor = $convert.base64Decode(
    'ChRTZXRNYXhFbnRyaWVzUmVxdWVzdBIdCgpzdG9yZV9uYW1lGAEgASgJUglzdG9yZU5hbWUSHw'
    'oLbWF4X2VudHJpZXMYAiABKANSCm1heEVudHJpZXM=');

@$core.Deprecated('Use setMaxBytesRequestDescriptor instead')
const SetMaxBytesRequest$json = {
  '1': 'SetMaxBytesRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
    {'1': 'max_bytes', '3': 2, '4': 1, '5': 3, '10': 'maxBytes'},
  ],
};

/// Descriptor for `SetMaxBytesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setMaxBytesRequestDescriptor = $convert.base64Decode(
    'ChJTZXRNYXhCeXRlc1JlcXVlc3QSHQoKc3RvcmVfbmFtZRgBIAEoCVIJc3RvcmVOYW1lEhsKCW'
    '1heF9ieXRlcxgCIAEoA1IIbWF4Qnl0ZXM=');

@$core.Deprecated('Use getStatsRequestDescriptor instead')
const GetStatsRequest$json = {
  '1': 'GetStatsRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
  ],
};

/// Descriptor for `GetStatsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getStatsRequestDescriptor = $convert.base64Decode(
    'Cg9HZXRTdGF0c1JlcXVlc3QSHQoKc3RvcmVfbmFtZRgBIAEoCVIJc3RvcmVOYW1l');

@$core.Deprecated('Use getStatsResponseDescriptor instead')
const GetStatsResponse$json = {
  '1': 'GetStatsResponse',
  '2': [
    {'1': 'count', '3': 1, '4': 1, '5': 3, '10': 'count'},
    {'1': 'size_bytes', '3': 2, '4': 1, '5': 3, '10': 'sizeBytes'},
  ],
};

/// Descriptor for `GetStatsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getStatsResponseDescriptor = $convert.base64Decode(
    'ChBHZXRTdGF0c1Jlc3BvbnNlEhQKBWNvdW50GAEgASgDUgVjb3VudBIdCgpzaXplX2J5dGVzGA'
    'IgASgDUglzaXplQnl0ZXM=');

@$core.Deprecated('Use getCacheRequestDescriptor instead')
const GetCacheRequest$json = {
  '1': 'GetCacheRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
    {'1': 'key', '3': 2, '4': 1, '5': 9, '10': 'key'},
  ],
};

/// Descriptor for `GetCacheRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getCacheRequestDescriptor = $convert.base64Decode(
    'Cg9HZXRDYWNoZVJlcXVlc3QSHQoKc3RvcmVfbmFtZRgBIAEoCVIJc3RvcmVOYW1lEhAKA2tleR'
    'gCIAEoCVIDa2V5');

@$core.Deprecated('Use getCacheResponseDescriptor instead')
const GetCacheResponse$json = {
  '1': 'GetCacheResponse',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 12, '10': 'value'},
  ],
};

/// Descriptor for `GetCacheResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getCacheResponseDescriptor = $convert
    .base64Decode('ChBHZXRDYWNoZVJlc3BvbnNlEhQKBXZhbHVlGAEgASgMUgV2YWx1ZQ==');

@$core.Deprecated('Use getCacheKeysResponseDescriptor instead')
const GetCacheKeysResponse$json = {
  '1': 'GetCacheKeysResponse',
  '2': [
    {'1': 'keys', '3': 1, '4': 3, '5': 9, '10': 'keys'},
  ],
};

/// Descriptor for `GetCacheKeysResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getCacheKeysResponseDescriptor = $convert
    .base64Decode('ChRHZXRDYWNoZUtleXNSZXNwb25zZRISCgRrZXlzGAEgAygJUgRrZXlz');

@$core.Deprecated('Use putCacheRequestDescriptor instead')
const PutCacheRequest$json = {
  '1': 'PutCacheRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
    {'1': 'key', '3': 2, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 3, '4': 1, '5': 12, '10': 'value'},
    {'1': 'ttl_seconds', '3': 4, '4': 1, '5': 3, '10': 'ttlSeconds'},
    {'1': 'cost', '3': 5, '4': 1, '5': 3, '10': 'cost'},
  ],
};

/// Descriptor for `PutCacheRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List putCacheRequestDescriptor = $convert.base64Decode(
    'Cg9QdXRDYWNoZVJlcXVlc3QSHQoKc3RvcmVfbmFtZRgBIAEoCVIJc3RvcmVOYW1lEhAKA2tleR'
    'gCIAEoCVIDa2V5EhQKBXZhbHVlGAMgASgMUgV2YWx1ZRIfCgt0dGxfc2Vjb25kcxgEIAEoA1IK'
    'dHRsU2Vjb25kcxISCgRjb3N0GAUgASgDUgRjb3N0');

@$core.Deprecated('Use deleteCacheRequestDescriptor instead')
const DeleteCacheRequest$json = {
  '1': 'DeleteCacheRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
    {'1': 'key', '3': 2, '4': 1, '5': 9, '10': 'key'},
  ],
};

/// Descriptor for `DeleteCacheRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteCacheRequestDescriptor = $convert.base64Decode(
    'ChJEZWxldGVDYWNoZVJlcXVlc3QSHQoKc3RvcmVfbmFtZRgBIAEoCVIJc3RvcmVOYW1lEhAKA2'
    'tleRgCIAEoCVIDa2V5');

@$core.Deprecated('Use clearCacheRequestDescriptor instead')
const ClearCacheRequest$json = {
  '1': 'ClearCacheRequest',
  '2': [
    {'1': 'store_name', '3': 1, '4': 1, '5': 9, '10': 'storeName'},
  ],
};

/// Descriptor for `ClearCacheRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearCacheRequestDescriptor = $convert.base64Decode(
    'ChFDbGVhckNhY2hlUmVxdWVzdBIdCgpzdG9yZV9uYW1lGAEgASgJUglzdG9yZU5hbWU=');

@$core.Deprecated('Use errorDescriptor instead')
const Error$json = {
  '1': 'Error',
  '2': [
    {'1': 'code', '3': 1, '4': 1, '5': 5, '10': 'code'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
    {'1': 'grpc_code', '3': 3, '4': 1, '5': 5, '10': 'grpcCode'},
  ],
};

/// Descriptor for `Error`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List errorDescriptor = $convert.base64Decode(
    'CgVFcnJvchISCgRjb2RlGAEgASgFUgRjb2RlEhgKB21lc3NhZ2UYAiABKAlSB21lc3NhZ2USGw'
    'oJZ3JwY19jb2RlGAMgASgFUghncnBjQ29kZQ==');
