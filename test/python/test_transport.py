from __future__ import annotations

import os
import unittest
from collections.abc import Iterable, Iterator
from typing import Any, get_type_hints

from synurang import (
    BidiStream,
    FfiTransport,
    GrpcTransport,
    PluginHost,
    RpcStream,
    RpcTransport,
)


PLUGIN_PATH = os.environ.get("SYNURANG_PYTHON_TEST_PLUGIN")


@unittest.skipUnless(PLUGIN_PATH, "SYNURANG_PYTHON_TEST_PLUGIN is not set")
class FfiTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        assert PLUGIN_PATH is not None
        self.host = PluginHost.load(PLUGIN_PATH)
        self.transport = FfiTransport(self.host)

    def tearDown(self) -> None:
        self.transport.close()
        self.host.close()

    def test_all_rpc_cardinalities_and_runtime_protocols(self) -> None:
        self.assertIsInstance(self.transport, RpcTransport)
        self.assertEqual(
            b"unary",
            self.transport.unary_unary(
                "TestService", "/test.v1.TestService/Echo", b"unary"
            ),
        )
        self.assertEqual(
            [b"server"],
            list(
                self.transport.unary_stream(
                    "TestService",
                    "/test.v1.TestService/EchoStream",
                    b"server",
                )
            ),
        )
        self.assertEqual(
            b"client",
            self.transport.stream_unary(
                "TestService",
                "/test.v1.TestService/EchoStream",
                [b"client"],
            ),
        )
        with self.transport.stream_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        ) as stream:
            self.assertIsInstance(stream, RpcStream)
            stream.send(b"bidi")
            stream.close_send()
            self.assertEqual(b"bidi", stream.recv())
            self.assertIsNone(stream.recv())

    def test_borrowed_host_and_unsupported_call_options(self) -> None:
        with self.assertRaisesRegex(ValueError, "timeouts"):
            self.transport.unary_unary(
                "TestService",
                "/test.v1.TestService/Echo",
                b"x",
                timeout=1,
            )
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.transport.unary_unary(
                "TestService",
                "/test.v1.TestService/Echo",
                b"x",
                metadata=(("x-test", "value"),),
            )

        self.transport.close()
        self.assertFalse(self.host.closed)
        self.assertEqual(
            b"still-open",
            self.host.invoke(
                "TestService", "/test.v1.TestService/Echo", b"still-open"
            ),
        )

        assert PLUGIN_PATH is not None
        owned_host = PluginHost.load(PLUGIN_PATH)
        owned = FfiTransport(owned_host, close_host=True)
        owned.close()
        owned.close()
        self.assertTrue(owned_host.closed)


class _ResponseIterator:
    def __init__(self, values: Iterable[bytes]) -> None:
        self._values = iter(values)
        self.cancelled = False

    def __iter__(self) -> "_ResponseIterator":
        return self

    def __next__(self) -> bytes:
        return next(self._values)

    def cancel(self) -> None:
        self.cancelled = True


class _BidiCall:
    def __init__(self, requests: Iterator[bytes]) -> None:
        self._requests = requests
        self._callbacks: list[Any] = []
        self.cancelled = False

    def __iter__(self) -> "_BidiCall":
        return self

    def __next__(self) -> bytes:
        try:
            return b"bidi:" + next(self._requests)
        except StopIteration:
            self._finish()
            raise

    def add_done_callback(self, callback: Any) -> None:
        self._callbacks.append(callback)

    def cancel(self) -> None:
        self.cancelled = True
        self._finish()

    def _finish(self) -> None:
        callbacks, self._callbacks = self._callbacks, []
        for callback in callbacks:
            callback(self)


