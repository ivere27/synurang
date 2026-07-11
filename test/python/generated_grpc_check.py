from __future__ import annotations

import os
import sys
import threading
from concurrent import futures
from pathlib import Path

import grpc


output_dir = Path(os.environ["SYNURANG_GENERATED_OUT"])
sys.path.insert(0, str(output_dir))

import python_service_ffi  # noqa: E402
import types_lite  # noqa: E402
from synurang import GrpcTransport  # noqa: E402


def request_value(payload: bytes) -> str:
    return types_lite.Request.from_bytes(payload).value


def response(value: str) -> bytes:
    return types_lite.Response(value=value).to_bytes()


def unary(payload: bytes, context: grpc.ServicerContext) -> bytes:
    metadata = dict(context.invocation_metadata())
    assert metadata["x-synurang-test"] == "remote"
    assert metadata["x-call"] == "unary"
    value = request_value(payload)
    if value == "error":
        context.abort(grpc.StatusCode.INVALID_ARGUMENT, "remote error")
    return response(f"remote:{value}")


def server_stream(
    payload: bytes, _context: grpc.ServicerContext
):
    value = request_value(payload)
    yield response(f"stream:{value}:1")
    yield response(f"stream:{value}:2")


def client_stream(
    requests, _context: grpc.ServicerContext
) -> bytes:
    values = [request_value(payload) for payload in requests]
    return response("client:" + ",".join(values))


def bidi_stream(requests, _context: grpc.ServicerContext):
    for payload in requests:
        yield response(f"bidi:{request_value(payload)}")


def bidi_early(_requests, _context: grpc.ServicerContext):
    yield response("early")


handlers = {
    "Unary": grpc.unary_unary_rpc_method_handler(unary),
    "ServerStream": grpc.unary_stream_rpc_method_handler(server_stream),
    "ClientStream": grpc.stream_unary_rpc_method_handler(client_stream),
    "BidiStream": grpc.stream_stream_rpc_method_handler(bidi_stream),
    "BidiEarly": grpc.stream_stream_rpc_method_handler(bidi_early),
}

server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
server.add_generic_rpc_handlers(
    (grpc.method_handlers_generic_handler("python.test.v1.PythonService", handlers),)
)
port = server.add_insecure_port("127.0.0.1:0")
assert port > 0
server.start()

try:
    with GrpcTransport.insecure_channel(
        f"127.0.0.1:{port}",
        default_timeout=5.0,
        default_metadata=(("x-synurang-test", "remote"),),
    ) as transport:
        client = python_service_ffi.PythonServiceClient(transport)

        unary_reply = client.unary(
            types_lite.Request(value="request"),
            metadata=(("x-call", "unary"),),
        )
        assert unary_reply.value == "remote:request"

        try:
            client.unary(
                types_lite.Request(value="error"),
                metadata=(("x-call", "unary"),),
            )
        except grpc.RpcError as error:
            assert error.code() == grpc.StatusCode.INVALID_ARGUMENT
            assert error.details() == "remote error"
        else:
            raise AssertionError("remote gRPC error was not propagated")

        streamed = list(
            client.server_stream(types_lite.Request(value="request"))
        )
        assert [item.value for item in streamed] == [
            "stream:request:1",
            "stream:request:2",
        ]

        partial_stream = client.server_stream(
            types_lite.Request(value="partial")
        )
        assert next(partial_stream).value == "stream:partial:1"
        partial_stream.close()

        uploaded = client.client_stream(
            [
                types_lite.Request(value="a"),
                types_lite.Request(value="b"),
            ]
        )
        assert uploaded.value == "client:a,b"

        with client.bidi_stream() as bidi:
            bidi.send(types_lite.Request(value="first"))
            first = bidi.recv()
            assert first is not None and first.value == "bidi:first"
            bidi.send(types_lite.Request(value="second"))
            bidi.close_send()
            assert [item.value for item in bidi] == ["bidi:second"]
            assert bidi.recv() is None

        with client.bidi_stream() as bidi:
            concurrent_responses: list[str] = []

            def receive_responses() -> None:
                concurrent_responses.extend(item.value for item in bidi)

            reader = threading.Thread(target=receive_responses)
            reader.start()
            bidi.send(types_lite.Request(value="thread-a"))
            bidi.send(types_lite.Request(value="thread-b"))
            bidi.close_send()
            reader.join(timeout=5)
            assert not reader.is_alive()
            assert concurrent_responses == ["bidi:thread-a", "bidi:thread-b"]

        # The server terminates without consuming or waiting for close_send().
        # The transport must unblock grpcio's request-iterator worker.
        with client.bidi_early() as bidi:
            early = bidi.recv()
            assert early is not None and early.value == "early"
            assert bidi.recv() is None

    assert transport.closed
finally:
    server.stop(0).wait()

print("generated Python remote gRPC check passed")
