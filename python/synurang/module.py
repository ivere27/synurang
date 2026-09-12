"""Instance-scoped native module calls, with synchronous and asyncio APIs.

The optional ``synurang_module_host`` loader is built from ``src/module_host.c``.
Every native entry is nonblocking and serialized per instance. One driver
thread per host waits for notifications and runs bounded polls.
"""
from __future__ import annotations

import asyncio
import ctypes as C
import ctypes.util
import math
import os
import threading
import time
from collections.abc import AsyncIterator, Iterable, Iterator
from typing import Callable, Generic, TypeVar

from .errors import FfiError, PluginClosedError


class RequestClosedError(EOFError):
    """The provider stopped accepting requests; responses remain readable."""


class _Options(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("request_stream", C.c_uint32),
                ("response_stream", C.c_uint32), ("reserved", C.c_uint32),
                ("timeout_ms", C.c_uint64)]


class _Read(C.Structure):
    _fields_ = [("kind", C.c_uint32), ("code", C.c_int32),
                ("data", C.c_void_p), ("size", C.c_uint32)]


_Wakeup = C.CFUNCTYPE(None, C.c_void_p)


class _Signal:
    def __init__(self):
        self.condition = threading.Condition()
        self.generation = 0
        self.waiters = []

    def version(self):
        with self.condition:
            return self.generation

    def wake(self):
        with self.condition:
            self.generation += 1
            waiting, self.waiters = self.waiters, []
            self.condition.notify_all()
        for loop, future in waiting:
            try:
                loop.call_soon_threadsafe(self._complete, future)
            except RuntimeError:
                if not loop.is_closed():
                    raise

    @staticmethod
    def _complete(future):
        if not future.done():
            future.set_result(None)

    def wait(self, version, timeout=None):
        with self.condition:
            self.condition.wait_for(lambda: self.generation != version, timeout)

    async def wait_async(self, version):
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        with self.condition:
            if self.generation != version:
                return
            self.waiters.append((loop, future))
        await future


def _loader(path: str | os.PathLike[str] | None) -> C.CDLL:
    name = path or os.environ.get("SYNURANG_MODULE_HOST_LIBRARY")
    name = name or ctypes.util.find_library("synurang_module_host")
    if not name:
        raise OSError("Set SYNURANG_MODULE_HOST_LIBRARY or pass loader= to ModuleHost.load")
    lib = C.CDLL(os.fspath(name))
    signatures = {
        "load": ([C.c_char_p, C.c_char_p, C.c_void_p], C.c_void_p),
        "error": ([], C.c_char_p),
        "open": ([C.c_void_p, C.c_char_p, C.POINTER(_Options)], C.c_uint64),
        "send": ([C.c_void_p, C.c_uint64, C.c_void_p, C.c_uint32], C.c_int),
        "half_close": ([C.c_void_p, C.c_uint64], C.c_int),
        "receive": ([C.c_void_p, C.c_uint64, C.POINTER(_Read)], C.c_int),
        "cancel": ([C.c_void_p, C.c_uint64, C.c_int32], C.c_int),
        "release": ([C.c_void_p, C.c_uint64], None),
        "free": ([C.c_void_p, C.c_void_p], None),
        "poll": ([C.c_void_p, C.c_uint32], C.c_uint32),
        "has_work": ([C.c_void_p], C.c_int),
        "set_wakeup": ([C.c_void_p, _Wakeup, C.c_void_p], None),
        "destroy": ([C.c_void_p], C.c_int),
    }
    for symbol, (arguments, result) in signatures.items():
        function = getattr(lib, "synurang_host_" + symbol)
        function.argtypes, function.restype = arguments, result
    return lib


def _rpc_error(code: int, payload: bytes = b"") -> FfiError:
    decoded = FfiError.from_payload(payload)
    return FfiError(decoded.message or "RPC failed", decoded.code, code, payload)


