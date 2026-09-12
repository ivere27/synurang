# Synurang for Python

Python 3.10+ hosts load C, C++, Rust, and Go native modules through the same
instance-scoped call ABI. The Python runtime uses only the standard library.
`ModuleHost` supplies blocking calls; `AsyncModuleHost` supplies asyncio calls
and asynchronous response iteration. Both support all four RPC shapes.

`protoc-gen-synurang-ffi` generates dependency-free protobuf-lite message
classes together with typed service clients. The generated messages support
binary parse/serialization, packed repeated fields, maps, optional fields,
oneofs, nested types, imports, and common well-known protobuf types. Neither
`google.protobuf` nor `protoc --python_out` is required.

Generated lite messages currently target proto3 schemas.

Generate messages and both kinds of typed clients:

```sh
protoc -I. --synurang-ffi_out=lang=python,mode=client:generated service.proto
```

This emits `service_lite.py` and `service_client.py`. Build the optional loader
from the repository root on Linux:

```sh
cc -std=c11 -shared -fPIC -Iinclude src/module_host.c -ldl -o libsynurang_module_host.so
export SYNURANG_MODULE_HOST_LIBRARY="$PWD/libsynurang_module_host.so"
```

The loader handles the module function table and frees buffers through their
allocating module. It does not contain a provider's executor or link the C
service runtime. Rust and Go providers retain their own runtime implementations.
Alternatively pass `loader="/path/to/loader"` to `ModuleHost.load`.

```python
from synurang import ModuleHost
from service_client import GreeterClient
from service_lite import HelloRequest

with ModuleHost.load("./libgreeter.so") as host:
    client = GreeterClient(host)
    reply = client.say_hello(HelloRequest(name="World"), timeout=2)
```

For asyncio, use the generated `GreeterAsyncClient`:

```python
from synurang import AsyncModuleHost
from service_client import GreeterAsyncClient

async def greet():
    async with AsyncModuleHost.load("./libgreeter.so") as host:
        client = GreeterAsyncClient(host)
        return await client.say_hello(HelloRequest(name="World"), timeout=2)
```

Server-streaming methods return iterators or async iterators. Client-streaming
methods accept iterables; async clients also accept async iterables. Bidi methods
return a typed call with `send`, `recv`, `half_close`, `cancel`, and `close`:

```python
async with client.chat(timeout=30) as call:
    await call.send(first_request)
    first_reply = await call.recv()
    await call.send(second_request)
    await call.half_close()
    async for reply in call:
        consume(reply)
```

Raw calls use `host.open("/example.Greeter/Chat", request_stream=True,
response_stream=True)`, without a separate service name. Empty bytes are valid
protobuf messages; `None` means successful EOF. Unary methods wait for successful
terminal status before returning a response. Failures raise `FfiError` with
`grpc_code`, application `code`, and the original structured `payload`.

Timeouts are seconds measured by a monotonic clock. Cancelling an asyncio task
waiting on a call cancels and releases that call. Calls serialize only their
nonblocking native entries. Async polling yields to the event loop. Synchronous
deadlines share one timer thread per instance; asyncio uses event-loop timers.
Explicitly close calls and hosts, including when breaking response iteration.
Host close cancels pending calls and drains producer cleanup before unloading.
Each loaded host owns a separate instance. New hosts require the module
accessor and do not fall back to older per-service ABI symbols.

A provider may complete client streaming before the request iterator ends.
Async client-stream helpers receive concurrently and cancel/close the request
iterator when the response finishes, including when its next item is pending.
On raw calls, `send` raises `RequestClosedError` when only the request side has
closed; queued responses and the final status remain readable. Stop sending
and call `recv` or `result` to observe them.

Run native conformance after building the modules:

```sh
bash test/call/test_python.sh /tmp/call-tests /path/to/c_module.so /path/to/rust_module.so
```
