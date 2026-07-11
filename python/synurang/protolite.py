"""Small, dependency-free Protocol Buffers codec used by generated lite types."""

from __future__ import annotations

import base64
import copy
import json
import math
import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import Any, ClassVar, TypeVar


class ProtoError(ValueError):
    """Base class for protobuf-lite encoding and decoding failures."""


class DecodeError(ProtoError):
    """Raised when a protobuf payload is malformed."""


class EncodeError(ProtoError):
    """Raised when a message value cannot be encoded."""


@dataclass(frozen=True, slots=True)
class Field:
    """Generated protobuf field metadata."""

    number: int
    name: str
    kind: str
    repeated: bool = False
    optional: bool = False
    oneof: str | None = None
    type_name: str = ""
    is_map: bool = False
    map_key_kind: str = ""
    map_value_kind: str = ""
    map_value_type_name: str = ""


MessageT = TypeVar("MessageT", bound="ProtoMessage")

_MESSAGE_TYPES: dict[str, type["ProtoMessage"]] = {}
_ENUM_TYPES: dict[str, type[IntEnum]] = {}
_MAX_FIELD_NUMBER = (1 << 29) - 1


def register_message(message_type: type[MessageT]) -> type[MessageT]:
    """Register a generated message by protobuf fully-qualified name."""

    name = message_type.__proto_name__
    if name:
        _MESSAGE_TYPES[name.lstrip(".")] = message_type
    _MESSAGE_TYPES[message_type.__name__] = message_type
    return message_type


def register_enum(name: str, enum_type: type[IntEnum]) -> type[IntEnum]:
    """Register a generated enum for reflection and JSON conversion."""

    if name:
        _ENUM_TYPES[name.lstrip(".")] = enum_type
    _ENUM_TYPES[enum_type.__name__] = enum_type
    return enum_type


def attach_nested(namespace: dict[str, Any], python_name: str, value: Any) -> None:
    """Expose a flattened generated type through its Python nested name."""

    parts = python_name.split(".")
    if len(parts) < 2:
        return
    parent = namespace.get(parts[0])
    if parent is None:
        parent = next(
            (
                value
                for value in namespace.values()
                if getattr(value, "__python_name__", None) == parts[0]
            ),
            None,
        )
    if parent is None:
        raise ProtoError(f"cannot attach nested protobuf type {python_name!r}")
    for part in parts[1:-1]:
        parent = getattr(parent, part)
    setattr(parent, parts[-1], value)


