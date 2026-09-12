import asyncio
import sys
import time
from synurang import AsyncModuleHost, FfiError, ModuleHost, RequestClosedError
from conformance_client import CallsAsyncClient
from conformance_lite import Value

MODULE = sys.argv[1]
FIRST, SECOND = b"\x08\x2a", b"\x08\x2b"

with ModuleHost.load(MODULE) as host:
    with host.open("/early.Service/Client", request_stream=True) as call:
        call.send(FIRST)
        time.sleep(.03)
        try:
            call.send(SECOND)
            raise AssertionError("Expected request-side EOF")
        except RequestClosedError:
            pass
        call.half_close()
        assert call.result() == FIRST
    def requests():
        yield FIRST
        time.sleep(.03)
        yield SECOND
    assert host.client_stream("/early.Service/Client", requests()) == FIRST


async def main():
    async with AsyncModuleHost.load(MODULE) as host:
        async with host.open("/early.Service/Client", request_stream=True) as call:
            await call.send(FIRST)
            await asyncio.sleep(.03)
            try:
                await call.send(SECOND)
                raise AssertionError("Expected request-side EOF")
            except RequestClosedError:
                pass
            assert await call.result() == FIRST

        for method in ("Client", "Fail"):
            disposed = asyncio.Event()
            async def requests():
                try:
                    yield FIRST
                    await asyncio.Future()  # Input never ends; response must win.
                finally:
                    disposed.set()
            try:
                result = await asyncio.wait_for(host.client_stream("/early.Service/" + method, requests()), 1)
                assert method == "Client" and result == FIRST
            except FfiError as error:
                assert method == "Fail" and error.grpc_code == 7 and error.code == 42
            assert disposed.is_set(), "Request iterator was not cancelled/closed"
        assert not host._host._calls

        disposed = asyncio.Event()
        async def typed_requests():
            try:
                yield Value(value=42)
                await asyncio.Future()
            finally:
                disposed.set()
        response = await asyncio.wait_for(CallsAsyncClient(host).client(typed_requests()), 1)
        assert response.value == 42 and disposed.is_set()

asyncio.run(main())
print("Python early response, request EOF and asynchronous producer cancellation passed")
