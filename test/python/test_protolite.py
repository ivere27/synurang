from __future__ import annotations

import math
import unittest

from synurang import DecodeError, Field, ProtoMessage
from synurang.proto import Struct, Timestamp, Value


class Child(ProtoMessage):
    __proto_name__ = "test.v1.Child"
    __fields__ = (Field(1, "value", "int32"),)


class WireCase(ProtoMessage):
    __proto_name__ = "test.v1.WireCase"
    __fields__ = (
        Field(1, "int_value", "int32"),
        Field(2, "sint_value", "sint32"),
        Field(3, "fixed_value", "fixed32"),
        Field(4, "float_value", "float"),
        Field(5, "packed_values", "int32", repeated=True),
        Field(
            6,
            "labels",
            "message",
            is_map=True,
            map_key_kind="string",
            map_value_kind="int32",
        ),
        Field(7, "optional_value", "int32", optional=True),
        Field(8, "choice_text", "string", oneof="choice"),
        Field(9, "choice_number", "int64", oneof="choice"),
        Field(10, "child", "message", type_name="test.v1.Child"),
        Field(11, "double_value", "double"),
    )


class ProtoLiteTests(unittest.TestCase):
    def test_exact_scalar_fixed_float_packed_map_and_nested_wire_bytes(self) -> None:
        message = WireCase(
            int_value=-1,
            sint_value=-1,
            fixed_value=0x78563412,
            float_value=1.5,
            packed_values=[1, 2, 300],
            labels={"a": 1},
            optional_value=0,
            choice_text="x",
            child=Child(value=7),
        )
        expected = (
            b"\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
            b"\x10\x01"
            b"\x1d\x12\x34\x56\x78"
            b"\x25\x00\x00\xc0\x3f"
            b"\x2a\x04\x01\x02\xac\x02"
            b"\x32\x05\x0a\x01a\x10\x01"
            b"\x38\x00"
            b"\x42\x01x"
            b"\x52\x02\x08\x07"
        )

        self.assertEqual(expected, message.to_bytes(deterministic=True))
        self.assertEqual(message, WireCase.from_bytes(expected))

    def test_accepts_unpacked_encoding_for_repeated_numeric_field(self) -> None:
        unpacked = b"\x28\x01\x28\x02\x28\xac\x02"

        parsed = WireCase.from_bytes(unpacked)

        self.assertEqual([1, 2, 300], parsed.packed_values)
        self.assertEqual(b"\x2a\x04\x01\x02\xac\x02", parsed.to_bytes())

    def test_optional_default_tracks_presence(self) -> None:
        absent = WireCase()
        present = WireCase(optional_value=0)

        self.assertFalse(absent.HasField("optional_value"))
        self.assertTrue(present.HasField("optional_value"))
        self.assertEqual(b"", absent.to_bytes())
        self.assertEqual(b"\x38\x00", present.to_bytes())
        self.assertTrue(WireCase.from_bytes(b"\x38\x00").HasField("optional_value"))

    def test_oneof_assignment_clears_previous_member(self) -> None:
        message = WireCase(choice_text="first")
        self.assertEqual("choice_text", message.WhichOneof("choice"))

        message.choice_number = 9

        self.assertEqual("", message.choice_text)
        self.assertEqual("choice_number", message.WhichOneof("choice"))
        self.assertEqual(b"\x48\x09", message.to_bytes())
        message.ClearField("choice")
        self.assertIsNone(message.WhichOneof("choice"))

    def test_unknown_fields_are_skipped(self) -> None:
        payload = Child(value=4).to_bytes() + b"\xf8\x07\x01"

        self.assertEqual(Child(value=4), Child.from_bytes(payload))

    def test_negative_float_zero_is_encoded_but_positive_zero_is_omitted(self) -> None:
        self.assertEqual(b"", WireCase(float_value=0.0, double_value=0.0).to_bytes())

        payload = WireCase(float_value=-0.0, double_value=-0.0).to_bytes()

        self.assertEqual(
            b"\x25\x00\x00\x00\x80"
            b"\x59\x00\x00\x00\x00\x00\x00\x00\x80",
            payload,
        )
        parsed = WireCase.from_bytes(payload)
        self.assertEqual(-1.0, math.copysign(1.0, parsed.float_value))
        self.assertEqual(-1.0, math.copysign(1.0, parsed.double_value))

    def test_non_finite_float_values_roundtrip(self) -> None:
        for field_name in ("float_value", "double_value"):
            for value in (math.nan, math.inf, -math.inf):
                with self.subTest(field=field_name, value=value):
                    parsed = WireCase.from_bytes(
                        WireCase(**{field_name: value}).to_bytes()
                    )
                    decoded = getattr(parsed, field_name)
                    if math.isnan(value):
                        self.assertTrue(math.isnan(decoded))
                    else:
                        self.assertEqual(value, decoded)

    def test_merge_from_recursively_merges_singular_message_fields(self) -> None:
        class Grandchild(ProtoMessage):
            __proto_name__ = "test.v1.Grandchild"
            __fields__ = (
                Field(1, "left", "int32"),
                Field(2, "right", "int32"),
            )

        class Parent(ProtoMessage):
            __proto_name__ = "test.v1.Parent"
            __fields__ = (
                Field(1, "child", "message", type_name="test.v1.Grandchild"),
            )

        message = Parent(child=Grandchild(left=1))

        message.MergeFrom(Parent(child=Grandchild(right=2)))

        self.assertEqual(Grandchild(left=1, right=2), message.child)

    def test_rejects_field_numbers_above_protobuf_maximum(self) -> None:
        with self.assertRaisesRegex(DecodeError, "exceeds maximum"):
            Child.from_bytes(b"\x80\x80\x80\x80\x10\x01")

    def test_well_known_and_recursive_struct_messages(self) -> None:
        timestamp = Timestamp(seconds=12, nanos=34)
        self.assertEqual(b"\x08\x0c\x10\x22", timestamp.to_bytes())
        self.assertEqual(timestamp, Timestamp.from_bytes(timestamp.to_bytes()))

        struct_value = Struct(
            fields={
                "name": Value(string_value="synurang"),
                "enabled": Value(bool_value=True),
            }
        )
        self.assertEqual(struct_value, Struct.from_bytes(struct_value.to_bytes(True)))

    def test_malformed_payload_raises_decode_error(self) -> None:
        with self.assertRaises(DecodeError):
            WireCase.from_bytes(b"\x0a\x05x")


if __name__ == "__main__":
    unittest.main()
