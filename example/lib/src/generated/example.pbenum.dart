// This is a generated file - do not edit.
//
// Generated from example.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class TriggerRequest_Action extends $pb.ProtobufEnum {
  static const TriggerRequest_Action UNARY =
      TriggerRequest_Action._(0, _omitEnumNames ? '' : 'UNARY');
  static const TriggerRequest_Action SERVER_STREAM =
      TriggerRequest_Action._(1, _omitEnumNames ? '' : 'SERVER_STREAM');
  static const TriggerRequest_Action CLIENT_STREAM =
      TriggerRequest_Action._(2, _omitEnumNames ? '' : 'CLIENT_STREAM');
  static const TriggerRequest_Action BIDI_STREAM =
      TriggerRequest_Action._(3, _omitEnumNames ? '' : 'BIDI_STREAM');
  static const TriggerRequest_Action UPLOAD_FILE =
      TriggerRequest_Action._(4, _omitEnumNames ? '' : 'UPLOAD_FILE');
  static const TriggerRequest_Action DOWNLOAD_FILE =
      TriggerRequest_Action._(5, _omitEnumNames ? '' : 'DOWNLOAD_FILE');
  static const TriggerRequest_Action BIDI_FILE =
      TriggerRequest_Action._(6, _omitEnumNames ? '' : 'BIDI_FILE');

  static const $core.List<TriggerRequest_Action> values =
      <TriggerRequest_Action>[
    UNARY,
    SERVER_STREAM,
    CLIENT_STREAM,
    BIDI_STREAM,
    UPLOAD_FILE,
    DOWNLOAD_FILE,
    BIDI_FILE,
  ];

  static final $core.List<TriggerRequest_Action?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static TriggerRequest_Action? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const TriggerRequest_Action._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
