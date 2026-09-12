"""Range, ownership, and failure checks for the POSIX shared-memory example."""
from contextlib import contextmanager
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path
import os
import sys
import unittest

from synurang import FfiError, ModuleHost
from shared_memory_client import SharedMemoryClient
from shared_memory_lite import BufferRequest

METHOD = "/synurang.example.shm.SharedMemory/Process"
BUILD = Path(sys.argv.pop(1)).resolve()


class SharedMemoryTests(unittest.TestCase):
    @contextmanager
    def region_and_host(self, size=128):
        region = SharedMemory(create=True, size=size)
        try:
            with ModuleHost.load(BUILD / "backend.so", loader=BUILD / "libsynurang_module_host.so") as host:
                yield region, host
        finally:
            region.close()
            region.unlink()

    def descriptor(self, region, **changes):
        values = dict(name="/" + region.name.lstrip("/"), offset=7, length=17,
                      xor_mask=0x5A, request_id=1)
        values.update(changes)
        return BufferRequest(**values)

    def assert_status(self, code, operation):
        with self.assertRaises(FfiError) as caught:
            operation()
        self.assertEqual(caught.exception.grpc_code, code)

    def test_unaligned_mapping_and_ack_release(self):
        page = os.sysconf("SC_PAGE_SIZE")
        offset, length = page * 2 + 13, 29
        with self.region_and_host(offset + length + 11) as (region, host):
            client = SharedMemoryClient(host)
            for i in range(region.size):
                region.buf[i] = i % 256
            before = bytes(region.buf)  # Test oracle only, never sent to C.
            name = region.name.lstrip("/")
            mappings_before = Path("/proc/self/maps").read_text().count(name)
            # Full uint64 IDs survive the protobuf control path.
            for request_id in (1, 2**64 - 1):
                descriptor = self.descriptor(region, offset=offset, length=length, request_id=request_id)
                done = client.process(descriptor, timeout=5)
                self.assertEqual(done.request_id, request_id)
                self.assertEqual(done.bytes_processed, length)
                self.assertEqual(done.checksum, sum(region.buf[offset:offset + length]))
                self.assertEqual(Path("/proc/self/maps").read_text().count(name), mappings_before)
                self.assertLess(len(descriptor.to_bytes()), 128)
                if request_id == 1:
                    self.assertEqual(bytes(region.buf[offset:offset + length]),
                                     bytes(value ^ 0x5A for value in before[offset:offset + length]))
            # XOR twice restores the original payload; both guards also survive.
            self.assertEqual(bytes(region.buf), before)

    def test_invalid_descriptors_leave_memory_untouched(self):
        with self.region_and_host() as (region, host):
            client = SharedMemoryClient(host)
            region.buf[:] = bytes([0xCC]) * region.size
            cases = [
                (3, dict(name="")),
                (3, dict(name="no-leading-slash")),
                (3, dict(name="/bad/name")),
                (3, dict(name="/bad\x00name")),
                (3, dict(name="/" + "x" * 256)),
                (3, dict(length=0)),
                (3, dict(length=64 * 1024 + 1)),
                (3, dict(xor_mask=256)),
                (11, dict(offset=region.size, length=1)),
                (11, dict(offset=region.size - 1, length=2)),
                (11, dict(offset=2**64 - 1)),
                (5, dict(name="/" + region.name.lstrip("/") + "_missing")),
            ]
            for code, changes in cases:
                with self.subTest(changes=changes):
                    self.assert_status(code, lambda: client.process(self.descriptor(region, **changes), timeout=5))
            self.assert_status(3, lambda: host.unary(METHOD, b"\x0a\x05x", timeout=5))
            self.assertEqual(bytes(region.buf), bytes([0xCC]) * region.size)
            # An invalid request has not poisoned the instance.
            self.assertEqual(client.process(self.descriptor(region)).bytes_processed, 17)

    def test_cancel_and_deadline_keep_owner_alive_through_host_close(self):
        with self.region_and_host() as (region, host):
            region.buf[:] = bytes([0xCD]) * region.size
            descriptor = self.descriptor(region)
            self.assert_status(4, lambda: SharedMemoryClient(host).process(descriptor, timeout=0))
            call = host.open(METHOD)
            call.cancel()
            self.assert_status(1, call.recv)
            call.close()
            # Teardown establishes that no provider callback can access the
            # region, even when no successful completion was received.
            host.close()
            self.assertEqual(bytes(region.buf), bytes([0xCD]) * region.size)


if __name__ == "__main__":
    unittest.main()
