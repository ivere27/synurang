"""Pure-Python loader for Synurang plugin shared libraries."""

from __future__ import annotations

import contextlib
import ctypes
import os
import threading
import weakref
from collections.abc import Callable, Iterator
from pathlib import Path
from types import TracebackType
from typing import Generic, TypeVar

from .errors import FfiError, PluginClosedError
from .transport import RpcStream


_MAX_I32 = (1 << 31) - 1

_InvokeFunc = ctypes.CFUNCTYPE(
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_void_p,
    ctypes.c_int32,
    ctypes.POINTER(ctypes.c_int32),
)
_FreeFunc = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
_StreamOpenFunc = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_char_p)
_StreamSendFunc = ctypes.CFUNCTYPE(
    ctypes.c_int32, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int32
)
_StreamRecvFunc = ctypes.CFUNCTYPE(
    ctypes.c_void_p,
    ctypes.c_uint64,
    ctypes.POINTER(ctypes.c_int32),
    ctypes.POINTER(ctypes.c_int32),
)
_StreamCloseSendFunc = ctypes.CFUNCTYPE(None, ctypes.c_uint64)
_StreamCloseFunc = ctypes.CFUNCTYPE(None, ctypes.c_uint64)


class _StreamFunctions:
    __slots__ = ("send", "recv", "close_send", "close")

    def __init__(
        self,
        send: _StreamSendFunc,
        recv: _StreamRecvFunc,
        close_send: _StreamCloseSendFunc,
        close: _StreamCloseFunc,
    ) -> None:
        self.send = send
        self.recv = recv
        self.close_send = close_send
        self.close = close


