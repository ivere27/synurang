"""Errors carried by the Synurang plugin ABI."""

from __future__ import annotations


class FfiError(RuntimeError):
    """A structured error returned by a Synurang plugin.

    Plugin errors are encoded as ``core.v1.Error`` protobuf payloads.  The
    runtime decodes the three stable fields directly so the low-level host does
    not need generated protobuf code.
    """

    def __init__(
        self,
        message: str,
        code: int = 0,
        grpc_code: int = 2,
        payload: bytes | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.grpc_code = grpc_code
        self.payload = None if payload is None else bytes(payload)

    @classmethod
    def from_payload(cls, payload: bytes | bytearray | memoryview | None) -> "FfiError":
        """Decode a ``core.v1.Error`` payload.

        If the payload is not a valid structured error, its UTF-8 replacement
        decoding is used as the message.  This preserves compatibility with
        older plugins that returned plain text.
        """

        data = b"" if payload is None else bytes(payload)
        if not data:
            return cls("", code=0, grpc_code=0, payload=data)

        index = 0
        code = 0
        grpc_code = 0
        message: str | None = None

        while index < len(data):
            tag, index, ok = _read_varint(data, index)
            if not ok or tag == 0:
                break

            field_number = tag >> 3
            wire_type = tag & 0x07
            if field_number == 1 and wire_type == 0:
                value, index, ok = _read_varint(data, index)
                if not ok:
                    break
                code = _as_int32(value)
            elif field_number == 2 and wire_type == 2:
                length, index, ok = _read_varint(data, index)
                if not ok or length > len(data) - index:
                    break
                end = index + length
                message = data[index:end].decode("utf-8", errors="replace")
                index = end
            elif field_number == 3 and wire_type == 0:
                value, index, ok = _read_varint(data, index)
                if not ok:
                    break
                grpc_code = _as_int32(value)
            else:
                index, ok = _skip_field(data, index, wire_type)
                if not ok:
                    break

        if message is None:
            message = data.decode("utf-8", errors="replace")
        return cls(message, code=code, grpc_code=grpc_code, payload=data)


class PluginClosedError(FfiError):
    """Raised when an operation is attempted on a closed host or stream."""

    def __init__(self, message: str = "plugin is closed") -> None:
        super().__init__(message)


def _read_varint(data: bytes, index: int) -> tuple[int, int, bool]:
    value = 0
    shift = 0
    while index < len(data) and shift < 64:
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, index, True
        shift += 7
    return 0, index, False


def _skip_field(data: bytes, index: int, wire_type: int) -> tuple[int, bool]:
    if wire_type == 0:
        _, index, ok = _read_varint(data, index)
        return index, ok
    if wire_type == 1:
        end = index + 8
        return min(end, len(data)), end <= len(data)
    if wire_type == 2:
        length, index, ok = _read_varint(data, index)
        if not ok or length > len(data) - index:
            return len(data), False
        return index + length, True
    if wire_type == 5:
        end = index + 4
        return min(end, len(data)), end <= len(data)
    return len(data), False


def _as_int32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value

