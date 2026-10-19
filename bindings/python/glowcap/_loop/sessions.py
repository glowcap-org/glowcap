"""Internal driver-loop sessions owner."""

from __future__ import annotations

import asyncio
import ctypes
from typing import TYPE_CHECKING, Optional, Union, cast

if TYPE_CHECKING:
    from .._host import Host
    from . import DriverLoop

from .. import _constants as _c
from .._errors import GlowcapError
from .._driver.transport import _LoopTransport
from .._ffi_driver import _driver
from .._ffi_host import _CloseOptions
from .._lifecycle import _lifecycle_closed
from .._locator import Locator

from .errors import _check
from .state import DriverLoopMixinBase


class _SessionsMixin(DriverLoopMixinBase):
    _wrapper: "Optional[Host]"

    async def connect_session(
        self,
        locator: Union[Locator, str],
    ):
        """Dial through the loop and wrap the opened session as the public
        :class:`glowcap.Session`, over the adopted wrapper Host: every session
        verb, promise, and trampoline works on it, with the driver loop as
        the transport and the drain."""
        ptr = await self.dial(locator)
        return self.adopt_session(ptr)

    def adopt_session(self, ptr: int):
        """Transfer one event-delivered FFI handle into a Session wrapper."""
        from .._session import Session

        host = self.wrapper_host()
        existing = host.get_session(ptr)
        if existing is not None:
            return existing
        closed, failure = self._unclaimed_sessions.get(ptr, (False, None))
        transport = _LoopTransport(cast("DriverLoop", self), ptr)
        session = Session(ctypes.c_void_p(ptr), host, transport)
        self._unclaimed_sessions.pop(ptr, None)
        if closed:
            if failure is None:
                transport.mark_closed()
            else:
                transport.mark_failed(failure)
            session.close_transport()
        return session

    def wrapper_host(self) -> "Host":
        """The public :class:`glowcap.Host` wrapper adopted over this loop's
        FFI host (ADR-0024): application verbs, publish trampolines, and
        ``RemotePromise`` settles all work on it, while the loop stays the one
        action drain and the one release authority. Built on first call. Call
        it on the driving thread."""
        if self._wrapper is None:
            from .._host import Host

            assert self._seed_material is not None
            self._wrapper = Host(
                seed=self._seed_material[:32],
                codec=self._codec,
                _adopt_raw=self.host.value,
                _driver_loop=cast("DriverLoop", self),
                context=self._release_owner.context,
            )
        return self._wrapper

    def session_release(self, session: int) -> None:
        """Release one loop-owned session: the loop spelling of
        ``glowcap_host_session_release``, which must not be called on
        sessions this loop minted."""
        _check(
            _driver.glowcap_driver_session_release(self._h, ctypes.c_void_p(session))
        )

    def claim_reference_exporter(self, reference) -> Optional[int]:
        """Resolve and claim the exporter session named by one Host capability."""
        out = ctypes.c_void_p()
        _check(
            _driver.glowcap_driver_claim_reference_exporter(
                self._h,
                ctypes.byref(reference),
                ctypes.byref(out),
            )
        )
        return out.value

    async def close_session(
        self, session: ctypes.c_void_p, options: _CloseOptions
    ) -> None:
        """Close one loop-owned session through the FFI completion barrier."""
        aio = self._started_loop()
        key = session.value
        if key is None:
            return
        future = self._session_closes.get(key)
        created = future is None
        if future is None:
            future = aio.create_future()
            self._session_closes[key] = future
        try:
            _check(
                _driver.glowcap_driver_session_close(
                    self._h,
                    session,
                    ctypes.byref(options),
                )
            )
        except BaseException:
            if created:
                self._session_closes.pop(key, None)
                future.cancel()
            raise
        # The close call escalates pending-work policy and may install a new
        # finite deadline while a close driver (this session's or the loop's)
        # is already parked; wake it so it re-reads the wait budget.
        self._signal_loop_activity()
        self._finish_session_close(key)
        if created and self._session_closes.get(key) is future:
            task = aio.create_task(self._drive_session_close(key, future))
            self._session_close_tasks.add(task)
            task.add_done_callback(self._session_close_tasks.discard)
        await asyncio.shield(future)

    async def _drive_session_close(
        self, session: int, future: "asyncio.Future[None]"
    ) -> None:
        """The deadline-stepper behind one session's FFI close barrier: a
        grace expiry takes effect only inside a step, so this driver steps on
        every loop-activity or deadline wake until the session's lifecycle
        turns terminal. Escalating repeats of :meth:`close_session` share
        it."""
        try:
            while not self._released and self._session_closes.get(session) is future:
                # Arm before stepping (the lost-wakeup discipline); loop-wide
                # activity or another owner's deadline waking this driver
                # early is harmless because it re-checks.
                self._arm_loop_activity()
                self.step_now()
                self._finish_session_close(session)
                if self._session_closes.get(session) is not future:
                    break
                await self._wait_step_wake()
        except BaseException as error:
            self._fail_background(error)

    def _finish_session_close(self, session: int) -> None:
        future = self._session_closes.get(session)
        if future is None:
            return
        state = ctypes.c_uint32()
        rc = _driver.glowcap_driver_session_lifecycle_state(
            self._h,
            ctypes.c_void_p(session),
            ctypes.byref(state),
        )
        if rc not in (_c.OK, _c.ERR_TIMEOUT):
            self._session_closes.pop(session, None)
            future.set_exception(GlowcapError(rc, "FFI session close failed"))
            return
        if not _lifecycle_closed(state.value):
            return
        self._session_closes.pop(session, None)
        if rc == _c.ERR_TIMEOUT:
            future.set_exception(
                GlowcapError(_c.ERR_TIMEOUT, "finish close exhausted its grace period")
            )
        else:
            future.set_result(None)
