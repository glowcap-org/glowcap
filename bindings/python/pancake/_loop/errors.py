"""Driver-loop native failure projection."""

import ctypes
from typing import Optional

from .. import _constants as _c
from .._errors import PancakeError
from .._ffi_driver import _driver


def _last_driver_error() -> Optional[str]:
    buf = ctypes.create_string_buffer(512)
    n = _driver.pancake_driver_last_error(buf, len(buf))
    if n == 0:
        return None
    return buf.raw[: min(n, len(buf))].split(b"\x00", 1)[0].decode("utf-8", "replace")


def _check(rc: int) -> None:
    if rc != _c.OK:
        raise PancakeError(rc, _last_driver_error())


def _as_driver_error(error: BaseException) -> PancakeError:
    if isinstance(error, PancakeError):
        return error
    return PancakeError(_c.ERR_INTERNAL, f"driver loop failed: {error}")
