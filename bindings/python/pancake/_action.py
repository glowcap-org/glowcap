"""Internal: host-action execute — the embedder-contract switch the CapTP
host drain runs.

:class:`~pancake._host.Host` owns park/kick/vows and the Session registry;
decode/types come from the generated ``_host_action_gen`` module
(``zig build gen-binding-host-action``); this module owns the shared C drain
(``pancake_host_pump_drain``) with sync park-only hooks, then runs each parked
arm (dial, flush, close, gift-id entropy, settle, fail) after the C loop
returns — so async I/O never runs inside the C callback.
"""

from __future__ import annotations

import ctypes
import secrets

from . import _constants as _abi
from ._errors import PancakeError, VowBroken, _check_host
from ._ffi_host import _HostPumpArmFn, _HostPumpHooks, _host
from ._ffi_ocapn import _byte_buf
from ._host_action_gen import (
    Close,
    Dial,
    Fail,
    Flush,
    HostAction,
    NeedGiftId,
    Settle,
    decode,
    dispatch,
)

_OK = _abi.OK
_ERR_CLOSED = _abi.ERR_CLOSED


def _park_actions(host) -> list[HostAction]:
    """Run ``pancake_host_pump_drain`` with park-only arms; return decoded
    actions in queue order. Views are copied inside ``decode`` before the
    next pop frees them."""
    parked: list[HostAction] = []

    @_HostPumpArmFn
    def park(_ctx, _host_ptr, action, out_progressed) -> int:
        parked.append(decode(action.contents))
        if out_progressed:
            out_progressed[0] = 1
        return _OK

    # Keep the callback + hooks alive for the duration of the C call via
    # locals (do not stash on Host private fields).
    hooks = _HostPumpHooks(None, park, park, park, park, park)
    acted = ctypes.c_uint32(0)
    _check_host(_host.pancake_host_pump_drain(
        host.raw, ctypes.byref(hooks), ctypes.byref(acted),
    ))
    return parked


async def _run_action(host, action: HostAction) -> None:
    # The executor is deliberately dumb: every decision was already made in
    # the core; each arm is pure I/O or marshalling. The kind inventory lives
    # in generated `dispatch` — a seventh kind fails generate/check.
    from ._dial import run_dial_ticket

    class _Handlers:
        async def dial(self, a: Dial) -> None:
            await run_dial_ticket(host, a.ticket)

        async def flush(self, a: Flush) -> None:
            conn = host.get_session(a.conn_ptr)
            if conn is not None:
                await conn.flush_outbound()

        async def close(self, a: Close) -> None:
            conn = host.get_session(a.conn_ptr)
            if conn is not None:
                try:
                    await conn.flush_outbound()
                except Exception:  # noqa: BLE001 — the session is ending either way
                    pass
                conn.close_transport()

        async def need_gift_id(self, a: NeedGiftId) -> None:
            gift_id = secrets.token_bytes(32)
            buf, ptr = _byte_buf(gift_id)
            _check_host(_host.pancake_host_provide_gift_id(
                host.raw, a.ticket, ptr, 32,
            ))

        async def settle(self, a: Settle) -> None:
            host.settle_vow(a.ticket, True, a.value)

        async def fail(self, a: Fail) -> None:
            error = (
                PancakeError(_ERR_CLOSED, a.message)
                if host.vow_session_closing(a.ticket) else VowBroken(a.message)
            )
            host.settle_vow(a.ticket, False, error)

    await dispatch(action, _Handlers())
