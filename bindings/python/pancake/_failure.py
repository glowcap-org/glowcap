"""Typed projection of the Context-owned unreturnable-failure seam."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, replace
from enum import Enum
import threading

from ._constants_gen import (
    ERR_INTERNAL,
    ERR_TIMEOUT,
    FAILURE_LAYER_APPLICATION_OBSERVER,
    FAILURE_LAYER_BINDING,
    FAILURE_LAYER_CORE,
    FAILURE_LAYER_DRIVER,
    FAILURE_LAYER_TRANSPORT,
    FAILURE_SCOPE_CONTEXT,
    FAILURE_SCOPE_HOST,
    FAILURE_SCOPE_LISTENER,
    FAILURE_SCOPE_OPERATION,
    FAILURE_SCOPE_PROCESS,
    FAILURE_SCOPE_SESSION,
    FAILURE_SCOPE_TRANSPORT,
)
from ._errors import PancakeError


class FailureLayer(Enum):
    """The layer that observed an unreturnable failure."""

    CORE = "core"
    DRIVER = "driver"
    TRANSPORT = "transport"
    BINDING = "binding"
    APPLICATION_OBSERVER = "application-observer"


class FailureScope(Enum):
    """The lifecycle owner of the operation that failed."""

    PROCESS = "process"
    CONTEXT = "context"
    HOST = "host"
    SESSION = "session"
    LISTENER = "listener"
    TRANSPORT = "transport"
    OPERATION = "operation"


@dataclass(frozen=True)
class FailureEvent:
    """A failure that had no remaining deterministic return recipient.

    Events are claimed once in observation order. ``dropped_before`` reports
    bounded records evicted before this event; ``secondary_count`` preserves
    the total consequences while the first remains typed in ``secondary_*``.
    """

    sequence: int
    dropped_before: int
    layer: FailureLayer
    scope: FailureScope
    scope_id: int
    operation_id: int
    primary_result: int
    secondary_result: int
    secondary_count: int
    truncated_fields: int
    operation: str
    primary_name: str
    primary_message: str
    secondary_name: str
    secondary_message: str


_LAYERS = {
    FAILURE_LAYER_CORE: FailureLayer.CORE,
    FAILURE_LAYER_DRIVER: FailureLayer.DRIVER,
    FAILURE_LAYER_TRANSPORT: FailureLayer.TRANSPORT,
    FAILURE_LAYER_BINDING: FailureLayer.BINDING,
    FAILURE_LAYER_APPLICATION_OBSERVER: FailureLayer.APPLICATION_OBSERVER,
}
_SCOPES = {
    FAILURE_SCOPE_PROCESS: FailureScope.PROCESS,
    FAILURE_SCOPE_CONTEXT: FailureScope.CONTEXT,
    FAILURE_SCOPE_HOST: FailureScope.HOST,
    FAILURE_SCOPE_SESSION: FailureScope.SESSION,
    FAILURE_SCOPE_LISTENER: FailureScope.LISTENER,
    FAILURE_SCOPE_TRANSPORT: FailureScope.TRANSPORT,
    FAILURE_SCOPE_OPERATION: FailureScope.OPERATION,
}
_PAYLOAD_CAP = 512
_U64_MAX = (1 << 64) - 1


def _bounded_text(fields: tuple[str, ...]) -> tuple[tuple[str, ...], int]:
    """Copy one native-sized UTF-8 prefix across the ordered schema fields."""
    remaining = _PAYLOAD_CAP
    retained = []
    flags = 0
    for index, field in enumerate(fields):
        encoded = field.encode()
        decoded = encoded[:remaining].decode(errors="ignore")
        copied_len = len(decoded.encode())
        retained.append(decoded)
        remaining -= copied_len
        if copied_len != len(encoded):
            flags |= 1 << index
    return tuple(retained), flags


class _RuntimeFailureQueue:
    """Bounded surviving owner for failures observed after resource owners die."""

    def __init__(self, capacity: int = 64) -> None:
        if capacity <= 0:
            raise ValueError("runtime failure capacity must be positive")
        self._events: deque[FailureEvent] = deque(maxlen=capacity)
        self._next_sequence = 1
        self._lock = threading.Lock()

    def record(self, layer: FailureLayer, operation: str, error: BaseException) -> None:
        result = getattr(error, "code", ERR_INTERNAL)
        if type(result) is not int or not ERR_TIMEOUT <= result <= 0:
            result = ERR_INTERNAL
        secondary_count = getattr(error, "secondary_count", 0)
        if type(secondary_count) is not int or secondary_count < 0:
            secondary_count = 0
        secondary_count = min((1 << 32) - 1, secondary_count)
        secondary_values = getattr(error, "secondary", ())
        secondary = (
            secondary_values[0]
            if secondary_count and isinstance(secondary_values, tuple) and secondary_values
            else None
        )
        # PancakeError always retains the first consequence when its count is
        # nonzero. Callerless application exceptions are arbitrary Python
        # objects, though, and may expose contradictory duck-typed attributes.
        # Do not publish a count the central schema would reject for lacking a
        # named first cause.
        if secondary is None:
            secondary_count = 0
        secondary_result = getattr(secondary, "code", 0)
        if type(secondary_result) is not int or not ERR_TIMEOUT <= secondary_result <= 0:
            secondary_result = ERR_INTERNAL
        bounded, truncated_fields = _bounded_text(
            (
                operation,
                type(error).__name__,
                str(error),
                type(secondary).__name__ if secondary is not None else "",
                str(secondary) if secondary is not None else "",
            )
        )
        operation, primary_name, primary_message, secondary_name, secondary_message = bounded
        with self._lock:
            dropped_before = 0
            if len(self._events) == self._events.maxlen:
                dropped = min(_U64_MAX, self._events.popleft().dropped_before + 1)
                if self._events:
                    self._events[0] = replace(
                        self._events[0],
                        dropped_before=min(
                            _U64_MAX,
                            self._events[0].dropped_before + dropped,
                        ),
                    )
                else:
                    dropped_before = dropped
            event = FailureEvent(
                sequence=self._next_sequence,
                dropped_before=dropped_before,
                layer=layer,
                scope=FailureScope.PROCESS,
                scope_id=0,
                operation_id=0,
                primary_result=result,
                secondary_result=secondary_result,
                secondary_count=secondary_count,
                truncated_fields=truncated_fields,
                operation=operation,
                primary_name=primary_name,
                primary_message=primary_message,
                secondary_name=secondary_name,
                secondary_message=secondary_message,
            )
            self._next_sequence = min(_U64_MAX, self._next_sequence + 1)
            self._events.append(event)

    def claim(self) -> tuple[FailureEvent, ...]:
        with self._lock:
            events = tuple(self._events)
            self._events.clear()
            return events


_runtime_failures = _RuntimeFailureQueue()


def _record_runtime_failure(
    layer: FailureLayer, operation: str, error: BaseException
) -> None:
    _runtime_failures.record(layer, operation, error)


def take_runtime_failures() -> tuple[FailureEvent, ...]:
    """Atomically claim failures that outlived any Context or Host owner."""
    return _runtime_failures.claim()


def _layer(value: int) -> FailureLayer:
    # The C boundary rejects unknown values before a record enters the journal.
    try:
        return _LAYERS[value]
    except KeyError as error:
        raise PancakeError(
            ERR_INTERNAL,
            f"pancake ABI returned unknown failure layer {value}",
        ) from error


def _scope(value: int) -> FailureScope:
    try:
        return _SCOPES[value]
    except KeyError as error:
        raise PancakeError(
            ERR_INTERNAL,
            f"pancake ABI returned unknown failure scope {value}",
        ) from error
