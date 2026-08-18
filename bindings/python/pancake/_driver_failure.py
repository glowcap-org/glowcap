"""Thin projection of the driver's versioned deterministic failure record."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from typing import Callable, Optional

from . import _constants as _c
from ._carrier_failure import CarrierFailure, _decode as _decode_carrier
from ._errors import PancakeError
from ._ffi_driver import _driver, _DriverFailure


@dataclass(frozen=True)
class _Failure:
    primary_result: int
    primary_name: str
    secondary_result: int
    secondary_count: int
    secondary_name: str
    carrier_failure: Optional[CarrierFailure]


@dataclass(frozen=True)
class _Outcome:
    code: int
    failure: Optional[_Failure]
    error: Optional[PancakeError]


def _text(pointer: Optional[int], length: int, field: str) -> str:
    if length == 0:
        return ""
    if not pointer:
        raise PancakeError(
            _c.ERR_INTERNAL, f"driver returned null {field} with nonzero length"
        )
    try:
        return ctypes.string_at(pointer, length).decode("utf-8", "strict")
    except UnicodeDecodeError as cause:
        raise PancakeError(
            _c.ERR_INTERNAL, f"driver returned non-UTF-8 {field}"
        ) from cause


def _error(failure: _Failure, operation: str) -> PancakeError:
    detail = (
        f"{operation} failed: {failure.primary_name}"
        if failure.primary_name
        else f"{operation} failed"
    )
    error = PancakeError(failure.primary_result, detail)
    error.carrier_failure = failure.carrier_failure
    error.secondary_count = failure.secondary_count
    if failure.secondary_count:
        error.secondary = (
            PancakeError(failure.secondary_result, failure.secondary_name),
        )
    return error


def _decode(code: int, raw: _DriverFailure, operation: str) -> _Outcome:
    failure = _Failure(
        raw.primary_result,
        _text(raw.primary_name, raw.primary_name_len, "primary failure name"),
        raw.secondary_result,
        raw.secondary_count,
        _text(raw.secondary_name, raw.secondary_name_len, "secondary failure name"),
        _decode_carrier(
            raw.carrier_phase,
            raw.carrier_detail_flags,
            raw.carrier_verification_flags,
            raw.carrier_peer_alert,
            raw.carrier_engine_code,
        ),
    )
    if code == _c.OK:
        if failure == _Failure(_c.OK, "", _c.OK, 0, "", None):
            return _Outcome(code, None, None)
        raise PancakeError(
            _c.ERR_INTERNAL, f"{operation} returned success with failure data"
        )
    if failure.primary_result != code or not failure.primary_name:
        raise PancakeError(
            _c.ERR_INTERNAL, f"{operation} returned an inconsistent failure record"
        )
    if (
        failure.secondary_count == 0
        and (failure.secondary_result != _c.OK or failure.secondary_name)
    ) or (
        failure.secondary_count > 0
        and (failure.secondary_result == _c.OK or not failure.secondary_name)
    ):
        raise PancakeError(
            _c.ERR_INTERNAL,
            f"{operation} returned an inconsistent secondary failure",
        )
    return _Outcome(code, failure, _error(failure, operation))


def _call_driver(operation: str, call: Callable[[object], int]) -> _Outcome:
    raw = _DriverFailure()
    raw.abi_version = _c.DRIVER_FAILURE_ABI_VERSION
    raw.struct_size = ctypes.sizeof(_DriverFailure)
    code = call(ctypes.byref(raw))
    try:
        return _decode(code, raw, operation)
    except PancakeError as error:
        return _Outcome(code, None, error)


def _release(driver, handle, operation: str) -> _Outcome:
    return _call_driver(
        operation, lambda out: driver.pancake_driver_release(handle, out)
    )


def _add_provider(driver, handle, package) -> None:
    outcome = _call_driver(
        "driver add_provider",
        lambda out: driver.pancake_driver_add_provider(
            handle, ctypes.byref(package), out
        ),
    )
    if outcome.error is not None:
        raise outcome.error


def _close_listener(handle, listener: int) -> None:
    outcome = _call_driver(
        "driver listener_close",
        lambda out: _driver.pancake_driver_listener_close(handle, listener, out),
    )
    if outcome.error is not None:
        raise outcome.error


def _driver_event_failure(event, operation: str) -> PancakeError:
    """Project an authoritative driver-event result through the same shape."""
    return _error(
        _Failure(
            event.primary_result,
            event.primary_name,
            event.secondary_result,
            event.secondary_count,
            event.secondary_name,
            event.carrier_failure,
        ),
        operation,
    )


def _report_fields(outcome: _Outcome, operation: str) -> dict[str, object]:
    """Project one failed outcome into the shared Context report vocabulary."""
    assert outcome.error is not None
    failure = outcome.failure
    return {
        "operation": operation,
        "primary_name": failure.primary_name if failure else type(outcome.error).__name__,
        "primary_result": outcome.error.code,
        "primary_message": str(outcome.error),
        "secondary_name": failure.secondary_name if failure else "",
        "secondary_result": failure.secondary_result if failure else 0,
        "secondary_count": failure.secondary_count if failure else 0,
    }
