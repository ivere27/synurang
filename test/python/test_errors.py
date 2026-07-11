from __future__ import annotations

import unittest

from synurang import FfiError, PluginClosedError


class FfiErrorTests(unittest.TestCase):
    def test_decodes_structured_payload(self) -> None:
        payload = b"\x08\x7b\x12\x04boom\x18\x0a"

        error = FfiError.from_payload(payload)

        self.assertEqual("boom", str(error))
        self.assertEqual("boom", error.message)
        self.assertEqual(123, error.code)
        self.assertEqual(10, error.grpc_code)
        self.assertEqual(payload, error.payload)

    def test_decodes_negative_int32_values(self) -> None:
        minus_one = b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
        payload = b"\x08" + minus_one + b"\x12\x01x\x18" + minus_one

        error = FfiError.from_payload(payload)

        self.assertEqual(-1, error.code)
        self.assertEqual(-1, error.grpc_code)

    def test_falls_back_to_plain_text(self) -> None:
        error = FfiError.from_payload(b"legacy plugin error")

        self.assertEqual("legacy plugin error", error.message)
        self.assertEqual(0, error.code)
        self.assertEqual(0, error.grpc_code)

    def test_skips_unknown_fixed_and_length_delimited_fields(self) -> None:
        payload = (
            b"\x29abcdefgh"
            b"\x32\x03xyz"
            b"\x3d1234"
            b"\x12\x02ok"
        )

        error = FfiError.from_payload(payload)

        self.assertEqual("ok", error.message)

    def test_empty_payload_is_preserved(self) -> None:
        error = FfiError.from_payload(None)

        self.assertEqual("", error.message)
        self.assertEqual(b"", error.payload)
        self.assertEqual(0, error.grpc_code)

    def test_closed_error_is_an_ffi_error(self) -> None:
        error = PluginClosedError()

        self.assertIsInstance(error, FfiError)
        self.assertEqual("plugin is closed", str(error))


if __name__ == "__main__":
    unittest.main()