class ProtoMessage:
    """Base class for generated zero-dependency protobuf messages."""

    __proto_name__: ClassVar[str] = ""
    __python_name__: ClassVar[str] = ""
    __fields__: ClassVar[tuple[Field, ...]] = ()
    __fields_by_name__: ClassVar[dict[str, Field]] = {}
    __fields_by_number__: ClassVar[dict[int, Field]] = {}
    __oneofs__: ClassVar[dict[str, tuple[Field, ...]]] = {}

    def __init_subclass__(cls, **kwargs: Any) -> None:
        super().__init_subclass__(**kwargs)
        cls.__fields__ = tuple(cls.__fields__)
        cls.__fields_by_name__ = {field.name: field for field in cls.__fields__}
        cls.__fields_by_number__ = {field.number: field for field in cls.__fields__}
        oneofs: dict[str, list[Field]] = {}
        for field in cls.__fields__:
            if field.oneof:
                oneofs.setdefault(field.oneof, []).append(field)
        cls.__oneofs__ = {name: tuple(fields) for name, fields in oneofs.items()}
        if cls.__proto_name__:
            register_message(cls)

    def __init__(self, **values: Any) -> None:
        object.__setattr__(self, "_present", set())
        object.__setattr__(self, "_oneof_cases", {})
        object.__setattr__(self, "_initializing", True)
        for field in self.__fields__:
            object.__setattr__(self, field.name, _default_value(field))
        object.__setattr__(self, "_initializing", False)
        unknown = set(values).difference(self.__fields_by_name__)
        if unknown:
            names = ", ".join(sorted(unknown))
            raise TypeError(f"unknown field(s) for {type(self).__name__}: {names}")
        for name, value in values.items():
            setattr(self, name, value)

    def __setattr__(self, name: str, value: Any) -> None:
        field = type(self).__fields_by_name__.get(name)
        if field is None or getattr(self, "_initializing", False):
            object.__setattr__(self, name, value)
            return
        if value is None:
            if field.kind != "message" and not field.optional and not field.oneof:
                raise TypeError(f"field {name!r} does not accept None")
            self.ClearField(name)
            return
        value = _coerce_value(field, value)
        if field.oneof:
            previous = self._oneof_cases.get(field.oneof)
            if previous and previous != name:
                previous_field = self.__fields_by_name__[previous]
                object.__setattr__(self, previous, _default_value(previous_field))
                self._present.discard(previous_field.number)
            self._oneof_cases[field.oneof] = name
        object.__setattr__(self, name, value)
        self._present.add(field.number)

    def SerializeToString(self, deterministic: bool = False) -> bytes:
        return _encode_message(self, deterministic=deterministic)

    def SerializePartialToString(self, deterministic: bool = False) -> bytes:
        return self.SerializeToString(deterministic=deterministic)

    def to_bytes(self, deterministic: bool = False) -> bytes:
        return self.SerializeToString(deterministic=deterministic)

    def toByteArray(self) -> bytes:
        return self.SerializeToString()

    def ParseFromString(self, data: bytes | bytearray | memoryview) -> int:
        self.Clear()
        payload = bytes(data)
        _decode_message(self, payload)
        return len(payload)

    def MergeFromString(self, data: bytes | bytearray | memoryview) -> int:
        incoming = type(self).FromString(data)
        self.MergeFrom(incoming)
        return len(data)

    @classmethod
    def FromString(cls: type[MessageT], data: bytes | bytearray | memoryview) -> MessageT:
        message = cls()
        message.ParseFromString(data)
        return message

    @classmethod
    def from_bytes(cls: type[MessageT], data: bytes | bytearray | memoryview) -> MessageT:
        return cls.FromString(data)

    @classmethod
    def parseFrom(cls: type[MessageT], data: bytes | bytearray | memoryview) -> MessageT:
        return cls.FromString(data)

    def ByteSize(self) -> int:
        return len(self.SerializeToString())

    def HasField(self, name: str) -> bool:
        field = self.__fields_by_name__.get(name)
        if field is None:
            if name in self.__oneofs__:
                return name in self._oneof_cases
            raise ValueError(f"unknown field {name!r}")
        if field.kind != "message" and not field.optional and not field.oneof:
            raise ValueError(f"field {name!r} does not track presence")
        return field.number in self._present

    def WhichOneof(self, name: str) -> str | None:
        if name not in self.__oneofs__:
            raise ValueError(f"unknown oneof {name!r}")
        return self._oneof_cases.get(name)

    def ClearField(self, name: str) -> None:
        if name in self.__oneofs__:
            active = self._oneof_cases.pop(name, None)
            if active is not None:
                self.ClearField(active)
            return
        field = self.__fields_by_name__.get(name)
        if field is None:
            raise ValueError(f"unknown field {name!r}")
        object.__setattr__(self, name, _default_value(field))
        self._present.discard(field.number)
        if field.oneof and self._oneof_cases.get(field.oneof) == name:
            self._oneof_cases.pop(field.oneof, None)

    def Clear(self) -> None:
        for field in self.__fields__:
            object.__setattr__(self, field.name, _default_value(field))
        self._present.clear()
        self._oneof_cases.clear()

    def CopyFrom(self, other: "ProtoMessage") -> None:
        if type(other) is not type(self):
            raise TypeError("CopyFrom requires messages of the same type")
        self.Clear()
        self.MergeFrom(other)

    def MergeFrom(self, other: "ProtoMessage") -> None:
        if type(other) is not type(self):
            raise TypeError("MergeFrom requires messages of the same type")
        for field in self.__fields__:
            value = getattr(other, field.name)
            if field.repeated:
                getattr(self, field.name).extend(copy.deepcopy(value))
            elif field.is_map:
                getattr(self, field.name).update(copy.deepcopy(value))
            elif field.number in other._present:
                current = getattr(self, field.name)
                can_merge_message = (
                    field.kind == "message"
                    and current is not None
                    and value is not None
                    and (
                        not field.oneof
                        or self._oneof_cases.get(field.oneof) == field.name
                    )
                )
                if can_merge_message:
                    current.MergeFrom(value)
                    self._present.add(field.number)
                else:
                    setattr(self, field.name, copy.deepcopy(value))

    def to_dict(self) -> dict[str, Any]:
        output: dict[str, Any] = {}
        for field in self.__fields__:
            if field.oneof and self._oneof_cases.get(field.oneof) != field.name:
                continue
            value = getattr(self, field.name)
            if field.repeated:
                if value:
                    output[field.name] = [_json_value(field, item) for item in value]
            elif field.is_map:
                if value:
                    output[field.name] = {
                        str(key): _json_map_value(field, item)
                        for key, item in value.items()
                    }
            elif field.kind == "message":
                if value is not None:
                    output[field.name] = _json_value(field, value)
            elif field.number in self._present or not _is_default_value(
                field.kind, value
            ):
                output[field.name] = _json_value(field, value)
        return output

    def to_json(self, **kwargs: Any) -> str:
        return json.dumps(self.to_dict(), **kwargs)

    def __repr__(self) -> str:
        values = ", ".join(
            f"{field.name}={getattr(self, field.name)!r}"
            for field in self.__fields__
            if _should_show(self, field)
        )
        return f"{type(self).__name__}({values})"

    def __eq__(self, other: object) -> bool:
        if type(other) is not type(self):
            return False
        assert isinstance(other, ProtoMessage)
        if not all(
            getattr(self, field.name) == getattr(other, field.name)
            for field in self.__fields__
        ):
            return False
        presence_fields = {
            field.number for field in self.__fields__ if field.optional or field.oneof
        }
        return (
            self._present.intersection(presence_fields)
            == other._present.intersection(presence_fields)
            and self._oneof_cases == other._oneof_cases
        )


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0

    @property
    def eof(self) -> bool:
        return self.offset >= len(self.data)

    def varint(self) -> int:
        value = 0
        for shift in range(0, 70, 7):
            if self.offset >= len(self.data):
                raise DecodeError("truncated protobuf varint")
            byte = self.data[self.offset]
            self.offset += 1
            if shift == 63 and byte > 1:
                raise DecodeError("protobuf varint exceeds 64 bits")
            value |= (byte & 0x7F) << shift
            if byte & 0x80 == 0:
                return value
        raise DecodeError("protobuf varint exceeds 10 bytes")

    def raw(self, size: int) -> bytes:
        if size < 0 or self.offset + size > len(self.data):
            raise DecodeError("truncated protobuf payload")
        result = self.data[self.offset : self.offset + size]
        self.offset += size
        return result

    def length_delimited(self) -> bytes:
        return self.raw(self.varint())

    def skip(self, wire_type: int) -> None:
        if wire_type == 0:
            self.varint()
        elif wire_type == 1:
            self.raw(8)
        elif wire_type == 2:
            self.length_delimited()
        elif wire_type == 5:
            self.raw(4)
        else:
            raise DecodeError(f"unsupported protobuf wire type {wire_type}")


