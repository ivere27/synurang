import asyncio
import sys
from synurang import AsyncModuleHost, ModuleHost
from conformance_client import CallsAsyncClient, CallsClient
from conformance_lite import Value


def sync(module):
    with ModuleHost.load(module) as host:
        client = CallsClient(host)
        assert client.unary(Value(value=42)).value == 42
        assert [response.value for response in client.server(Value(value=50))] == list(range(50))
        assert client.client([Value(value=3), Value(value=4)]).value == 7
        with client.bidi() as call:
            call.send(Value())
            assert call.recv().value == 0
            call.half_close()
            assert call.recv() is None


async def asynchronous(module):
    async with AsyncModuleHost.load(module) as host:
        client = CallsAsyncClient(host)
        assert (await client.unary(Value(value=42))).value == 42
        assert [response.value async for response in client.server(Value(value=50))] == list(range(50))
        assert (await client.client([Value(value=3), Value(value=4)])).value == 7
        async with client.bidi() as call:
            await call.send(Value())
            assert (await call.recv()).value == 0
            await call.half_close()
            assert await call.recv() is None


for module in sys.argv[1:]:
    sync(module)
    asyncio.run(asynchronous(module))
    print("Python generated sync/async client conformance:", module)