class PluginHost:
    """Load and call a Go, C++, or Rust Synurang plugin.

    The host is safe to use from multiple Python threads.  Native calls made
    through ``ctypes.CDLL`` release the GIL, and the host prevents the shared
    library from being unloaded while a call is active.
    """

    def __init__(self, path: str | os.PathLike[str]) -> None:
        self._path = os.fspath(path)
        self._condition = threading.Condition(threading.RLock())
        self._active_calls = 0
        self._close_requested = False
        self._closed = False
        self._invokers: dict[str, _InvokeFunc] = {}
        self._stream_openers: dict[str, _StreamOpenFunc] = {}
        self._stream_functions: _StreamFunctions | None = None
        self._streams: weakref.WeakSet[PluginStream] = weakref.WeakSet()

        try:
            self._library: ctypes.CDLL | None = ctypes.CDLL(self._path)
        except OSError as error:
            raise FfiError(f"failed to load plugin {self._path!r}: {error}") from error

        try:
            self._free: _FreeFunc | None = self._resolve(
                "Synurang_Free", _FreeFunc
            )
        except Exception:
            library = self._library
            self._library = None
            if library is not None:
                _unload_library(library)
            raise

    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> "PluginHost":
        """Load a plugin from ``path``."""

        return cls(path)

    @property
    def path(self) -> Path:
        return Path(self._path)

    @property
    def closed(self) -> bool:
        with self._condition:
            return self._close_requested or self._closed

    def invoke(
        self,
        service_name: str,
        method: str,
        data: bytes | bytearray | memoryview,
    ) -> bytes:
        """Invoke a unary RPC and return its serialized protobuf response."""

        method_bytes = _encode_c_string(method, "method")
        request, request_pointer = _native_buffer(data)

        with self._native_call():
            invoke = self._get_invoker(service_name)
            response_length = ctypes.c_int32()
            response_pointer = invoke(
                method_bytes,
                request_pointer,
                len(request),
                ctypes.byref(response_length),
            )
            length = response_length.value

            if not response_pointer:
                if length == 0:
                    return b""
                raise FfiError(f"plugin returned null for {method}")

            payload = self._copy_and_free(response_pointer, abs(length))
            if length < 0:
                raise FfiError.from_payload(payload)
            return payload

    def open_stream(self, service_name: str, method: str) -> "PluginStream":
        """Open a streaming RPC."""

        method_bytes = _encode_c_string(method, "method")
        with self._native_call():
            functions = self._get_stream_functions()
            opener = self._get_stream_opener(service_name)
            handle = int(opener(method_bytes))
            if handle == 0:
                raise FfiError(f"failed to open stream for {method}")

            stream = PluginStream(self, handle, functions)
            with self._condition:
                if self._close_requested or self._closed:
                    functions.close(handle)
                    raise PluginClosedError()
                self._streams.add(stream)
            return stream

    def close(self) -> None:
        """Close open streams, wait for active calls, and unload the plugin."""

        with self._condition:
            if self._close_requested or self._closed:
                return
            self._close_requested = True
            streams = list(self._streams)

        for stream in streams:
            stream._close_from_host()

        with self._condition:
            while self._active_calls:
                self._condition.wait()
            if self._closed:
                return
            self._closed = True

            library = self._library
            self._library = None
            self._free = None
            self._invokers.clear()
            self._stream_openers.clear()
            self._stream_functions = None

        if library is not None:
            _unload_library(library)

    def __enter__(self) -> "PluginHost":
        if self.closed:
            raise PluginClosedError()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    @contextlib.contextmanager
    def _native_call(self, *, allow_during_close: bool = False) -> Iterator[None]:
        with self._condition:
            if self._closed or (self._close_requested and not allow_during_close):
                raise PluginClosedError()
            self._active_calls += 1
        try:
            yield
        finally:
            with self._condition:
                self._active_calls -= 1
                if self._active_calls == 0:
                    self._condition.notify_all()

    def _resolve(self, name: str, function_type: type[ctypes._CFuncPtr]):
        library = self._library
        if library is None:
            raise PluginClosedError()
        try:
            address = ctypes.cast(library[name], ctypes.c_void_p).value
        except AttributeError as error:
            raise FfiError(f"plugin symbol not found: {name}") from error
        if not address:
            raise FfiError(f"plugin symbol not found: {name}")
        return function_type(address)

    def _get_invoker(self, service_name: str) -> _InvokeFunc:
        _validate_symbol_component(service_name, "service name")
        with self._condition:
            invoke = self._invokers.get(service_name)
            if invoke is None:
                symbol = f"Synurang_Invoke_{service_name}"
                invoke = self._resolve(symbol, _InvokeFunc)
                self._invokers[service_name] = invoke
            return invoke

    def _get_stream_opener(self, service_name: str) -> _StreamOpenFunc:
        _validate_symbol_component(service_name, "service name")
        with self._condition:
            opener = self._stream_openers.get(service_name)
            if opener is None:
                symbol = f"Synurang_Stream_{service_name}_Open"
                opener = self._resolve(symbol, _StreamOpenFunc)
                self._stream_openers[service_name] = opener
            return opener

    def _get_stream_functions(self) -> _StreamFunctions:
        with self._condition:
            functions = self._stream_functions
            if functions is None:
                functions = _StreamFunctions(
                    self._resolve("Synurang_Stream_Send", _StreamSendFunc),
                    self._resolve("Synurang_Stream_Recv", _StreamRecvFunc),
                    self._resolve(
                        "Synurang_Stream_CloseSend", _StreamCloseSendFunc
                    ),
                    self._resolve("Synurang_Stream_Close", _StreamCloseFunc),
                )
                self._stream_functions = functions
            return functions

    def _copy_and_free(self, pointer: int, length: int) -> bytes:
        if length < 0 or length > _MAX_I32:
            self._free_response(pointer)
            raise FfiError(f"invalid plugin response length: {length}")
        try:
            return ctypes.string_at(pointer, length)
        finally:
            self._free_response(pointer)

    def _free_response(self, pointer: int | None) -> None:
        if pointer:
            free = self._free
            if free is None:
                raise PluginClosedError()
            free(pointer)

    def _unregister_stream(self, stream: "PluginStream") -> None:
        with self._condition:
            self._streams.discard(stream)