class ModuleHost:
    """One module instance. Explicitly close it after its calls finish.

    A thread may send while another receives. The lock protects only short
    native entries; waiting never holds it. ``timeout`` is seconds, measured
    with a monotonic clock. No deadline is imposed when it is None.
    """

    def __init__(self, library: C.CDLL, handle: int):
        self._lib, self._handle = library, handle
        self._lock = threading.RLock()
        self._calls: set[ModuleCall] = set()
        self._closing = False
        self._notification, self._progress = _Signal(), _Signal()
        self._failure = None
        self._async_loop: asyncio.AbstractEventLoop | None = None
        # This callback takes no host lock: a producer may hold its own lock.
        self._callback = _Wakeup(lambda _: self._notification.wake())
        self._lib.synurang_host_set_wakeup(handle, self._callback, None)
        self._driver = threading.Thread(target=self._drive, name="synurang-module", daemon=True)
        self._driver.start()

    @classmethod
    def load(cls, path: str | os.PathLike[str], *, loader=None,
             symbol: str = "Synurang_GetApi") -> ModuleHost:
        library = _loader(loader)
        handle = library.synurang_host_load(os.fsencode(path), symbol.encode(), None)
        if not handle:
            raise OSError(library.synurang_host_error().decode("utf-8", "replace"))
        return cls(library, handle)

    @property
    def closed(self) -> bool:
        return self._closing

    def open(self, method: str, *, request_stream: bool = False,
             response_stream: bool = False, timeout: float | None = None) -> ModuleCall:
        if timeout is not None and (not math.isfinite(timeout) or timeout < 0):
            raise ValueError("timeout must be a finite nonnegative number")
        if not method.startswith("/") or "\x00" in method:
            raise ValueError("method must be a full /package.Service/Method path")
        milliseconds = (1 << 64) - 1 if timeout is None else min(math.ceil(timeout * 1000), (1 << 64) - 2)
        options = _Options(C.sizeof(_Options), request_stream, response_stream, 0, milliseconds)
        with self._lock:
            if self._closing:
                raise PluginClosedError("module instance is closed")
            handle = self._lib.synurang_host_open(self._handle, method.encode(), C.byref(options))
            if not handle:
                raise FfiError("could not open call", grpc_code=13)
            call = ModuleCall(self, handle, None if timeout is None else time.monotonic() + timeout)
            self._calls.add(call)
            self._notification.wake()
            return call

    def _schedule_cleanup(self):
        self._notification.wake()

    def _drive(self):
        while True:
            version = self._notification.version()
            with self._lock:
                if not self._handle:
                    return
                now = time.monotonic()
                for call in tuple(self._calls):
                    if call._deadline is not None and call._deadline <= now:
                        call._expire()
                try:
                    self._lib.synurang_host_poll(self._handle, 64)
                    ready = bool(self._lib.synurang_host_has_work(self._handle))
                except Exception as error:
                    self._failure, ready = error, False
                deadlines = [call._deadline for call in self._calls if call._deadline is not None]
                delay = max(0, min(deadlines) - time.monotonic()) if deadlines else None
                self._progress.wake()
            if ready:
                time.sleep(0)  # Yield between bounded batches, without an idle timer.
            else:
                self._notification.wait(version, delay)

    def unary(self, method: str, request: bytes, *, timeout=None) -> bytes:
        with self.open(method, timeout=timeout) as call:
            call.send(request)
            call.half_close()
            return call.result()

    def server_stream(self, method: str, request: bytes, *, timeout=None) -> Iterator[bytes]:
        with self.open(method, response_stream=True, timeout=timeout) as call:
            call.send(request)
            call.half_close()
            yield from call

    def client_stream(self, method: str, requests: Iterable[bytes], *, timeout=None) -> bytes:
        with self.open(method, request_stream=True, timeout=timeout) as call:
            for request in requests:
                try:
                    call.send(request)
                except RequestClosedError:
                    break
            call.half_close()
            return call.result()

    def _close_step(self) -> bool:
        with self._lock:
            if not self._handle:
                return True
            if not self._closing:
                self._closing = True
                self._notification.wake()
                for call in tuple(self._calls):
                    call.close()
            status = self._lib.synurang_host_destroy(self._handle)
            if status == 0:
                self._handle = 0
                self._notification.wake()
                self._progress.wake()
                return True
            if status != 3:
                raise FfiError("module destroy failed: %d" % status, grpc_code=13)
            return False

    def close(self) -> None:
        while True:
            version = self._progress.version()
            if self._close_step():
                return
            self._progress.wait(version)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


_PENDING = object()


