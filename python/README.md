# Synurang for Python

Python 3.10+ transport-neutral client runtime. Its in-process FFI transport is
implemented with the Python standard library and has no third-party
dependencies; remote gRPC support is an optional `grpcio` extra.

`protoc-gen-synurang-ffi` generates dependency-free protobuf-lite message
classes together with typed service clients. The generated messages support
binary parse/serialization, packed repeated fields, maps, optional fields,
oneofs, nested types, imports, and common well-known protobuf types. Neither
`google.protobuf` nor `protoc --python_out` is required.

Generated lite messages currently target proto3 schemas.

The generated `*Client` class accepts a neutral `RpcTransport`:

```python
from synurang import FfiTransport, GrpcTransport, PluginHost
from your_service_ffi import GreeterClient
from your_service_lite import HelloRequest

request = HelloRequest(name="World")

# In-process shared library; no optional dependencies.
with PluginHost.load("./libgreeter.so") as host:
    local = GreeterClient(FfiTransport(host))
    reply = local.say_hello(request)

# Remote server; install with: python -m pip install './python[grpc]'
with GrpcTransport.insecure_channel("127.0.0.1:50051") as transport:
    remote = GreeterClient(transport)
    reply = remote.say_hello(request)
```

Both clients expose the same unary and streaming methods. `*Ffi(host)` remains
as a compatibility shortcut for `*Client(FfiTransport(host))`. Remote failures
are raised as `grpc.RpcError`; FFI failures are raised as `FfiError`.