class _FakeChannel:
    def __init__(self) -> None:
        self.closed = False
        self.options: list[dict[str, Any]] = []
        self.last_responses: _ResponseIterator | None = None
        self.last_bidi: _BidiCall | None = None

    def unary_unary(self, method: str, **_kwargs: Any):
        self._check_method(method)

        def call(request: bytes, **options: Any) -> bytes:
            self.options.append(options)
            return b"unary:" + request

        return call

    def unary_stream(self, method: str, **_kwargs: Any):
        self._check_method(method)

        def call(request: bytes, **options: Any) -> _ResponseIterator:
            self.options.append(options)
            self.last_responses = _ResponseIterator(
                [b"server:1:" + request, b"server:2:" + request]
            )
            return self.last_responses

        return call

    def stream_unary(self, method: str, **_kwargs: Any):
        self._check_method(method)

        def call(requests: Iterable[bytes], **options: Any) -> bytes:
            self.options.append(options)
            return b"client:" + b",".join(requests)

        return call

    def stream_stream(self, method: str, **_kwargs: Any):
        self._check_method(method)

        def call(requests: Iterator[bytes], **options: Any) -> _BidiCall:
            self.options.append(options)
            self.last_bidi = _BidiCall(requests)
            return self.last_bidi

        return call

    def close(self) -> None:
        self.closed = True

    @staticmethod
    def _check_method(method: str) -> None:
        if method != "/test.v1.TestService/Call":
            raise AssertionError(method)


class GrpcTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.channel = _FakeChannel()
        self.transport = GrpcTransport(
            self.channel,
            default_timeout=5,
            default_metadata=(("x-default", "yes"),),
        )

    def tearDown(self) -> None:
        self.transport.close()

    def test_all_rpc_cardinalities_and_options(self) -> None:
        method = "/test.v1.TestService/Call"
        self.assertIsInstance(self.transport, RpcTransport)
        self.assertEqual(
            b"unary:req",
            self.transport.unary_unary(
                "TestService",
                method,
                b"req",
                metadata=(("x-call", "yes"),),
            ),
        )
        self.assertEqual(
            [b"server:1:req", b"server:2:req"],
            list(self.transport.unary_stream("TestService", method, b"req")),
        )
        assert self.channel.last_responses is not None
        self.assertTrue(self.channel.last_responses.cancelled)
        self.assertEqual(
            b"client:a,b",
            self.transport.stream_unary(
                "TestService", method, [b"a", b"b"]
            ),
        )

        with self.transport.stream_stream("TestService", method) as stream:
            stream.send(b"a")
            self.assertEqual(b"bidi:a", stream.recv())
            stream.close_send()
            with self.assertRaisesRegex(RuntimeError, "send side"):
                stream.send(b"late")
            self.assertIsNone(stream.recv())
            self.assertIsNone(stream.recv())

        options = self.channel.options[0]
        self.assertEqual(5, options["timeout"])
        self.assertEqual(
            (("x-default", "yes"), ("x-call", "yes")),
            options["metadata"],
        )

    def test_owned_and_borrowed_channel_lifetimes(self) -> None:
        self.transport.close()
        self.assertFalse(self.channel.closed)

        owned_channel = _FakeChannel()
        owned = GrpcTransport(owned_channel, close_channel=True)
        owned.close()
        owned.close()
        self.assertTrue(owned_channel.closed)

    def test_transport_close_cancels_open_bidi_stream(self) -> None:
        stream = self.transport.stream_stream(
            "TestService", "/test.v1.TestService/Call"
        )
        assert self.channel.last_bidi is not None

        self.transport.close()

        self.assertTrue(stream.closed)
        self.assertTrue(self.channel.last_bidi.cancelled)
        with self.assertRaisesRegex(RuntimeError, "closed"):
            stream.recv()

    def test_transport_close_cancels_open_server_stream(self) -> None:
        responses = self.transport.unary_stream(
            "TestService", "/test.v1.TestService/Call", b"request"
        )
        self.assertEqual(b"server:1:request", next(responses))
        assert self.channel.last_responses is not None

        self.transport.close()

        self.assertTrue(self.channel.last_responses.cancelled)
        with self.assertRaises(StopIteration):
            next(responses)

    def test_typed_stream_runtime_annotation_is_resolvable(self) -> None:
        self.assertIs(RpcStream, get_type_hints(BidiStream.__init__)["stream"])

        typed = BidiStream(
            self.transport.stream_stream(
                "TestService", "/test.v1.TestService/Call"
            ),
            bytes,
            bytes,
        )
        typed.close()
        with self.assertRaisesRegex(RuntimeError, "closed"):
            typed.__enter__()


if __name__ == "__main__":
    unittest.main()
