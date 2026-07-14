"""Internal: host-action execute — the embedder-contract switch the CapTP
host drain runs.

:class:`~pancake._host.Host` owns park/kick/vows and the Session registry;
decode/types come from the generated ``_host_action_gen`` module
(``zig build gen-binding-host-action``); this module owns pop + run
(``pancake_host_next_action`` and each I/O arm: dial, flush, close, gift-id
entropy, settle, fail).
"""

from __future__ import annotations

import ctypes
import secrets
from typing import Optional

from . import _constants as _abi
from ._errors import PancakeError, VowBroken, _check_host
from ._ffi_driver import _host
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
)

_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED


def _pop_action(host) -> Optional[HostAction]:
    # Pop the next embedder action, its borrowed views copied into Python
    # values — a SETTLE's PancakeArgument lifted whole — before anything
    # else can call `pancake_host_next_action` (which frees them), and
    # before the drain's first await. None when the queue is dry.
    a = host.action_scratch
    rc = _host.pancake_host_next_action(host.raw, ctypes.byref(a))
    if rc == _WOULD_BLOCK:
        return None
    _check_host(rc)
    return decode(a)


async def _run_action(host, action: HostAction) -> None:
    # The executor is deliberately dumb: every decision was already made in
    # the core; each arm is pure I/O or marshalling. Dial lives in `_dial`;
    # import at call time to keep the module-load edge acyclic.
    from ._dial import dial_exporter

    match action:
        case Dial(
            ticket=ticket,
            transport=transport,
            designator=designator,
            direct_addresses_hint=hint,
        ):
            try:
                conn = await dial_exporter(
                    transport, designator, hint, host,
                )
            except Exception as error:  # noqa: BLE001 — a failed dial breaks the redeems
                reason = (str(error) or type(error).__name__).encode()
                buf, ptr = _byte_buf(reason)
                _check_host(_host.pancake_host_dial_failed(
                    host.raw, ticket, ptr, len(reason),
                ))
                return
            conn.host_dialed = True
            # Keep the exporter connection pumped: the withdraw's resolution —
            # and any later routed traffic — rides it immediately.
            conn.serve()
            _check_host(_host.pancake_host_dialed(host.raw, ticket, conn.raw))
        case Flush(conn_ptr=conn_ptr):
            conn = host.get_session(conn_ptr)
            if conn is not None:
                await conn.flush_outbound()
        case Close(conn_ptr=conn_ptr):
            # The host condemned the connection mid-pump (local turn budget
            # exceeded): write its queued resource_exhausted abort, then close
            # the transport and release the conn shell.
            conn = host.get_session(conn_ptr)
            if conn is not None:
                try:
                    await conn.flush_outbound()
                except Exception:  # noqa: BLE001 — the session is ending either way
                    pass
                conn.close_transport()
        case NeedGiftId(ticket=ticket):
            # Entropy is a host effect, drawn only when a reply actually
            # becomes a gift.
            gift_id = secrets.token_bytes(32)
            buf, ptr = _byte_buf(gift_id)
            _check_host(_host.pancake_host_provide_gift_id(
                host.raw, ticket, ptr, 32,
            ))
        case Settle(ticket=ticket, value=value):
            host.settle_vow(ticket, True, value)
        case Fail(ticket=ticket, message=message):
            # A FAIL fired by the disconnect's own break (the connection is
            # closing) classifies as the typed ERR_CLOSED, not a partner break.
            error = (
                PancakeError(_ERR_CLOSED, message)
                if host.vow_session_closing(ticket) else VowBroken(message)
            )
            host.settle_vow(ticket, False, error)
        case _:
            raise RuntimeError(f"unknown host action: {action!r}")
