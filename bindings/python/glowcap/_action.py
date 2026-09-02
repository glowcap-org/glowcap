"""Internal: host-action execute — the embedder-contract switch the CapTP
host drain runs.

:class:`~glowcap._host.Host` owns park/kick/vows and the Session registry;
decode/types come from the generated ``_host_action_gen`` module
(``zig build gen-binding-host-action``); this module owns the shared C drain
(``glowcap_host_pump_drain``) with sync park-only hooks, then runs each parked
arm (dial, flush, close, gift-id entropy, settle, fail) after the C loop
returns — so async I/O never runs inside the C callback.
"""

from __future__ import annotations

import ctypes
import secrets

from . import _constants as _abi
from ._errors import _check_host, _vow_failure, GlowcapError
from ._ffi_host import _HostPumpArmFn, _HostPumpHooks, _host
from ._ffi_ocapn import _byte_buf
from ._host_action_gen import (
    Close,
    CancelDial,
    Dial,
    Fail,
    Flush,
    HostAction,
    NeedGiftId,
    Resume,
    Settle,
    decode,
    dispatch,
)

_OK = _abi.OK


def _answer_gift_id(draw, provide, failed) -> None:
    """Complete entropy failure separately from native ticket refusal."""
    try:
        gift_id = draw()
    except Exception:  # noqa: BLE001 — the core owns the failed effect
        failed()
        return
    provide(gift_id)


def _park_actions(host) -> tuple[list[HostAction], bool]:
    """Run ``glowcap_host_pump_drain`` with park-only arms; return decoded
    actions in queue order. Views are copied inside ``decode`` before the
    next pop frees them."""
    parked: list[HostAction] = []
    callback_failure: BaseException | None = None

    @_HostPumpArmFn
    def park(_ctx, _host_ptr, action, out_progressed) -> int:
        nonlocal callback_failure
        try:
            parked.append(decode(action.contents))
        except BaseException as error:
            callback_failure = error
            return _abi.ERR_INTERNAL
        if out_progressed:
            out_progressed[0] = 1
        return _OK

    # Keep the callback + hooks alive for the duration of the C call via
    # locals (do not stash on Host private fields).
    hooks = _HostPumpHooks(None, park, park, park, park, park)
    acted = ctypes.c_uint32(0)
    yielded = ctypes.c_uint32(0)
    rc = _host.glowcap_host_pump_drain(
        host.raw,
        ctypes.byref(hooks),
        ctypes.byref(acted),
        ctypes.byref(yielded),
    )
    if callback_failure is not None:
        raise GlowcapError(
            _abi.ERR_INTERNAL,
            f"glowcap ABI returned an invalid host action: {callback_failure}",
        ) from callback_failure
    _check_host(rc)
    return parked, yielded.value != 0


async def _run_action(host, action: HostAction) -> None:
    # The executor is deliberately dumb: every decision was already made in
    # the core; each arm is pure I/O or marshalling. The kind inventory lives
    # in generated `dispatch` — a new kind fails generate/check.
    class _Handlers:
        async def dial(self, a: Dial) -> None:
            # A popped DIAL is no longer owned by the native action queue. Hand
            # it to the Host before returning so teardown can cancel and join it
            # without serializing this drain behind network establishment.
            from ._dial import run_dial_ticket

            host.start_dial_task(
                a.ticket,
                a.route_index,
                lambda: run_dial_ticket(host, a.ticket, a.route_index),
            )

        async def cancel_dial(self, a: CancelDial) -> None:
            await host.cancel_dial_task(a.ticket, a.route_index)

        async def flush(self, a: Flush) -> None:
            session = host.get_session(a.session_ptr)
            if session is not None:
                try:
                    await session.flush_outbound()
                except BaseException:
                    # Session.flush_outbound retained the exact first cause and
                    # retired this stream. Do not fail an unrelated Host drain.
                    pass

        async def close(self, a: Close) -> None:
            session = host.get_session(a.session_ptr)
            if session is not None:
                try:
                    await session.flush_outbound()
                except Exception:  # noqa: BLE001 — the session is ending either way
                    # Session.flush_outbound owns terminal failure state.
                    pass
                session.close_transport()
                session._finish_close(a.result)

        async def need_gift_id(self, a: NeedGiftId) -> None:
            def provide(gift_id: bytes) -> None:
                buf, ptr = _byte_buf(gift_id)
                _check_host(
                    _host.glowcap_host_provide_gift_id(
                        host.raw,
                        a.ticket,
                        ptr,
                        32,
                    )
                )

            _answer_gift_id(
                lambda: secrets.token_bytes(32),
                provide,
                lambda: _check_host(
                    _host.glowcap_host_gift_id_failed(host.raw, a.ticket)
                ),
            )

        async def settle(self, a: Settle) -> None:
            host.settle_vow(a.ticket, True, a.value)

        async def fail(self, a: Fail) -> None:
            host.settle_vow(a.ticket, False, _vow_failure(a.result, a.message))

        async def resume(self, a: Resume) -> None:
            # The shared C pump reports this as `yielded` before dispatch; keep
            # the exhaustive generated handler honest for direct callers.
            _ = a

    await dispatch(action, _Handlers())
