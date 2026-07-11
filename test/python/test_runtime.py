from __future__ import annotations

import os
import threading
import unittest

from synurang import BidiStream, FfiError, PluginClosedError, PluginHost


PLUGIN_PATH = os.environ.get("SYNURANG_PYTHON_TEST_PLUGIN")


@unittest.skipUnless(PLUGIN_PATH, "SYNURANG_PYTHON_TEST_PLUGIN is not set")
class PluginHostTests(unittest.TestCase):
    def setUp(self) -> None:
        assert PLUGIN_PATH is not None
        self.host = PluginHost.load(PLUGIN_PATH)

    def tearDown(self) -> None:
        self.host.close()

    def test_unary_payload_and_empty_successes(self) -> None:
        self.assertEqual(
            b"hello",
            self.host.invoke(
                "TestService", "/test.v1.TestService/Echo", b"hello"
            ),
        )
        self.assertEqual(
            b"",
            self.host.invoke(
                "TestService", "/test.v1.TestService/NullEmpty", b""
            ),
        )
        self.assertEqual(
            b"",
            self.host.invoke(
                "TestService", "/test.v1.TestService/AllocatedEmpty", b""
            ),
        )

    def test_unary_structured_error(self) -> None:
        with self.assertRaises(FfiError) as caught:
            self.host.invoke(
                "TestService", "/test.v1.TestService/Error", b"request"
            )

        self.assertEqual("boom", caught.exception.message)
        self.assertEqual(123, caught.exception.code)
        self.assertEqual(10, caught.exception.grpc_code)

    def test_stream_send_receive_eof_and_context_manager(self) -> None:
        with self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        ) as stream:
            stream.send(b"stream payload")
            stream.close_send()
            self.assertEqual(b"stream payload", stream.recv())
            self.assertIsNone(stream.recv())

        self.assertTrue(stream.closed)
        with self.assertRaises(PluginClosedError):
            stream.recv()

    def test_empty_stream_payload_is_not_eof(self) -> None:
        with self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        ) as stream:
            stream.send(b"")
            stream.close_send()
            self.assertEqual(b"", stream.recv())
            self.assertIsNone(stream.recv())

    def test_stream_structured_error(self) -> None:
        with self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        ) as stream:
            stream.send(b"error")
            stream.close_send()
            with self.assertRaises(FfiError) as caught:
                stream.recv()

        self.assertEqual(("boom", 123, 10), (
            caught.exception.message,
            caught.exception.code,
            caught.exception.grpc_code,
        ))

    def test_stream_send_error_and_open_error(self) -> None:
        with self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        ) as stream:
            with self.assertRaisesRegex(FfiError, "code -7"):
                stream.send(b"\xff")

        with self.assertRaisesRegex(FfiError, "failed to open stream"):
            self.host.open_stream(
                "TestService", "/test.v1.TestService/OpenFail"
            )

    def test_bidi_stream_serializes_and_deserializes(self) -> None:
        raw_stream = self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        )
        with BidiStream(
            raw_stream,
            lambda value: value.encode("utf-8"),
            lambda value: value.decode("utf-8"),
        ) as stream:
            stream.send("hello")
            stream.close_send()
            self.assertEqual(["hello"], list(stream.responses()))

    def test_close_marks_open_streams_and_host_closed(self) -> None:
        stream = self.host.open_stream(
            "TestService", "/test.v1.TestService/EchoStream"
        )

        self.host.close()

        self.assertTrue(self.host.closed)
        self.assertTrue(stream.closed)
        with self.assertRaises(PluginClosedError):
            self.host.invoke(
                "TestService", "/test.v1.TestService/Echo", b"late"
            )

    def test_concurrent_unary_calls(self) -> None:
        errors: list[BaseException] = []

        def worker(index: int) -> None:
            payload = f"worker-{index}".encode()
            try:
                for _ in range(50):
                    if self.host.invoke(
                        "TestService", "/test.v1.TestService/Echo", payload
                    ) != payload:
                        raise AssertionError("response mismatch")
            except BaseException as error:
                errors.append(error)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual([], errors)

    def test_rejects_bad_method_and_service_names(self) -> None:
        with self.assertRaisesRegex(ValueError, "NUL"):
            self.host.invoke("TestService", "bad\0method", b"")
        with self.assertRaisesRegex(ValueError, "service name"):
            self.host.invoke("../bad", "/test.v1.Bad/Call", b"")

    def test_reports_missing_service_symbol(self) -> None:
        with self.assertRaisesRegex(
            FfiError, "Synurang_Invoke_MissingService"
        ):
            self.host.invoke("MissingService", "/test.v1.Missing/Call", b"")


if __name__ == "__main__":
    unittest.main()
