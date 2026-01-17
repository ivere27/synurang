// This is a generated file - do not edit.
//
// Generated from example.proto.

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

@$core.Deprecated('Use goroutinesRequestDescriptor instead')
const GoroutinesRequest$json = {
  '1': 'GoroutinesRequest',
  '2': [
    {'1': 'as_string', '3': 1, '4': 1, '5': 8, '10': 'asString'},
  ],
};

/// Descriptor for `GoroutinesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List goroutinesRequestDescriptor = $convert.base64Decode(
    'ChFHb3JvdXRpbmVzUmVxdWVzdBIbCglhc19zdHJpbmcYASABKAhSCGFzU3RyaW5n');

@$core.Deprecated('Use goroutinesResponseDescriptor instead')
const GoroutinesResponse$json = {
  '1': 'GoroutinesResponse',
  '2': [
    {'1': 'count', '3': 1, '4': 1, '5': 5, '10': 'count'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `GoroutinesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List goroutinesResponseDescriptor = $convert.base64Decode(
    'ChJHb3JvdXRpbmVzUmVzcG9uc2USFAoFY291bnQYASABKAVSBWNvdW50EhgKB21lc3NhZ2UYAi'
    'ABKAlSB21lc3NhZ2U=');

@$core.Deprecated('Use helloRequestDescriptor instead')
const HelloRequest$json = {
  '1': 'HelloRequest',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'language', '3': 2, '4': 1, '5': 9, '10': 'language'},
  ],
};

/// Descriptor for `HelloRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List helloRequestDescriptor = $convert.base64Decode(
    'CgxIZWxsb1JlcXVlc3QSEgoEbmFtZRgBIAEoCVIEbmFtZRIaCghsYW5ndWFnZRgCIAEoCVIIbG'
    'FuZ3VhZ2U=');

@$core.Deprecated('Use helloResponseDescriptor instead')
const HelloResponse$json = {
  '1': 'HelloResponse',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
    {'1': 'from', '3': 2, '4': 1, '5': 9, '10': 'from'},
    {
      '1': 'timestamp',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'timestamp'
    },
  ],
};

/// Descriptor for `HelloResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List helloResponseDescriptor = $convert.base64Decode(
    'Cg1IZWxsb1Jlc3BvbnNlEhgKB21lc3NhZ2UYASABKAlSB21lc3NhZ2USEgoEZnJvbRgCIAEoCV'
    'IEZnJvbRI4Cgl0aW1lc3RhbXAYAyABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgl0'
    'aW1lc3RhbXA=');

@$core.Deprecated('Use triggerRequestDescriptor instead')
const TriggerRequest$json = {
  '1': 'TriggerRequest',
  '2': [
    {
      '1': 'action',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.example.v1.TriggerRequest.Action',
      '10': 'action'
    },
    {
      '1': 'payload',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.example.v1.HelloRequest',
      '10': 'payload'
    },
    {'1': 'file_size', '3': 3, '4': 1, '5': 3, '10': 'fileSize'},
  ],
  '4': [TriggerRequest_Action$json],
};

@$core.Deprecated('Use triggerRequestDescriptor instead')
const TriggerRequest_Action$json = {
  '1': 'Action',
  '2': [
    {'1': 'UNARY', '2': 0},
    {'1': 'SERVER_STREAM', '2': 1},
    {'1': 'CLIENT_STREAM', '2': 2},
    {'1': 'BIDI_STREAM', '2': 3},
    {'1': 'UPLOAD_FILE', '2': 4},
    {'1': 'DOWNLOAD_FILE', '2': 5},
    {'1': 'BIDI_FILE', '2': 6},
  ],
};

/// Descriptor for `TriggerRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List triggerRequestDescriptor = $convert.base64Decode(
    'Cg5UcmlnZ2VyUmVxdWVzdBI5CgZhY3Rpb24YASABKA4yIS5leGFtcGxlLnYxLlRyaWdnZXJSZX'
    'F1ZXN0LkFjdGlvblIGYWN0aW9uEjIKB3BheWxvYWQYAiABKAsyGC5leGFtcGxlLnYxLkhlbGxv'
    'UmVxdWVzdFIHcGF5bG9hZBIbCglmaWxlX3NpemUYAyABKANSCGZpbGVTaXplIn0KBkFjdGlvbh'
    'IJCgVVTkFSWRAAEhEKDVNFUlZFUl9TVFJFQU0QARIRCg1DTElFTlRfU1RSRUFNEAISDwoLQklE'
    'SV9TVFJFQU0QAxIPCgtVUExPQURfRklMRRAEEhEKDURPV05MT0FEX0ZJTEUQBRINCglCSURJX0'
    'ZJTEUQBg==');

@$core.Deprecated('Use fileChunkDescriptor instead')
const FileChunk$json = {
  '1': 'FileChunk',
  '2': [
    {'1': 'content', '3': 1, '4': 1, '5': 12, '10': 'content'},
  ],
};

/// Descriptor for `FileChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileChunkDescriptor = $convert
    .base64Decode('CglGaWxlQ2h1bmsSGAoHY29udGVudBgBIAEoDFIHY29udGVudA==');

@$core.Deprecated('Use fileStatusDescriptor instead')
const FileStatus$json = {
  '1': 'FileStatus',
  '2': [
    {'1': 'size_received', '3': 1, '4': 1, '5': 3, '10': 'sizeReceived'},
  ],
};

/// Descriptor for `FileStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileStatusDescriptor = $convert.base64Decode(
    'CgpGaWxlU3RhdHVzEiMKDXNpemVfcmVjZWl2ZWQYASABKANSDHNpemVSZWNlaXZlZA==');

@$core.Deprecated('Use fileRequestDescriptor instead')
const FileRequest$json = {
  '1': 'FileRequest',
  '2': [
    {'1': 'size', '3': 1, '4': 1, '5': 3, '10': 'size'},
  ],
};

/// Descriptor for `FileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileRequestDescriptor =
    $convert.base64Decode('CgtGaWxlUmVxdWVzdBISCgRzaXplGAEgASgDUgRzaXpl');

@$core.Deprecated('Use downloadFileRequestDescriptor instead')
const DownloadFileRequest$json = {
  '1': 'DownloadFileRequest',
  '2': [
    {'1': 'size', '3': 1, '4': 1, '5': 3, '10': 'size'},
  ],
};

/// Descriptor for `DownloadFileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadFileRequestDescriptor = $convert
    .base64Decode('ChNEb3dubG9hZEZpbGVSZXF1ZXN0EhIKBHNpemUYASABKANSBHNpemU=');