class ModuleCall:
    """One call. Empty bytes are a message; only None denotes successful EOF."""
    def __init__(self, host: ModuleHost, handle: int, deadline: float | None):
        self._host, self._handle, self._deadline = host, handle, deadline
        self._error: FfiError | None = None
        self._finished = False
        self._timer: asyncio.TimerHandle | None = None
        self._request_closed = False
        self._buffered: bytes | None = None

    def _expire(self):
        with self._host._lock:
            if self._handle and self._deadline is not None:
                self._host._lib.synurang_host_cancel(self._host._handle, self._handle, 4)
                self._deadline = None
                self._host._notification.wake()

    def _prepare(self):
        if self._host._failure is not None:
            raise self._host._failure
        if not self._handle:
            if self._error:
                raise self._error
            raise PluginClosedError("call is closed")
        if self._deadline is not None and time.monotonic() >= self._deadline:
            self._expire()

    def _try_send(self, data: bytes) -> bool:
        with self._host._lock:
            if self._request_closed:
                raise RequestClosedError("provider stopped accepting requests")
            self._prepare()
            status = self._host._lib.synurang_host_send(self._host._handle, self._handle, data, len(data))
            if status == -4:
                return False
            if status:
                # A rejected send may carry a provider error or deadline.
                result = self._try_recv()
                if result is not None and result is not _PENDING:
                    self._buffered = result
                if status == -3:
                    self._request_closed = True
                    raise RequestClosedError("provider stopped accepting requests")
                raise FfiError("send failed: %d" % status, grpc_code=13)
            return True

    def send(self, data: bytes | bytearray | memoryview) -> None:
        payload = bytes(data)
        while True:
            version = self._host._progress.version()
            if self._try_send(payload):
                return
            self._host._progress.wait(version)

    def half_close(self) -> None:
        with self._host._lock:
            if self._request_closed:
                return
            self._prepare()
            status = self._host._lib.synurang_host_half_close(self._host._handle, self._handle)
            if status:
                self._try_recv()
                raise FfiError("half-close failed: %d" % status, grpc_code=9)

    close_send = half_close

    def _try_recv(self):
        with self._host._lock:
            if self._buffered is not None:
                payload, self._buffered = self._buffered, None
                return payload
            if self._finished:
                if self._error:
                    raise self._error
                return None
            self._prepare()
            result = _Read()
            status = self._host._lib.synurang_host_receive(self._host._handle, self._handle, C.byref(result))
            try:
                payload = C.string_at(result.data, result.size) if result.size else b""
            finally:
                if result.data:
                    self._host._lib.synurang_host_free(self._host._handle, result.data)
            if status:
                self.close()
                raise FfiError("receive failed: %d" % status, grpc_code=13)
            if result.kind == 0:
                return _PENDING
            if result.kind == 1:
                return payload
            if result.kind != 2:
                self.close()
                raise FfiError("invalid module read kind", grpc_code=13)
            self._finished = True
            self._error = _rpc_error(result.code, payload) if result.code else None
            self._release()
            if self._error:
                raise self._error
            return None

    def recv(self) -> bytes | None:
        while True:
            version = self._host._progress.version()
            result = self._try_recv()
            if result is not _PENDING:
                return result
            self._host._progress.wait(version)

    def result(self) -> bytes:
        response = self.recv()
        if response is None:
            raise FfiError("unary RPC returned no response", grpc_code=13)
        if self.recv() is not None:
            self.close()
            raise FfiError("unary RPC returned multiple responses", grpc_code=13)
        return response

    def cancel(self, code: int = 1) -> None:
        if code < 1 or code > 16:
            raise ValueError("cancellation status must be 1..16")
        with self._host._lock:
            if self._handle:
                self._host._lib.synurang_host_cancel(self._host._handle, self._handle, code)
                self._host._notification.wake()

    def _release(self):
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        if self._handle:
            self._host._lib.synurang_host_release(self._host._handle, self._handle)
            self._handle = 0
            self._host._calls.discard(self)
            self._host._schedule_cleanup()

    def close(self):
        with self._host._lock:
            self._buffered = None
            if not self._finished:
                self._finished = True
                self._error = FfiError("call closed", grpc_code=1)
            self._release()

    def __iter__(self):
        while True:
            result = self.recv()
            if result is None:
                return
            yield result

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class AsyncModuleHost:
    """Async host sharing the same nonblocking ABI and bounded queues."""
    def __init__(self, host: ModuleHost):
        self._host = host
        self._close_task: asyncio.Task | None = None

    @classmethod
    def load(cls, path, **options):
        return cls(ModuleHost.load(path, **options))

    def open(self, method: str, **options) -> AsyncModuleCall:
        loop = asyncio.get_running_loop()
        if self._host._async_loop is not None and self._host._async_loop is not loop:
            raise RuntimeError("AsyncModuleHost belongs to a different event loop")
        self._host._async_loop = loop
        return AsyncModuleCall(self._host.open(method, **options))

    async def unary(self, method: str, request: bytes, *, timeout=None) -> bytes:
        async with self.open(method, timeout=timeout) as call:
            await call.send(request)
            await call.half_close()
            return await call.result()

    async def server_stream(self, method: str, request: bytes, *, timeout=None) -> AsyncIterator[bytes]:
        async with self.open(method, response_stream=True, timeout=timeout) as call:
            await call.send(request)
            await call.half_close()
            async for response in call:
                yield response

    async def client_stream(self, method: str, requests, *, timeout=None) -> bytes:
        async with self.open(method, request_stream=True, timeout=timeout) as call:
            async def produce():
                iterator = requests.__aiter__() if hasattr(requests, "__aiter__") else iter(requests)
                try:
                    if hasattr(iterator, "__anext__"):
                        async for request in iterator:
                            await call.send(request)
                            await asyncio.sleep(0)
                    else:
                        for request in iterator:
                            await call.send(request)
                            await asyncio.sleep(0)
                    await call.half_close()
                except RequestClosedError:
                    pass
                finally:
                    close = getattr(iterator, "aclose", None)
                    if close is not None:
                        await close()
                    else:
                        close = getattr(iterator, "close", None)
                        if close is not None:
                            close()

            sender = asyncio.create_task(produce())
            response = asyncio.create_task(call.result())
            try:
                ready, _ = await asyncio.wait((sender, response), return_when=asyncio.FIRST_COMPLETED)
                if response in ready:
                    return response.result()
                await sender  # Preserve input-generator failures.
                return await response
            finally:
                sender.cancel()
                response.cancel()
                await asyncio.gather(sender, response, return_exceptions=True)

    async def close(self):
        async def drain():
            while True:
                version = self._host._progress.version()
                if self._host._close_step():
                    return
                await self._host._progress.wait_async(version)
        if self._close_task is None:
            self._close_task = asyncio.create_task(drain())
        await asyncio.shield(self._close_task)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        await self.close()


