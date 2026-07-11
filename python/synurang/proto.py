"""Dependency-free implementations of common ``google.protobuf`` messages."""

from __future__ import annotations

from enum import IntEnum

from .protolite import Field, ProtoMessage, register_enum


class NullValue(IntEnum):
    NULL_VALUE = 0


register_enum("google.protobuf.NullValue", NullValue)


class Empty(ProtoMessage):
    __proto_name__ = "google.protobuf.Empty"


class DoubleValue(ProtoMessage):
    __proto_name__ = "google.protobuf.DoubleValue"
    __fields__ = (Field(1, "value", "double"),)


class FloatValue(ProtoMessage):
    __proto_name__ = "google.protobuf.FloatValue"
    __fields__ = (Field(1, "value", "float"),)


class Int64Value(ProtoMessage):
    __proto_name__ = "google.protobuf.Int64Value"
    __fields__ = (Field(1, "value", "int64"),)


class UInt64Value(ProtoMessage):
    __proto_name__ = "google.protobuf.UInt64Value"
    __fields__ = (Field(1, "value", "uint64"),)


class Int32Value(ProtoMessage):
    __proto_name__ = "google.protobuf.Int32Value"
    __fields__ = (Field(1, "value", "int32"),)


class UInt32Value(ProtoMessage):
    __proto_name__ = "google.protobuf.UInt32Value"
    __fields__ = (Field(1, "value", "uint32"),)


class BoolValue(ProtoMessage):
    __proto_name__ = "google.protobuf.BoolValue"
    __fields__ = (Field(1, "value", "bool"),)


class StringValue(ProtoMessage):
    __proto_name__ = "google.protobuf.StringValue"
    __fields__ = (Field(1, "value", "string"),)


class BytesValue(ProtoMessage):
    __proto_name__ = "google.protobuf.BytesValue"
    __fields__ = (Field(1, "value", "bytes"),)


class Timestamp(ProtoMessage):
    __proto_name__ = "google.protobuf.Timestamp"
    __fields__ = (
        Field(1, "seconds", "int64"),
        Field(2, "nanos", "int32"),
    )


class Duration(ProtoMessage):
    __proto_name__ = "google.protobuf.Duration"
    __fields__ = (
        Field(1, "seconds", "int64"),
        Field(2, "nanos", "int32"),
    )


class Any(ProtoMessage):
    __proto_name__ = "google.protobuf.Any"
    __fields__ = (
        Field(1, "type_url", "string"),
        Field(2, "value", "bytes"),
    )


class Struct(ProtoMessage):
    __proto_name__ = "google.protobuf.Struct"
    __fields__ = (
        Field(
            1,
            "fields",
            "message",
            is_map=True,
            map_key_kind="string",
            map_value_kind="message",
            map_value_type_name="google.protobuf.Value",
        ),
    )


class ListValue(ProtoMessage):
    __proto_name__ = "google.protobuf.ListValue"
    __fields__ = (
        Field(
            1,
            "values",
            "message",
            repeated=True,
            type_name="google.protobuf.Value",
        ),
    )


class Value(ProtoMessage):
    __proto_name__ = "google.protobuf.Value"
    __fields__ = (
        Field(1, "null_value", "enum", oneof="kind", type_name="google.protobuf.NullValue"),
        Field(2, "number_value", "double", oneof="kind"),
        Field(3, "string_value", "string", oneof="kind"),
        Field(4, "bool_value", "bool", oneof="kind"),
        Field(5, "struct_value", "message", oneof="kind", type_name="google.protobuf.Struct"),
        Field(6, "list_value", "message", oneof="kind", type_name="google.protobuf.ListValue"),
    )


class FieldMask(ProtoMessage):
    __proto_name__ = "google.protobuf.FieldMask"
    __fields__ = (Field(1, "paths", "string", repeated=True),)


__all__ = [
    "Any",
    "BoolValue",
    "BytesValue",
    "DoubleValue",
    "Duration",
    "Empty",
    "FieldMask",
    "FloatValue",
    "Int32Value",
    "Int64Value",
    "ListValue",
    "NullValue",
    "StringValue",
    "Struct",
    "Timestamp",
    "UInt32Value",
    "UInt64Value",
    "Value",
]
