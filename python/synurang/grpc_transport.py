"""Optional synchronous ``grpcio`` transport for generated Synurang clients.

Importing this module does not import or require :mod:`grpc`.  Applications may
pass an existing synchronous channel to :class:`GrpcTransport`, or use the
factory methods that load ``grpcio`` only when a channel is created.
"""

from __future__ import annotations

import importlib
import queue
import threading
import weakref
from collections.abc import Iterable, Iterator, Sequence
from types import TracebackType
from typing import Any, Final, cast

from .transport import Metadata, RpcStream


_END_REQUESTS: Final = object()


def _identity(payload: bytes) -> bytes:
    return payload


def _load_grpc() -> Any:
    try:
        return importlib.import_module("grpc")
    except ImportError as error:
        raise ImportError(
            "remote gRPC transport requires the optional 'grpcio' package; "
            "install it with 'python -m pip install synurang[grpc]'"
        ) from error


class GrpcTransport:
    """Route raw protobuf payloads over a synchronous ``grpc.Channel``.

    The channel is borrowed by default.  Factory-created transports own their
    channel and close it when the transport is closed.  Default metadata is
    prepended to per-call metadata, preserving duplicate keys and ordering.

    Remote failures are raised as grpcio's native ``grpc.RpcError`` instances,
    preserving status codes and trailing metadata without making the core
    Synurang runtime depend on grpcio.
    """

    def __init__(
        self,
        channel: Any,
        *,
        close_channel: bool = False,
        default_timeout: float | None = None,
        default_metadata: Metadata | None = None,
        wait_for_ready: bool | None = None,
        compression: Any = None,
    ) -> None:
        if channel is None:
            raise TypeError("channel must not be None")
        if default_timeout is not None and default_timeout < 0:
            raise ValueError("default_timeout must be non-negative")
        self._channel = channel
        self._close_channel = close_channel
        self._default_timeout = default_timeout
        self._default_metadata = tuple(default_metadata or ())
        self._wait_for_ready = wait_for_ready
        self._compression = compression
        self._lock = threading.RLock()
        self._closed = False
        self._streams: weakref.WeakSet[Any] = weakref.WeakSet()

    @classmethod
    def insecure_channel(
        cls,
        target: str,
        *,
        options: Sequence[tuple[str, Any]] | None = None,
        compression: Any = None,
        default_timeout: float | None = None,
        default_metadata: Metadata | None = None,
        wait_for_ready: bool | None = None,
    ) -> "GrpcTransport":
        """Create and own an insecure ``grpcio`` channel."""

        grpc = _load_grpc()
        channel = grpc.insecure_channel(
            target, options=options, compression=compression
        )
        return cls(
            channel,
            close_channel=True,
            default_timeout=default_timeout,
            default_metadata=default_metadata,
            wait_for_ready=wait_for_ready,
            compression=compression,
        )

    @classmethod
    def secure_channel(
        cls,
        target: str,
        credentials: Any,
        *,
        options: Sequence[tuple[str, Any]] | None = None,
        compression: Any = None,
        default_timeout: float | None = None,
        default_metadata: Metadata | None = None,
        wait_for_ready: bool | None = None,
    ) -> "GrpcTransport":
        """Create and own a TLS/authenticated ``grpcio`` channel."""

        grpc = _load_grpc()
        channel = grpc.secure_channel(
            target,
            credentials,
            options=options,
            compression=compression,
        )
        return cls(
            channel,
            close_channel=True,
            default_timeout=default_timeout,
            default_metadata=default_metadata,
            wait_for_ready=wait_for_ready,
            compression=compression,
        )

    @property
    def channel(self) -> Any:
        """The wrapped synchronous gRPC channel."""

        return self._channel

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def unary_unary(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        del service
        call = self._channel.unary_unary(
            self._prepare_method(method),
            request_serializer=_identity,
            response_deserializer=_identity,
        )
        response = call(
            bytes(request), **self._call_options(timeout, metadata)
        )
        return bytes(response)

    def unary_stream(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> Iterator[bytes]:
        del service
        call = self._channel.unary_stream(
            self._prepare_method(method),
            request_serializer=_identity,
            response_deserializer=_identity,
        )
        responses = call(
            bytes(request), **self._call_options(timeout, metadata)
        )
        stream = _GrpcResponseStream(responses, self._discard_stream)
        with self._lock:
            if self._closed:
                stream.close()
                raise RuntimeError("transport is closed")
            self._streams.add(stream)
        return stream

    def stream_unary(
        self,
        service: str,
        method: str,
        requests: Iterable[bytes | bytearray | memoryview],
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        del service
        call = self._channel.stream_unary(
            self._prepare_method(method),
            request_serializer=_identity,
            response_deserializer=_identity,
        )
        wire_requests = (bytes(request) for request in requests)
        response = call(
            wire_requests, **self._call_options(timeout, metadata)
        )
        return bytes(response)

    def stream_stream(
        self,
        service: str,
        method: str,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> RpcStream:
        del service
        multi_callable = self._channel.stream_stream(
            self._prepare_method(method),
            request_serializer=_identity,
            response_deserializer=_identity,
        )
        stream = _GrpcBidiStream(
            multi_callable,
            self._call_options(timeout, metadata),
            self._discard_stream,
        )
        with self._lock:
            if self._closed:
                stream.close()
                raise RuntimeError("transport is closed")
            self._streams.add(stream)
        return stream

    def close(self) -> None:
        """Cancel open streaming RPCs and, when owned, close the channel."""

        with self._lock:
            if self._closed:
                return
            self._closed = True
            streams = list(self._streams)
            self._streams.clear()
            close_channel = self._close_channel

        for stream in streams:
            stream.close()
        if close_channel:
            close = getattr(self._channel, "close", None)
            if callable(close):
                close()

    def __enter__(self) -> "GrpcTransport":
        self._ensure_open()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def _prepare_method(self, method: str) -> str:
        self._ensure_open()
        if not method.startswith("/") or method.count("/") != 2:
            raise ValueError(
                "gRPC method must be a fully qualified '/package.Service/Method' path"
            )
        return method

    def _call_options(
        self, timeout: float | None, metadata: Metadata | None
    ) -> dict[str, Any]:
        if timeout is not None and timeout < 0:
            raise ValueError("timeout must be non-negative")
        effective_timeout = (
            self._default_timeout if timeout is None else timeout
        )
        effective_metadata = self._default_metadata + tuple(metadata or ())
        options: dict[str, Any] = {
            "timeout": effective_timeout,
            "metadata": effective_metadata or None,
        }
        if self._wait_for_ready is not None:
            options["wait_for_ready"] = self._wait_for_ready
        if self._compression is not None:
            options["compression"] = self._compression
        return options

    def _ensure_open(self) -> None:
        if self.closed:
            raise RuntimeError("transport is closed")

    def _discard_stream(self, stream: Any) -> None:
        with self._lock:
            self._streams.discard(stream)


class _GrpcResponseStream:
    """Cancelable iterator for one remote server-streaming call."""

    def __init__(self, responses: Any, on_close: Any) -> None:
        self._call = responses
        self._responses = iter(responses)
        self._lock = threading.RLock()
        self._next_lock = threading.Lock()
        self._closed = False
        self._on_close = on_close

    def __iter__(self) -> "_GrpcResponseStream":
        return self

    def __next__(self) -> bytes:
        with self._next_lock:
            with self._lock:
                if self._closed:
                    raise StopIteration
            try:
                return bytes(next(self._responses))
            except BaseException:
                self.close()
                raise

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            call = self._call

        try:
            cancel = getattr(call, "cancel", None)
            if callable(cancel):
                cancel()
        finally:
            self._on_close(self)

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass


class _GrpcBidiStream:
    """Queue-backed adapter for grpcio's iterator-based bidi API."""

    def __init__(
        self,
        multi_callable: Any,
        call_options: dict[str, Any],
        on_close: Any,
    ) -> None:
        self._requests: queue.Queue[bytes | object] = queue.Queue()
        self._lock = threading.RLock()
        self._recv_lock = threading.Lock()
        self._closed = False
        self._send_closed = False
        self._response_done = False
        self._terminal_notified = False
        self._on_close = on_close
        try:
            self._call = multi_callable(
                self._request_iterator(), **call_options
            )
            self._responses = iter(self._call)
            add_done_callback = getattr(self._call, "add_done_callback", None)
            if callable(add_done_callback):
                add_done_callback(self._call_finished)
        except BaseException:
            self._send_closed = True
            self._closed = True
            self._requests.put(_END_REQUESTS)
            raise

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def send(self, data: bytes | bytearray | memoryview) -> None:
        payload = bytes(data)
        with self._lock:
            if self._closed:
                raise RuntimeError("stream is closed")
            if self._send_closed:
                raise RuntimeError("stream send side is closed")
            self._requests.put(payload)

    def recv(self) -> bytes | None:
        with self._lock:
            if self._response_done:
                return None
            if self._closed:
                raise RuntimeError("stream is closed")
        with self._recv_lock:
            with self._lock:
                if self._response_done:
                    return None
            try:
                return bytes(next(self._responses))
            except StopIteration:
                with self._lock:
                    self._response_done = True
                    self._closed = True
                    self._finish_requests_locked()
                self._notify_terminal()
                return None
            except BaseException:
                self.close()
                raise

    def responses(self) -> Iterator[bytes]:
        """Iterate responses until the server closes its response side."""

        while True:
            response = self.recv()
            if response is None:
                return
            yield response

    def __iter__(self) -> Iterator[bytes]:
        return self.responses()

    def close_send(self) -> None:
        with self._lock:
            if self._closed:
                raise RuntimeError("stream is closed")
            self._finish_requests_locked()

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._finish_requests_locked()
            call = self._call

        try:
            cancel = getattr(call, "cancel", None)
            if callable(cancel):
                cancel()
        finally:
            self._notify_terminal()

    def __enter__(self) -> "_GrpcBidiStream":
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

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    def _request_iterator(self) -> Iterator[bytes]:
        while True:
            request = self._requests.get()
            if request is _END_REQUESTS:
                return
            yield cast(bytes, request)

    def _call_finished(self, _call: Any) -> None:
        # grpcio consumes the request iterator on a worker thread.  Wake that
        # thread when the remote side terminates before the caller half-closes.
        with self._lock:
            self._finish_requests_locked()

    def _finish_requests_locked(self) -> None:
        if not self._send_closed:
            self._send_closed = True
            self._requests.put(_END_REQUESTS)

    def _notify_terminal(self) -> None:
        with self._lock:
            if self._terminal_notified:
                return
            self._terminal_notified = True
            on_close = self._on_close
        on_close(self)


__all__ = ["GrpcTransport"]
