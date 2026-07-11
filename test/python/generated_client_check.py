from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

from synurang import FfiTransport


generated_file = Path(os.environ["SYNURANG_GENERATED_PYTHON"])
output_dir = Path(os.environ["SYNURANG_GENERATED_OUT"])
sys.path.insert(0, str(output_dir))

spec = importlib.util.spec_from_file_location("generated_python_ffi", generated_file)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load {generated_file}")
generated = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generated)

import python_service_lite  # noqa: E402
import types_lite  # noqa: E402
from synurang.proto import Timestamp  # noqa: E402


assert not any(name.startswith("google.protobuf") for name in sys.modules)
assert python_service_lite.Envelope.Nested is python_service_lite.Envelope_Nested
assert python_service_lite.Envelope.Level is python_service_lite.Envelope_Level
assert python_service_lite.KeywordEnum.False_.value == 0
assert python_service_lite.KeywordEnum.True_.value == 1
assert python_service_lite.None_(**{"class": "keyword"}).to_bytes() == b"\x0a\x07keyword"
assert getattr(python_service_lite.None_, "True") is python_service_lite.None_True
assert hasattr(generated.PythonServiceFfi, "from_")
assert hasattr(generated.PythonServiceFfi, "get_url")


class FakeStream:
    def __init__(self, responses: list[bytes]) -> None:
        self.sent: list[bytes] = []
        self._responses = iter([*responses, None])
        self.send_closed = False
        self.closed = False

    def send(self, payload: bytes) -> None:
        self.sent.append(payload)

    def recv(self) -> bytes | None:
        return next(self._responses)

    def close_send(self) -> None:
        self.send_closed = True

    def close(self) -> None:
        self.closed = True

    def __enter__(self) -> "FakeStream":
        return self

    def __exit__(self, *_args) -> None:
        self.close()


class FakeHost:
    def __init__(self) -> None:
        self.streams: list[FakeStream] = []

    def invoke(self, service: str, method: str, payload: bytes) -> bytes:
        assert service == "PythonService"
        if method == "/python.test.v1.PythonService/Unary":
            request = types_lite.Request.from_bytes(payload)
            return types_lite.Response(value=f"reply:{request.value}").to_bytes()
        if method == "/python.test.v1.PythonService/NestedUnary":
            request = python_service_lite.Envelope.Nested.from_bytes(payload)
            return python_service_lite.Envelope.Nested(
                value=f"nested:{request.value}"
            ).to_bytes()
        raise AssertionError(method)

    def open_stream(self, service: str, method: str) -> FakeStream:
        assert service == "PythonService"
        if method.endswith("/ServerStream"):
            responses = [
                types_lite.Response(value="one").to_bytes(),
                types_lite.Response(value="two").to_bytes(),
            ]
        elif method.endswith("/ClientStream"):
            responses = [types_lite.Response(value="client").to_bytes()]
        elif method.endswith("/BidiStream"):
            responses = [types_lite.Response(value="bidi").to_bytes()]
        else:
            raise AssertionError(method)
        stream = FakeStream(responses)
        self.streams.append(stream)
        return stream


host = FakeHost()
client = generated.PythonServiceFfi(host)
assert issubclass(generated.PythonServiceFfi, generated.PythonServiceClient)

unary = client.unary(types_lite.Request(value="request"))
assert unary.value == "reply:request"

nested = client.nested_unary(
    python_service_lite.Envelope.Nested(value="request")
)
assert nested.value == "nested:request"

server = list(client.server_stream(types_lite.Request(value="request")))
assert [response.value for response in server] == ["one", "two"]
assert host.streams[-1].send_closed and host.streams[-1].closed

client_response = client.client_stream(
    [types_lite.Request(value="a"), types_lite.Request(value="b")]
)
assert client_response.value == "client"
assert len(host.streams[-1].sent) == 2
assert host.streams[-1].send_closed and host.streams[-1].closed

with client.bidi_stream() as bidi:
    bidi.send(types_lite.Request(value="a"))
    bidi.close_send()
    assert [response.value for response in bidi] == ["bidi"]


feature_type = python_service_lite.FeatureMessage

# Exact wire checks prove generated metadata selects the correct scalar codecs.
assert feature_type(int32_value=-1).to_bytes() == (
    b"\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
)
assert feature_type(sint32_value=-1).to_bytes() == b"\x10\x01"
assert feature_type(fixed32_value=0x78563412).to_bytes() == b"\x45\x12\x34\x56\x78"
assert feature_type(float_value=1.5).to_bytes() == b"\x5d\x00\x00\xc0\x3f"
assert feature_type(packed_values=[1, 2, 300]).to_bytes() == b"\x8a\x01\x04\x01\x02\xac\x02"
assert feature_type(labels={"a": 1}).to_bytes(True) == b"\x9a\x01\x05\x0a\x01a\x10\x01"
assert feature_type(optional_count=0).to_bytes() == b"\xa8\x01\x00"

unpacked = b"\x88\x01\x01\x88\x01\x02\x88\x01\xac\x02"
assert feature_type.from_bytes(unpacked).packed_values == [1, 2, 300]

feature = feature_type(
    int32_value=-7,
    sint32_value=-8,
    sfixed32_value=-9,
    int64_value=-10,
    sint64_value=-11,
    sfixed64_value=-12,
    uint32_value=13,
    fixed32_value=14,
    uint64_value=15,
    fixed64_value=16,
    float_value=1.5,
    double_value=2.5,
    bool_value=True,
    string_value="text",
    bytes_value=b"bytes",
    state=python_service_lite.State.STATE_READY,
    packed_values=[1, 2, 300],
    names=["a", "b"],
    labels={"one": 1, "two": 2},
    nested_map={
        7: python_service_lite.Envelope.Nested(
            value="map", level=python_service_lite.Envelope.Level.LEVEL_HIGH
        )
    },
    optional_count=0,
    choice_text="selected",
    nested=python_service_lite.Envelope.Nested(value="nested"),
    imported=types_lite.Request(value="imported"),
    timestamp=Timestamp(seconds=123, nanos=456),
)
assert feature.HasField("optional_count")
feature.choice_id = 42
assert feature.choice_text == ""
assert feature.WhichOneof("choice") == "choice_id"

decoded = feature_type.from_bytes(feature.to_bytes(deterministic=True))
assert decoded == feature
assert isinstance(decoded.imported, types_lite.Request)
assert decoded.imported.value == "imported"
assert decoded.nested_map[7].value == "map"
assert isinstance(decoded.timestamp, Timestamp)
assert decoded.HasField("optional_count")
assert decoded.WhichOneof("choice") == "choice_id"

unknown = feature_type(string_value="known").to_bytes() + b"\xf8\x07\x01"
assert feature_type.from_bytes(unknown).string_value == "known"

neutral_host = FakeHost()
neutral_client = generated.PythonServiceClient(FfiTransport(neutral_host))
neutral_reply = neutral_client.unary(types_lite.Request(value="neutral"))
assert neutral_reply.value == "reply:neutral"

print("generated Python client check passed")
