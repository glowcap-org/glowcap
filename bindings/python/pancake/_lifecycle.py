"""Close-policy vocabulary and C marshalling shared by Python owners."""

from __future__ import annotations

import ctypes
import math
import time
from enum import Enum
from typing import Final

from . import _constants as _abi
from ._errors import PancakeError
from ._ffi_host import _CloseOptions


class PendingWork(str, Enum):
    """What close does with operations admitted before its barrier."""

    CANCEL = "cancel"
    FINISH = "finish"


_UNSET: Final = object()


def _monotonic_ms() -> int:
    return time.monotonic_ns() // 1_000_000


def _close_options(pending: PendingWork, grace: object = _UNSET) -> _CloseOptions:
    if grace is _UNSET:
        grace_mode = _abi.CLOSE_GRACE_UNSPECIFIED
        grace_ms = 0
    elif grace is None:
        grace_mode = _abi.CLOSE_GRACE_UNBOUNDED
        grace_ms = 0
    else:
        if isinstance(grace, bool) or not isinstance(grace, (int, float)) or grace < 0:
            raise PancakeError(_abi.ERR_INVALID_ARGUMENT, "grace must be a non-negative number of seconds or None")
        if isinstance(grace, float) and not math.isfinite(grace):
            raise PancakeError(_abi.ERR_INVALID_ARGUMENT, "grace must be finite")
        if grace > _abi.CLOSE_MAX_GRACE_MS / 1_000:
            raise PancakeError(
                _abi.ERR_INVALID_ARGUMENT,
                f"grace must not exceed {_abi.CLOSE_MAX_GRACE_MS} milliseconds",
            )
        grace_ms = math.ceil(grace * 1_000)
        if grace_ms > _abi.CLOSE_MAX_GRACE_MS:
            raise PancakeError(
                _abi.ERR_INVALID_ARGUMENT,
                f"grace must not exceed {_abi.CLOSE_MAX_GRACE_MS} milliseconds",
            )
        grace_mode = _abi.CLOSE_GRACE_FINITE
    pending_id = {
        PendingWork.CANCEL: _abi.PENDING_CANCEL,
        PendingWork.FINISH: _abi.PENDING_FINISH,
    }.get(pending, 0xFFFF_FFFF)
    return _CloseOptions(
        abi_version=_abi.CLOSE_OPTIONS_ABI_VERSION,
        struct_size=ctypes.sizeof(_CloseOptions),
        pending=pending_id,
        grace_mode=grace_mode,
        grace_ms=grace_ms,
    )
