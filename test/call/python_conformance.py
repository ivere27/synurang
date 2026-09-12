"""Run with PYTHONPATH=python and SYNURANG_MODULE_HOST_LIBRARY set."""
import asyncio
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
from synurang import AsyncModuleHost, FfiError, ModuleHost


def value(number):
    if not number:
        return b""
    out = bytearray(b"\x08")
    number &= (1 << 64) - 1
    while number > 127:
        out.append((number & 127) | 128)
        number >>= 7
    out.append(number)
    return bytes(out)


def path(method):
    return "/synurang.test.Calls/" + method


def expect_error(code, action):
    try:
        action()
    except FfiError as error:
        assert error.grpc_code == code, (error.grpc_code, str(error), code)
        return error
    raise AssertionError("expected RPC error %d" % code)


def synchronous(module):
    with ModuleHost.load(module) as host, ModuleHost.load(module) as other:
        assert host.unary(path("Unary"), b"") == b""
        assert other.unary(path("Unary"), value(42)) == value(42)
        assert host.client_stream(path("Client"), (value(1) for _ in range(1000))) == value(1000)
        assert list(host.server_stream(path("Server"), value(1000))) == [value(i) for i in range(1000)]
        with host.open(path("Bidi"), request_stream=True, response_stream=True) as call:
            for i in range(40):
                call.send(value(i))
                assert call.recv() == value(i)  # response before half-close
            call.half_close()
            assert call.recv() is None
        error = expect_error(7, lambda: host.unary(path("Fail"), b""))
        assert error.code == 42 and error.payload
        expect_error(7, lambda: host.unary(path("Unary"), value(-1)))
        expect_error(12, lambda: host.unary(path("Missing"), b""))
        expect_error(4, lambda: host.unary(path("Wait"), b"", timeout=.02))
        with host.open(path("Wait")) as call:
            call.send(b"")
            call.half_close()
            call.cancel()
            expect_error(1, call.recv)
        # A waiting receiver never owns the instance lock.
        waiting = host.open(path("Wait"))
        waiting.send(b"")
        waiting.half_close()
        errors = []
        def receive():
            try:
                waiting.recv()
            except FfiError as error:
                errors.append(error.grpc_code)
        thread = threading.Thread(target=receive)
        thread.start()
        assert host.unary(path("Unary"), value(3)) == value(3)
        waiting.cancel()
        thread.join(2)
        assert not thread.is_alive() and errors == [1]
    closed = ModuleHost.load(module)
    pending = closed.open(path("Wait"))
    pending.send(b"")
    closed.close()
    expect_error(1, pending.recv)


async def asynchronous(module):
    async with AsyncModuleHost.load(module) as host:
        results = await asyncio.gather(*(host.unary(path("Unary"), value(i)) for i in range(50)))
        assert results == [value(i) for i in range(50)]
        async def requests():
            for _ in range(1000):
                yield value(1)
        assert await host.client_stream(path("Client"), requests()) == value(1000)
        assert [reply async for reply in host.server_stream(path("Server"), value(1000))] == [value(i) for i in range(1000)]
        async with host.open(path("Bidi"), request_stream=True, response_stream=True) as call:
            await call.send(b"")
            assert await call.recv() == b""
            await call.half_close()
            assert await call.recv() is None
        beats = 0
        async def heartbeat():
            nonlocal beats
            for _ in range(10):
                await asyncio.sleep(.001)
                beats += 1
        waiting = asyncio.create_task(host.unary(path("Wait"), b"", timeout=.03))
        await heartbeat()
        try:
            await waiting
            raise AssertionError("deadline succeeded")
        except FfiError as error:
            assert error.grpc_code == 4 and beats == 10
        waiting = asyncio.create_task(host.unary(path("Wait"), b""))
        await asyncio.sleep(.005)
        waiting.cancel()
        try:
            await waiting
        except asyncio.CancelledError:
            pass
        assert not host._host._calls
        for method, request in (("Fail", b""), ("Unary", value(-1))):
            try:
                await host.unary(path(method), request)
                raise AssertionError("expected provider error")
            except FfiError as error:
                assert error.grpc_code == 7
                if method == "Fail":
                    assert error.code == 42
        assert not host._host._calls
    host = AsyncModuleHost.load(module)
    waiting = asyncio.create_task(host.unary(path("Wait"), b""))
    await asyncio.sleep(.005)
    await host.close()
    try:
        await waiting
        raise AssertionError("closed host returned success")
    except FfiError as error:
        assert error.grpc_code == 1


def cleanup_done(marker, count):
    data = marker.read_bytes() if marker.exists() else b""
    return data.count(b"C") == count and data.count(b"D") == count


def released_calls(module):
    with tempfile.TemporaryDirectory() as directory, ModuleHost.load(module) as host:
        marker = Path(directory) / "cleanup"
        calls = []
        for _ in range(96):
            call = host.open("/test.Release/Watch", response_stream=True)
            calls.append(call)
            call.send(os.fsencode(marker))
            assert call.recv() == b""
        for call in calls:
            call.close()
        deadline = time.monotonic() + 2
        while not cleanup_done(marker, len(calls)):
            assert time.monotonic() < deadline, "release cleanup stopped before host close"
            time.sleep(.001)


async def async_released_calls(module):
    with tempfile.TemporaryDirectory() as directory:
        async with AsyncModuleHost.load(module) as host:
            marker = Path(directory) / "cleanup"
            calls = []
            for _ in range(96):
                call = host.open("/test.Release/Watch", response_stream=True)
                calls.append(call)
                await call.send(os.fsencode(marker))
                assert await call.recv() == b""
            for call in calls:
                call.close()
            deadline = time.monotonic() + 2
            while not cleanup_done(marker, len(calls)):
                assert time.monotonic() < deadline, "async release cleanup stopped before host close"
                await asyncio.sleep(.001)


if release_module := os.environ.get("SYNURANG_TEST_RELEASE_MODULE"):
    released_calls(release_module)
    asyncio.run(async_released_calls(release_module))
    print("Python release drains without another call or host close")

for module in sys.argv[1:]:
    synchronous(module)
    asyncio.run(asynchronous(module))
    print("Python sync/async module conformance:", module)