class _Writer:
    def __init__(self) -> None:
        self.data = bytearray()

    def varint(self, value: int) -> None:
        value &= (1 << 64) - 1
        while value >= 0x80:
            self.data.append((value & 0x7F) | 0x80)
            value >>= 7
        self.data.append(value)

    def tag(self, field_number: int, wire_type: int) -> None:
        self.varint((field_number << 3) | wire_type)

    def length_delimited(self, value: bytes) -> None:
        self.varint(len(value))
        self.data.extend(value)


def _decode_message(message: ProtoMessage, data: bytes) -> None:
    reader = _Reader(data)
    while not reader.eof:
        tag = reader.varint()
        field_number = tag >> 3
        wire_type = tag & 0x07
        if field_number == 0:
            raise DecodeError("protobuf field number cannot be zero")
        if field_number > _MAX_FIELD_NUMBER:
            raise DecodeError(
                f"protobuf field number exceeds maximum {_MAX_FIELD_NUMBER}"
            )
        field = message.__fields_by_number__.get(field_number)
        if field is None:
            reader.skip(wire_type)
            continue
        if field.is_map:
            if wire_type != 2:
                reader.skip(wire_type)
                continue
            key, value = _decode_map_entry(field, reader.length_delimited())
            getattr(message, field.name)[key] = value
            message._present.add(field.number)
            continue
        if field.repeated:
            values = getattr(message, field.name)
            if wire_type == 2 and _is_packable(field.kind):
                packed = _Reader(reader.length_delimited())
                while not packed.eof:
                    values.append(_decode_scalar(packed, field.kind))
            elif wire_type == _wire_type(field.kind):
                values.append(_decode_value(reader, field.kind, field.type_name))
            else:
                reader.skip(wire_type)
                continue
            message._present.add(field.number)
            continue
        if wire_type != _wire_type(field.kind):
            reader.skip(wire_type)
            continue
        decoded = _decode_value(reader, field.kind, field.type_name)
        current = getattr(message, field.name)
        if field.kind == "message" and current is not None:
            current.MergeFrom(decoded)
            message._present.add(field.number)
        else:
            setattr(message, field.name, decoded)


