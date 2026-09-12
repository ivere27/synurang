# Shared memory through the existing call ABI

Python and C++ callers create POSIX shared memory, send its descriptor to a C
module, and receive a completion message after the module updates those same
pages. The example uses ABI version 1 and the existing hosts and generator.

For continuous images, see the [two-queue example](QUEUE.md): moving-target
detection and defect inspection with FIFO, Latest and Batch policies, both
callers, and an offline visual report. Run it with `make test_shared_memory_queue`.

```text
Python SharedMemory / C++ shm_open + mmap
    -> Protobuf { name, offset, length, xor_mask, request_id }
    -> C shm_open + mmap(MAP_SHARED), modify payload in place, munmap
    -> Protobuf BufferDone { request_id, bytes_processed, checksum }
    -> caller verifies the shared bytes, reuses the buffer, then closes/unlinks
```

The C module is loaded into the caller's process with FFI. POSIX shared memory
provides an explicit named buffer with matching Python/C APIs; a separate
backend process is not launched. Each mapping may have a different virtual
address while referring to the same shared pages.

## Run

On Linux, install a C/C++17 compiler, Rust/Cargo, `protoc`, and Python 3.10+.
Python uses the standard library and this repository's runtime. No additional
Python packages, Go, Flutter, or WASI SDK are required.

From the repository root:

```sh
bash example/shared_memory/run.sh
# Equivalent: make test_shared_memory
```

This generates the small Protobuf codecs/clients into `build/shared_memory`,
builds the C module and loader, runs both callers, and checks error/cleanup
cases. Each caller sends two requests against one 64 KiB payload. Only the small
descriptor and completion are encoded, copied, or sent over the call ABI.

To build and run the callers separately:

```sh
bash example/shared_memory/build.sh
PYTHONPATH="$PWD/python:$PWD/build/shared_memory" \
  python3 example/shared_memory/caller.py build/shared_memory
./build/shared_memory/cpp_caller ./build/shared_memory/backend.so
```

Both callers verify every modified byte, the checksum, matching request IDs,
and untouched bytes before/after the requested range. The edge checks cover
unaligned offsets beyond the first page, invalid names/ranges, uint64 IDs,
malformed Protobuf, cancellation, and deadlines. On success they also check
that the backend's extra mapping is gone before the caller reuses the region.

## Ownership and completion

- The caller owns the shared-memory name and allocation. It keeps the region
  alive and does not resize or modify it while a request is in flight.
- The backend maps only the requested range, including page-alignment padding.
  It XORs the payload with `xor_mask` and computes a checksum directly from the
  shared pages. No payload-sized staging buffer is created. The callers also
  produce the initial bytes directly into their mappings.
- The backend stops accessing the buffer and unmaps it **before** publishing
  `BufferDone`. The unary helper checks the final RPC status as well. That
  successful completion permits the caller to reuse the buffer.
- On error or timeout, both examples close the host before closing/unlinking
  the region. Host teardown waits for provider cleanup. A local timeout alone
  is not permission to overwrite a buffer that a provider might still use.
- The caller alone unlinks the name. Closing a mapping and unlinking the name
  are separate operations; see [Python's shared-memory documentation](https://docs.python.org/3/library/multiprocessing.shared_memory.html).

The example has one in-flight request and bounds work to 64 KiB to keep the C
callback short. For longer media work, retain the stream while a worker uses
the mapping and publish completion only after that work has stopped. For a
continuous stream, use a bounded buffer pool and bidi descriptors/completions,
with unique IDs per use and an explicit buffer-release path on cancellation,
as implemented in the [queue backend](queue_backend.c).

The zero-copy property here is **payload transfer between these CPU mappings**.
Small Protobuf metadata still uses the normal codecs. This example does not
measure latency or cover WASM/Worker memory, GPU transfers, or pixel conversion.
