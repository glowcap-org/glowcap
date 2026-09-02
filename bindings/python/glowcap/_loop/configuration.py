"""Driver-loop native option validation and C projection."""

import ctypes

from .. import _constants as _c
from .._errors import GlowcapError
from .._ffi_driver import _DriverOptions


def _driver_options(
    wire_buffer_bytes: int,
    max_pending_opens: int,
    handshake_ms: int,
    listener_setup_ms: int,
    settle_ms: int,
) -> _DriverOptions:
    fields = (
        ("wire_buffer_bytes", wire_buffer_bytes, ctypes.c_size_t(-1).value),
        ("max_pending_opens", max_pending_opens, ctypes.c_size_t(-1).value),
        ("handshake_ms", handshake_ms, ctypes.c_uint32(-1).value),
        ("listener_setup_ms", listener_setup_ms, ctypes.c_uint32(-1).value),
        ("settle_ms", settle_ms, ctypes.c_uint32(-1).value),
    )
    for name, value, maximum in fields:
        if (
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
            or value > maximum
        ):
            raise GlowcapError(
                _c.ERR_INVALID_ARGUMENT,
                f"{name} must be an unsigned integer representable by the C field",
            )
    return _DriverOptions(
        _c.DRIVER_OPTIONS_ABI_VERSION,
        ctypes.sizeof(_DriverOptions),
        wire_buffer_bytes,
        max_pending_opens,
        handshake_ms,
        listener_setup_ms,
        settle_ms,
    )
