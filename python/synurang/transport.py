"""Transport-neutral, raw-byte RPC interfaces.

Generated Synurang clients serialize their dependency-free lite messages before
calling these interfaces.  A transport therefore only needs to move protobuf
wire bytes; it never needs to know about generated message classes.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Iterable, Iterator, Sequence
from types import TracebackType
from typing import TYPE_CHECKING, Any, Protocol, TypeAlias, runtime_checkable

from .errors import FfiError, PluginClosedError

if TYPE_CHECKING:
    from .plugin import PluginHost
else:
    # Keep postponed public annotations resolvable without recreating the
    # transport/plugin import cycle at runtime.
    PluginHost = Any


MetadataValue: TypeAlias = str | bytes
"""A gRPC metadata value.  Binary (``-bin``) entries use :class:`bytes`."""

Metadata: TypeAlias = Sequence[tuple[str, MetadataValue]]
"""Ordered RPC metadata key/value pairs."""


@runtime_checkable
class RpcStream(Protocol):
    """An interactive bidirectional stream of protobuf wire payloads.

    One thread may call :meth:`send` while another calls :meth:`recv`.  Callers
    close the request side with :meth:`close_send`; responses remain readable
    until :meth:`recv` returns ``None``.
    """

    @property
    def closed(self) -> bool:
        """Whether the whole stream has been closed."""

    def send(self, data: bytes | bytearray | memoryview) -> None:
        """Send one serialized request."""

    def recv(self) -> bytes | None:
        """Receive one serialized response, or ``None`` at end-of-stream."""

    def close_send(self) -> None:
        """Close the request side while keeping the response side open."""

    def close(self) -> None:
        """Cancel or close both sides of the stream."""

    def __enter__(self) -> "RpcStream":
        """Enter a stream context."""

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the stream when leaving its context."""


@runtime_checkable
class RpcTransport(Protocol):
    """Raw-byte transport used by generated service clients.

    ``service`` is the generated ABI service symbol (for example ``Greeter``),
    while ``method`` is the fully qualified gRPC path (for example
    ``/hello.v1.Greeter/SayHello``).  Carrying both values lets the same client
    drive either the Synurang shared-library ABI or a remote gRPC channel.
    """

    @property
    def closed(self) -> bool:
        """Whether the transport no longer accepts new RPCs."""

    def unary_unary(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        """Perform a unary-request, unary-response RPC."""

    def unary_stream(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> Iterator[bytes]:
        """Perform a unary-request, streaming-response RPC."""

    def stream_unary(
        self,
        service: str,
        method: str,
        requests: Iterable[bytes | bytearray | memoryview],
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        """Perform a streaming-request, unary-response RPC."""

    def stream_stream(
        self,
        service: str,
        method: str,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> RpcStream:
        """Open an interactive bidirectional-streaming RPC."""

    def close(self) -> None:
        """Release resources and reject new RPCs."""

    def __enter__(self) -> "RpcTransport":
        """Enter a transport context."""

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the transport when leaving its context."""


class FfiTransport:
    """Route RPCs to a Synurang plugin loaded in the current process.

    A transport constructed around an existing :class:`PluginHost` borrows it
    by default.  Use :meth:`load`, or pass ``close_host=True``, when the
    transport should own and close the host.

    The Synurang native ABI has no timeout or metadata fields.  Supplying those
    options raises :class:`ValueError` instead of silently discarding them.
    """

    def __init__(self, host: PluginHost, *, close_host: bool = False) -> None:
        self._host = host
        self._close_host = close_host
        self._lock = threading.RLock()
        self._closed = False

    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> "FfiTransport":
        """Load ``path`` and return a transport that owns the plugin host."""

        from .plugin import PluginHost

        return cls(PluginHost.load(path), close_host=True)

    @property
    def host(self) -> PluginHost:
        """The wrapped plugin host."""

        return self._host

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed or bool(getattr(self._host, "closed", False))

    def unary_unary(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        self._prepare_call(timeout, metadata)
        return self._host.invoke(service, method, request)

    def unary_stream(
        self,
        service: str,
        method: str,
        request: bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> Iterator[bytes]:
        self._prepare_call(timeout, metadata)
        wire_request = bytes(request)

        def responses() -> Iterator[bytes]:
            self._ensure_open()
            stream = self._host.open_stream(service, method)
            try:
                stream.send(wire_request)
                stream.close_send()
                while True:
                    response = stream.recv()
                    if response is None:
                        return
                    yield response
            finally:
                stream.close()

        return responses()

    def stream_unary(
        self,
        service: str,
        method: str,
        requests: Iterable[bytes | bytearray | memoryview],
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> bytes:
        self._prepare_call(timeout, metadata)
        with self._host.open_stream(service, method) as stream:
            for request in requests:
                stream.send(request)
            stream.close_send()
            response = stream.recv()
            if response is None:
                raise FfiError("no response from client-streaming RPC")
            return response

    def stream_stream(
        self,
        service: str,
        method: str,
        *,
        timeout: float | None = None,
        metadata: Metadata | None = None,
    ) -> RpcStream:
        self._prepare_call(timeout, metadata)
        return self._host.open_stream(service, method)

    def close(self) -> None:
        """Close this wrapper and, when owned, its plugin host."""

        with self._lock:
            if self._closed:
                return
            self._closed = True
            close_host = self._close_host
        if close_host:
            self._host.close()

    def __enter__(self) -> "FfiTransport":
        self._ensure_open()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def _ensure_open(self) -> None:
        if self.closed:
            raise PluginClosedError("transport is closed")

    def _prepare_call(
        self, timeout: float | None, metadata: Metadata | None
    ) -> None:
        self._ensure_open()
        if timeout is not None:
            raise ValueError("FFI transport does not support RPC timeouts")
        if metadata:
            raise ValueError("FFI transport does not support RPC metadata")

__all__ = [
    "FfiTransport",
    "Metadata",
    "MetadataValue",
    "RpcStream",
    "RpcTransport",
]
