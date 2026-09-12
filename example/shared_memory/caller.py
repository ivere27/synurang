"""Python -> existing call ABI -> C -> the same POSIX shared-memory pages."""
from __future__ import annotations

import argparse
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path

from synurang import ModuleHost
from shared_memory_client import SharedMemoryClient
from shared_memory_lite import BufferRequest


def run(build: Path) -> None:
    length, offset, guard = 64 * 1024, 37, 0xCD
    region = SharedMemory(create=True, size=offset + length + 19)
    name = "/" + region.name.lstrip("/")
    try:
        # The host is closed BEFORE region cleanup, including on timeout/error.
        # A local timeout alone never grants permission to reuse shared memory.
        with ModuleHost.load(build / "backend.so", loader=build / "libsynurang_module_host.so") as host:
            client = SharedMemoryClient(host)
            for request_id, mask in enumerate((0x5A, 0xA5), start=1):
                # Produce directly into shared memory. No full payload copy.
                for i in range(region.size):
                    region.buf[i] = guard
                for i in range(length):
                    region.buf[offset + i] = i % 256
                descriptor = BufferRequest(name=name, offset=offset, length=length,
                                           xor_mask=mask, request_id=request_id)
                done = client.process(descriptor, timeout=5)
                # The helper has received both the ACK and successful terminal.
                assert done.request_id == request_id
                assert done.bytes_processed == length
                assert all(region.buf[offset + i] == ((i % 256) ^ mask) for i in range(length))
                assert done.checksum == sum(region.buf[offset + i] for i in range(length))
                assert all(region.buf[i] == guard for i in range(offset))
                assert all(region.buf[i] == guard for i in range(offset + length, region.size))
                print(f"Python: ACK {request_id}, payload={length} B, "
                      f"protobuf request={len(descriptor.to_bytes())} B, "
                      f"checksum={done.checksum}; in-place update verified")
                # Only now may the next request overwrite/reuse this region.
    finally:
        region.close()
        region.unlink()
    print("Python: host closed, shared memory closed and unlinked")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="Output directory from build.sh")
    run(parser.parse_args().build.resolve())