def _decode_map_entry(field: Field, data: bytes) -> tuple[Any, Any]:
    key = _kind_default(field.map_key_kind)
    value = _map_value_default(field)
    reader = _Reader(data)
    while not reader.eof:
        tag = reader.varint()
        number = tag >> 3
        wire_type = tag & 0x07
        if number == 0:
            raise DecodeError("protobuf field number cannot be zero")
        if number > _MAX_FIELD_NUMBER:
            raise DecodeError(
                f"protobuf field number exceeds maximum {_MAX_FIELD_NUMBER}"
            )
        if number == 1 and wire_type == _wire_type(field.map_key_kind):
            key = _decode_value(reader, field.map_key_kind, "")
        elif number == 2 and wire_type == _wire_type(field.map_value_kind):
            value = _decode_value(
                reader, field.map_value_kind, field.map_value_type_name
            )
        else:
            reader.skip(wire_type)
    return key, value


def _decode_value(reader: _Reader, kind: str, type_name: str) -> Any:
    if kind == "message":
        return _resolve_message(type_name).FromString(reader.length_delimited())
    if kind == "string":
        try:
            return reader.length_delimited().decode("utf-8")
        except UnicodeDecodeError as error:
            raise DecodeError("invalid UTF-8 protobuf string") from error
    if kind == "bytes":
        return reader.length_delimited()
    return _decode_scalar(reader, kind)


def _decode_scalar(reader: _Reader, kind: str) -> Any:
    if kind in {"int32", "enum"}:
        return _signed(reader.varint(), 32)
    if kind == "int64":
        return _signed(reader.varint(), 64)
    if kind == "sint32":
        return _zigzag_decode(reader.varint(), 32)
    if kind == "sint64":
        return _zigzag_decode(reader.varint(), 64)
    if kind == "uint32":
        return reader.varint() & 0xFFFFFFFF
    if kind == "uint64":
        return reader.varint() & 0xFFFFFFFFFFFFFFFF
    if kind == "fixed32":
        return struct.unpack("<I", reader.raw(4))[0]
    if kind == "fixed64":
        return struct.unpack("<Q", reader.raw(8))[0]
    if kind == "sfixed32":
        return struct.unpack("<i", reader.raw(4))[0]
    if kind == "sfixed64":
        return struct.unpack("<q", reader.raw(8))[0]
    if kind == "float":
        return struct.unpack("<f", reader.raw(4))[0]
    if kind == "double":
        return struct.unpack("<d", reader.raw(8))[0]
    if kind == "bool":
        return reader.varint() != 0
    raise DecodeError(f"unsupported protobuf kind {kind!r}")