class PluginStream:
    """Raw byte stream returned by :meth:`PluginHost.open_stream`."""

    def __init__(
        self,
        host: PluginHost,
        handle: int,
        functions: _StreamFunctions,
    ) -> None:
        self._host = host
        self._handle = handle
        self._functions = functions
        self._lock = threading.Lock()
        self._closed = False
        self._send_closed = False

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def send(self, data: bytes | bytearray | memoryview) -> None:
        """Send one serialized protobuf request."""

        with self._lock:
            if self._closed:
                raise PluginClosedError("stream is closed")
            if self._send_closed:
                raise PluginClosedError("stream send side is closed")
        request, request_pointer = _native_buffer(data)
        with self._host._native_call():
            result = int(self._functions.send(self._handle, request_pointer, len(request)))
        if result != 0:
            raise FfiError(f"stream send failed with code {result}")

    def recv(self) -> bytes | None:
        """Receive one serialized response, or ``None`` at end-of-stream."""

        with self._lock:
            if self._closed:
                raise PluginClosedError("stream is closed")

        response_length = ctypes.c_int32()
        status = ctypes.c_int32()
        with self._host._native_call():
            response_pointer = self._functions.recv(
                self._handle,
                ctypes.byref(response_length),
                ctypes.byref(status),
            )
            length = response_length.value
            status_value = status.value

            if status_value == 1:
                self._host._free_response(response_pointer)
                return None
            if status_value < 0:
                if response_pointer and length > 0:
                    payload = self._host._copy_and_free(response_pointer, length)
                    raise FfiError.from_payload(payload)
                self._host._free_response(response_pointer)
                raise FfiError(f"stream recv failed with status {status_value}")
            if status_value != 0:
                self._host._free_response(response_pointer)
                raise FfiError(f"stream recv failed with status {status_value}")
            if length < 0:
                self._host._free_response(response_pointer)
                raise FfiError(f"invalid stream response length: {length}")
            if not response_pointer:
                if length == 0:
                    return b""
                raise FfiError("plugin returned null for stream recv")
            return self._host._copy_and_free(response_pointer, length)

    def close_send(self) -> None:
        """Close the send half while leaving responses readable."""

        with self._lock:
            if self._closed:
                raise PluginClosedError("stream is closed")
            if self._send_closed:
                return
            self._send_closed = True
        with self._host._native_call():
            self._functions.close_send(self._handle)

    def close(self) -> None:
        self._close(allow_during_host_close=True)

    def _close_from_host(self) -> None:
        self._close(allow_during_host_close=True)

    def _close(self, *, allow_during_host_close: bool) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._send_closed = True
        try:
            try:
                with self._host._native_call(
                    allow_during_close=allow_during_host_close
                ):
                    self._functions.close(self._handle)
            except PluginClosedError:
                pass
        finally:
            self._host._unregister_stream(self)

    def __enter__(self) -> "PluginStream":
        if self.closed:
            raise PluginClosedError("stream is closed")
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass


RequestT = TypeVar("RequestT")
ResponseT = TypeVar("ResponseT")


class BidiStream(Generic[RequestT, ResponseT]):
    """Typed helper used by generated bidirectional-streaming clients."""

    def __init__(
        self,
        stream: RpcStream,
        serializer: Callable[[RequestT], bytes],
        deserializer: Callable[[bytes], ResponseT],
    ) -> None:
        self._stream = stream
        self._serializer = serializer
        self._deserializer = deserializer

    @property
    def closed(self) -> bool:
        return self._stream.closed

    def send(self, request: RequestT) -> None:
        self._stream.send(self._serializer(request))

    def recv(self) -> ResponseT | None:
        payload = self._stream.recv()
        return None if payload is None else self._deserializer(payload)

    def responses(self) -> Iterator[ResponseT]:
        while True:
            response = self.recv()
            if response is None:
                return
            yield response

    def __iter__(self) -> Iterator[ResponseT]:
        return self.responses()

    def close_send(self) -> None:
        self._stream.close_send()

    def close(self) -> None:
        self._stream.close()

    def __enter__(self) -> "BidiStream[RequestT, ResponseT]":
        if self.closed:
            raise RuntimeError("stream is closed")
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()


def _native_buffer(
    data: bytes | bytearray | memoryview,
) -> tuple[ctypes.Array[ctypes.c_ubyte] | bytes, ctypes.c_void_p | None]:
    payload = bytes(data)
    if len(payload) > _MAX_I32:
        raise ValueError("FFI payload exceeds the signed 32-bit ABI length")
    if not payload:
        return payload, None
    buffer = (ctypes.c_ubyte * len(payload)).from_buffer_copy(payload)
    return buffer, ctypes.cast(buffer, ctypes.c_void_p)


def _encode_c_string(value: str, label: str) -> bytes:
    encoded = value.encode("utf-8")
    if b"\0" in encoded:
        raise ValueError(f"{label} contains a NUL byte")
    return encoded


def _validate_symbol_component(value: str, label: str) -> None:
    if not value or not value.replace("_", "").isalnum() or not value.isascii():
        raise ValueError(f"invalid {label}: {value!r}")


def _unload_library(library: ctypes.CDLL) -> None:
    handle = getattr(library, "_handle", 0)
    if not handle:
        return
    try:
        import _ctypes

        if os.name == "nt":
            free_library = getattr(_ctypes, "FreeLibrary", None)
            if free_library is not None:
                free_library(handle)
        else:
            close_library = getattr(_ctypes, "dlclose", None)
            if close_library is not None:
                close_library(handle)
    finally:
        # CDLL itself has no public close operation.  Clearing the handle keeps
        # accidental post-close lookups from using an unloaded library.
        library._handle = 0