class AsyncModuleCall:
    def __init__(self, call: ModuleCall):
        self._call = call
        self._send_lock = asyncio.Lock()
        self._recv_lock = asyncio.Lock()

    async def send(self, data: bytes):
        try:
            async with self._send_lock:
                payload = bytes(data)
                while True:
                    version = self._call._host._progress.version()
                    if self._call._try_send(payload):
                        return
                    await self._call._host._progress.wait_async(version)
        except asyncio.CancelledError:
            self.close()
            raise

    async def half_close(self):
        try:
            async with self._send_lock:
                self._call.half_close()
        except asyncio.CancelledError:
            self.close()
            raise

    close_send = half_close

    async def recv(self):
        try:
            async with self._recv_lock:
                while True:
                    version = self._call._host._progress.version()
                    result = self._call._try_recv()
                    if result is not _PENDING:
                        return result
                    await self._call._host._progress.wait_async(version)
        except asyncio.CancelledError:
            self.close()
            raise

    async def result(self):
        response = await self.recv()
        if response is None:
            raise FfiError("unary RPC returned no response", grpc_code=13)
        if await self.recv() is not None:
            self.close()
            raise FfiError("unary RPC returned multiple responses", grpc_code=13)
        return response

    def cancel(self, code=1):
        self._call.cancel(code)

    def close(self):
        self._call.close()

    def __aiter__(self):
        return self

    async def __anext__(self):
        response = await self.recv()
        if response is None:
            raise StopAsyncIteration
        return response

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        self.close()


Request = TypeVar("Request")
Response = TypeVar("Response")


class TypedModuleCall(Generic[Request, Response]):
    def __init__(self, call: ModuleCall, encode: Callable[[Request], bytes], decode: Callable[[bytes], Response]):
        self.call, self._encode, self._decode = call, encode, decode

    def send(self, request: Request):
        self.call.send(self._encode(request))

    def recv(self) -> Response | None:
        data = self.call.recv()
        try:
            return None if data is None else self._decode(data)
        except Exception:
            self.close()
            raise

    def half_close(self):
        self.call.half_close()

    def cancel(self, code=1):
        self.call.cancel(code)

    def close(self):
        self.call.close()

    def __iter__(self):
        while True:
            data = self.recv()
            if data is None:
                return
            yield data

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class TypedAsyncModuleCall(Generic[Request, Response]):
    def __init__(self, call: AsyncModuleCall, encode: Callable[[Request], bytes], decode: Callable[[bytes], Response]):
        self.call, self._encode, self._decode = call, encode, decode

    async def send(self, request: Request):
        await self.call.send(self._encode(request))

    async def recv(self) -> Response | None:
        data = await self.call.recv()
        try:
            return None if data is None else self._decode(data)
        except Exception:
            self.close()
            raise

    async def half_close(self):
        await self.call.half_close()

    def cancel(self, code=1):
        self.call.cancel(code)

    def close(self):
        self.call.close()

    def __aiter__(self):
        return self

    async def __anext__(self):
        data = await self.recv()
        if data is None:
            raise StopAsyncIteration
        return data

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        self.close()