def _encode_message(message: ProtoMessage, *, deterministic: bool) -> bytes:
    writer = _Writer()
    for field in message.__fields__:
        value = getattr(message, field.name)
        if field.oneof and message._oneof_cases.get(field.oneof) != field.name:
            continue
        if field.is_map:
            keys = sorted(value) if deterministic else value.keys()
            for key in keys:
                entry = _encode_map_entry(field, key, value[key], deterministic)
                writer.tag(field.number, 2)
                writer.length_delimited(entry)
            continue
        if field.repeated:
            if not value:
                continue
            if _is_packable(field.kind):
                packed = _Writer()
                for item in value:
                    _encode_scalar(packed, field.kind, item)
                writer.tag(field.number, 2)
                writer.length_delimited(bytes(packed.data))
            else:
                for item in value:
                    _encode_field(
                        writer,
                        field.number,
                        field.kind,
                        field.type_name,
                        item,
                        deterministic,
                    )
            continue
        if field.kind == "message":
            if value is None:
                continue
        elif field.optional:
            if field.number not in message._present:
                continue
        elif not field.oneof and _is_default_value(field.kind, value):
            continue
        _encode_field(writer, field.number, field.kind, field.type_name, value, deterministic)
    return bytes(writer.data)


def _encode_map_entry(
    field: Field, key: Any, value: Any, deterministic: bool
) -> bytes:
    writer = _Writer()
    if key != _kind_default(field.map_key_kind):
        _encode_field(writer, 1, field.map_key_kind, "", key, deterministic)
    if field.map_value_kind == "message" or not _is_default_value(
        field.map_value_kind, value
    ):
        _encode_field(
            writer,
            2,
            field.map_value_kind,
            field.map_value_type_name,
            value,
            deterministic,
        )
    return bytes(writer.data)


def _encode_field(
    writer: _Writer,
    number: int,
    kind: str,
    type_name: str,
    value: Any,
    deterministic: bool,
) -> None:
    writer.tag(number, _wire_type(kind))
    if kind == "message":
        if isinstance(value, dict):
            value = _resolve_message(type_name)(**value)
        if not isinstance(value, ProtoMessage):
            raise EncodeError(f"message field {number} requires a ProtoMessage")
        writer.length_delimited(value.SerializeToString(deterministic=deterministic))
    elif kind == "string":
        writer.length_delimited(str(value).encode("utf-8"))
    elif kind == "bytes":
        writer.length_delimited(bytes(value))
    else:
        _encode_scalar(writer, kind, value)


def _encode_scalar(writer: _Writer, kind: str, value: Any) -> None:
    if kind in {"int32", "int64", "enum"}:
        writer.varint(int(value))
    elif kind == "sint32":
        number = _signed(int(value), 32)
        writer.varint(((number << 1) ^ (number >> 31)) & 0xFFFFFFFF)
    elif kind == "sint64":
        number = _signed(int(value), 64)
        writer.varint(((number << 1) ^ (number >> 63)) & 0xFFFFFFFFFFFFFFFF)
    elif kind == "uint32":
        writer.varint(int(value) & 0xFFFFFFFF)
    elif kind == "uint64":
        writer.varint(int(value) & 0xFFFFFFFFFFFFFFFF)
    elif kind == "fixed32":
        writer.data.extend(struct.pack("<I", int(value) & 0xFFFFFFFF))
    elif kind == "fixed64":
        writer.data.extend(struct.pack("<Q", int(value) & 0xFFFFFFFFFFFFFFFF))
    elif kind == "sfixed32":
        writer.data.extend(struct.pack("<i", _signed(int(value), 32)))
    elif kind == "sfixed64":
        writer.data.extend(struct.pack("<q", _signed(int(value), 64)))
    elif kind == "float":
        writer.data.extend(struct.pack("<f", float(value)))
    elif kind == "double":
        writer.data.extend(struct.pack("<d", float(value)))
    elif kind == "bool":
        writer.varint(1 if value else 0)
    else:
        raise EncodeError(f"unsupported protobuf kind {kind!r}")


