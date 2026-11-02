"""Close-policy vocabulary and C marshalling shared by Python owners."""

from __future__ import annotations

import ctypes
import time
from enum import StrEnum
from typing import Final

from . import _constants as _abi
from ._errors import GlowcapError
from ._ffi_host import _CloseOptions


class PendingWork(StrEnum):
    """What close does with operations admitted before its barrier."""

    CANCEL = "cancel"
    FINISH = "finish"


_UNSET: Final = object()


def _release_consumed(code: int) -> bool:
    """Whether final FFI release crossed its ownership boundary."""
    return code != _abi.ERR_INVALID_ARGUMENT


def _lifecycle_closed(raw: int) -> bool:
    """Decode FFI progress without letting an unknown state become a hang."""
    if raw in (_abi.LIFECYCLE_ACTIVE, _abi.LIFECYCLE_FINISHING, _abi.LIFECYCLE_TERMINATING):
        return False
    if raw == _abi.LIFECYCLE_CLOSED:
        return True
    raise GlowcapError(_abi.ERR_INTERNAL, f"glowcap ABI returned unknown lifecycle state {raw}")


def _monotonic_ms() -> int:
    return time.monotonic_ns() // 1_000_000


def _close_options(pending: PendingWork, grace_ms: object = _UNSET) -> _CloseOptions:
    """Marshal one close policy. ``grace_ms`` is a millisecond count, ``None``
    for the deliberate unbounded wait, or unset. FINISH names its grace budget
    explicitly, so unset is refused for it before any effect."""
    if grace_ms is _UNSET:
        if pending is PendingWork.FINISH:
            raise GlowcapError(_abi.ERR_INVALID_ARGUMENT, "finish close requires grace_ms (None waits without a bound)")
        grace_mode = _abi.CLOSE_GRACE_UNSPECIFIED
        grace_value = 0
    elif grace_ms is None:
        grace_mode = _abi.CLOSE_GRACE_UNBOUNDED
        grace_value = 0
    else:
        if (
            isinstance(grace_ms, bool)
            or not isinstance(grace_ms, int)
            or grace_ms < 0
            or grace_ms > _abi.CLOSE_MAX_GRACE_MS
        ):
            raise GlowcapError(
                _abi.ERR_INVALID_ARGUMENT,
                f"grace_ms must be None or an integer from 0 through {_abi.CLOSE_MAX_GRACE_MS}",
            )
        grace_mode = _abi.CLOSE_GRACE_FINITE
        grace_value = grace_ms
    pending_id = {PendingWork.CANCEL: _abi.PENDING_CANCEL, PendingWork.FINISH: _abi.PENDING_FINISH}.get(
        pending, 0xFFFF_FFFF
    )
    return _CloseOptions(
        abi_version=_abi.CLOSE_OPTIONS_ABI_VERSION,
        struct_size=ctypes.sizeof(_CloseOptions),
        pending=pending_id,
        grace_mode=grace_mode,
        grace_ms=grace_value,
    )
