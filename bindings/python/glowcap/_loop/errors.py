"""Driver-loop FFI failure projection."""

import ctypes

from .. import _constants as _c
from .._errors import GlowcapError
from .._ffi_driver import _driver
from .._ffi_ocapn import _BreakCause


def _last_driver_error() -> str | None:
    buf = ctypes.create_string_buffer(512)
    n = _driver.glowcap_driver_last_error(buf, len(buf))
    if n == 0:
        return None
    return buf.raw[: min(n, len(buf))].split(b"\x00", 1)[0].decode("utf-8", "replace")


def _last_driver_cause() -> tuple[int, int, int]:
    """The driver archive's typed cause for the call that just failed."""
    raw = _BreakCause()
    _driver.glowcap_driver_last_error_cause(ctypes.byref(raw))
    return raw.origin, raw.reason, raw.context


def _check(rc: int) -> None:
    if rc != _c.OK:
        # Capture message and cause now, before any later call clobbers them.
        raise GlowcapError(rc, _last_driver_error(), cause=_last_driver_cause())


def _as_driver_error(error: BaseException) -> GlowcapError:
    if isinstance(error, GlowcapError):
        return error
    return GlowcapError(_c.ERR_INTERNAL, f"driver loop failed: {error}")