def _wire_type(kind: str) -> int:
    if kind in {
        "int32", "int64", "sint32", "sint64", "uint32", "uint64", "bool", "enum"
    }:
        return 0
    if kind in {"fixed64", "sfixed64", "double"}:
        return 1
    if kind in {"string", "bytes", "message"}:
        return 2
    if kind in {"fixed32", "sfixed32", "float"}:
        return 5
    raise ProtoError(f"unsupported protobuf kind {kind!r}")


def _is_packable(kind: str) -> bool:
    return kind not in {"string", "bytes", "message"}


def _kind_default(kind: str) -> Any:
    if kind == "bool":
        return False
    if kind == "string":
        return ""
    if kind == "bytes":
        return b""
    if kind == "message":
        return None
    return 0


def _is_default_value(kind: str, value: Any) -> bool:
    if kind in {"float", "double"}:
        number = float(value)
        return number == 0.0 and math.copysign(1.0, number) > 0.0
    return value == _kind_default(kind)


def _default_value(field: Field) -> Any:
    if field.is_map:
        return {}
    if field.repeated:
        return []
    return _kind_default(field.kind)


def _map_value_default(field: Field) -> Any:
    if field.map_value_kind == "message":
        return _resolve_message(field.map_value_type_name)()
    return _kind_default(field.map_value_kind)


def _resolve_message(name: str) -> type[ProtoMessage]:
    message_type = _MESSAGE_TYPES.get(name.lstrip(".")) or _MESSAGE_TYPES.get(name)
    if message_type is None:
        raise ProtoError(f"protobuf message type is not registered: {name}")
    return message_type


def _coerce_value(field: Field, value: Any) -> Any:
    if field.repeated:
        if isinstance(value, (str, bytes, bytearray, memoryview)):
            raise TypeError(f"repeated field {field.name!r} requires an iterable")
        return list(value)
    if field.is_map:
        return dict(value)
    if field.kind == "bytes":
        return bytes(value)
    if field.kind == "message" and isinstance(value, dict):
        return _resolve_message(field.type_name)(**value)
    return value


def _signed(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def _zigzag_decode(value: int, bits: int) -> int:
    return _signed((value >> 1) ^ -(value & 1), bits)


def _json_value(field: Field, value: Any) -> Any:
    if field.kind == "bytes":
        return base64.b64encode(value).decode("ascii")
    if field.kind == "message":
        return value.to_dict()
    if field.kind == "enum":
        enum_type = _ENUM_TYPES.get(field.type_name.lstrip("."))
        if enum_type is not None:
            try:
                return enum_type(value).name
            except ValueError:
                pass
    if field.kind in {"int64", "sint64", "uint64", "fixed64", "sfixed64"}:
        return str(value)
    return value


def _json_map_value(field: Field, value: Any) -> Any:
    synthetic = Field(
        number=2,
        name="value",
        kind=field.map_value_kind,
        type_name=field.map_value_type_name,
    )
    return _json_value(synthetic, value)


def _should_show(message: ProtoMessage, field: Field) -> bool:
    value = getattr(message, field.name)
    if field.repeated or field.is_map:
        return bool(value)
    if field.kind == "message":
        return value is not None
    return field.number in message._present or not _is_default_value(field.kind, value)


__all__ = [
    "DecodeError",
    "EncodeError",
    "Field",
    "ProtoError",
    "ProtoMessage",
    "attach_nested",
    "register_enum",
    "register_message",
]
