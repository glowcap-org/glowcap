"""Internal driver-loop listeners owner."""

from __future__ import annotations

import asyncio
import ctypes
from typing import TYPE_CHECKING, Optional, Union, cast

from .. import _constants as _c
from .._errors import GlowcapError
from .._driver_failure import _close_listener
from .._listener import ListenerLike, ListenerOwner
from .._ffi_driver import _driver
from .._locator import _OwnedLocator, Locator, parse_locator

from .errors import _check
from .state import DriverLoopMixinBase

if TYPE_CHECKING:
    from . import DriverLoop


# Wakes every parked accept when its listener or the whole loop closes.
_ACCEPTS_CLOSED = object()


class _ListenersMixin(DriverLoopMixinBase):
    async def accept(self, listener: int) -> int:
        """Await the next accepted session handle (bind a listener first).
        Raises the typed ``ERR_CLOSED`` once the loop closes, so a server
        iteration ends rather than parking forever."""
        ready = self._take_accept_nowait(listener)
        if ready is not None:
            return ready
        accepts = self._accepts.get(listener)
        if accepts is None:
            raise GlowcapError(_c.ERR_CLOSED, "the listener is closed")
        if self._released:
            raise GlowcapError(_c.ERR_CLOSED, "the loop is closed")
        item = await accepts.get()
        if isinstance(item, GlowcapError):
            accepts.put_nowait(item)
            raise item
        if not isinstance(item, int):
            # The close sentinel: re-arm it so every sibling accept ends too.
            accepts.put_nowait(_ACCEPTS_CLOSED)
            raise GlowcapError(_c.ERR_CLOSED, "the loop is closed")
        return item

    def _take_accept_nowait(self, listener: int) -> Optional[int]:
        accepts = self._accepts.get(listener)
        if accepts is None:
            raise GlowcapError(_c.ERR_CLOSED, "the listener is closed")
        if self._released:
            raise GlowcapError(_c.ERR_CLOSED, "the loop is closed")
        try:
            item = accepts.get_nowait()
        except asyncio.QueueEmpty:
            return None
        if isinstance(item, GlowcapError):
            accepts.put_nowait(item)
            raise item
        if not isinstance(item, int):
            accepts.put_nowait(_ACCEPTS_CLOSED)
            raise GlowcapError(_c.ERR_CLOSED, "the loop is closed")
        return item

    def try_accept(self, listener: ListenerLike) -> Optional[int]:
        """Claim one already-dispatched accepted handle without parking.

        This is the accept face for callers that drive :meth:`step` from a
        plain thread. ``None`` means another step or partner is needed.
        """
        return self._take_accept_nowait(self._listener_id(listener))

    def listen(
        self, transport: Union[str, bytes], designator: Union[str, bytes]
    ) -> "ListenerOwner":
        transport_b = transport.encode() if isinstance(transport, str) else transport
        designator_b = (
            designator.encode() if isinstance(designator, str) else designator
        )
        listener = ctypes.c_uint64(0)
        _check(
            _driver.glowcap_driver_listen(
                self._h,
                transport_b,
                len(transport_b),
                designator_b,
                len(designator_b),
                None,
                ctypes.byref(listener),
            )
        )
        owner = ListenerOwner(cast("DriverLoop", self), listener.value)
        self._listeners[listener.value] = owner
        self._accepts[listener.value] = asyncio.Queue()
        return owner

    def _listener_id(self, listener: ListenerLike) -> int:
        return listener.listener if isinstance(listener, ListenerOwner) else listener

    def listener_locator(self, listener: ListenerLike) -> Locator:
        """Copy the listener's complete typed OCapN locator."""
        listener = self._listener_id(listener)
        from .._ffi_ocapn import _LocatorView

        view = _LocatorView()
        _check(
            _driver.glowcap_driver_listener_locator(
                self._h, listener, ctypes.byref(view)
            )
        )
        with _OwnedLocator.clone_view(
            ctypes.cast(ctypes.byref(view), ctypes.c_void_p)
        ) as owned:
            return owned.value()

    def listener_restoration_state(self, listener: ListenerLike) -> bytes:
        """Copy opaque provider state used to restore a listener's local address.

        The driver owns the provider state and exposes only its size/copy ABI.
        This binding keeps the result as bytes and does not interpret transport
        vocabulary. A provider that has no restoration state raises its driver
        error instead of manufacturing one from the public locator.
        """
        listener = self._listener_id(listener)
        needed = ctypes.c_size_t()
        rc = _driver.glowcap_driver_listener_restoration_state(
            self._h, listener, None, 0, ctypes.byref(needed)
        )
        if rc not in (_c.OK, _c.ERR_BUFFER_TOO_SMALL):
            _check(rc)
        if needed.value == 0:
            return b""
        buffer = (ctypes.c_uint8 * needed.value)()
        copied = ctypes.c_size_t()
        _check(
            _driver.glowcap_driver_listener_restoration_state(
                self._h,
                listener,
                ctypes.cast(buffer, ctypes.c_void_p),
                needed.value,
                ctypes.byref(copied),
            )
        )
        if copied.value != needed.value:
            raise GlowcapError(
                _c.ERR_INTERNAL,
                "driver listener restoration state changed during copy",
            )
        return bytes(buffer)

    def advertise_listener(
        self, listener: ListenerLike, locator: Union[Locator, str]
    ) -> None:
        """Replace this listener's advertised locator through its native owner."""
        listener = self._listener_id(listener)
        parsed = parse_locator(locator) if isinstance(locator, str) else locator
        with _OwnedLocator.create(parsed) as owned:
            _check(
                _driver.glowcap_driver_listener_advertise(
                    self._h, listener, owned.borrow_view()
                )
            )

    def select_listener(self, listener: ListenerLike) -> None:
        """Select this listener's locator as the Host's acceptable location."""
        _check(
            _driver.glowcap_driver_listener_select(self._h, self._listener_id(listener))
        )

    def close_listener(self, listener: ListenerLike) -> None:
        """Commit one listener stop after preserving committed accepts.

        Provider teardown may remain asynchronous. In that case loop progress
        retries the native barrier. :meth:`wait_listener_closed` observes its
        terminal result.
        """
        listener = self._listener_id(listener)
        # A terminal setup event may already be queued while the caller is
        # cancelling its waiter. Consume it before asking native code to
        # cancel; a failed setup has already retired its native identity.
        self._dispatch_many(self._pop_events())
        owner = self._listeners.get(listener)
        if owner is None:
            return
        owner._closed = True
        if listener in self._closing_listeners:
            return
        try:
            closed = _close_listener(self._h, listener)
        except GlowcapError as error:
            self._finish_listener_close(listener, error)
            raise
        if closed:
            try:
                self._dispatch_many(self._pop_events())
            finally:
                self._finish_listener_close(listener)
            return
        self._closing_listeners.add(listener)
        self.schedule_step()
        self._rearm_progress_timer()

    async def wait_listener_closed(self, listener: ListenerLike) -> None:
        """Join a listener stop, including asynchronous provider teardown."""
        listener = self._listener_id(listener)
        self.close_listener(listener)
        if listener not in self._listeners and listener not in self._closing_listeners:
            return
        waiter = self._listener_close_waiters.get(listener)
        if waiter is None:
            waiter = self._started_loop().create_future()
            self._listener_close_waiters[listener] = waiter
        # The listener teardown belongs to the loop, not to any one waiter.
        # Caller cancellation abandons only this await; a later close can join
        # the same native barrier and observe its terminal outcome.
        await asyncio.shield(waiter)

    def _advance_closing_listeners(self) -> None:
        """Retry native listener barriers after one productive driver step."""
        for listener in tuple(self._closing_listeners):
            try:
                closed = _close_listener(self._h, listener)
            except GlowcapError as error:
                self._finish_listener_close(listener, error)
                continue
            if closed:
                self._finish_listener_close(listener)

    def _finish_listener_close(
        self, listener: int, failure: Optional[GlowcapError] = None
    ) -> None:
        """Retire every binding-owned row for one terminal listener."""
        owner = self._listeners.pop(listener, None)
        self._closing_listeners.discard(listener)
        if owner is not None:
            if failure is not None:
                owner._mark_failed(failure)
            else:
                owner._closed = True
        waiter = self._listener_waiters.pop(listener, None)
        if waiter is not None and not waiter.done():
            if failure is not None:
                waiter.set_exception(failure)
            else:
                waiter.cancel()
        accepts = self._accepts.get(listener)
        if accepts is not None:
            self._release_unclaimed(listener)
            accepts.put_nowait(failure if failure is not None else _ACCEPTS_CLOSED)
            del self._accepts[listener]
        close_waiter = self._listener_close_waiters.pop(listener, None)
        if close_waiter is not None and not close_waiter.done():
            if failure is None:
                close_waiter.set_result(None)
            else:
                close_waiter.set_exception(failure)

    async def wait_listener(self, listener: ListenerLike) -> ListenerOwner:
        """Await provider construction and return the stable listener owner.

        ``listen`` has already returned the identity before setup runs. This
        boundary is the only place high-level async constructors wait for the
        provider's READY/FAILED outcome.
        """
        aio = self._started_loop()
        owner = (
            listener
            if isinstance(listener, ListenerOwner)
            else self._listeners.get(listener)
        )
        if owner is None:
            raise GlowcapError(_c.ERR_CLOSED, "the listener is closed")
        if owner.failure is not None:
            raise owner.failure
        if owner.ready:
            return owner
        if owner._closed:
            raise GlowcapError(_c.ERR_CLOSED, "the listener is closed")
        waiter = self._listener_waiters.get(owner.listener)
        if waiter is None:
            waiter = aio.create_future()
            self._listener_waiters[owner.listener] = waiter
        self.schedule_step()
        self._rearm_progress_timer()
        try:
            await waiter
        except asyncio.CancelledError:
            self.close_listener(owner)
            raise
        if owner.failure is not None:
            raise owner.failure
        if not owner.ready:
            raise GlowcapError(
                _c.ERR_INTERNAL,
                "listener became ready without a READY event",
            )
        return owner

    def _release_unclaimed(self, listener: int) -> None:
        accepts = self._accepts.get(listener)
        if accepts is None:
            return
        while True:
            try:
                item = accepts.get_nowait()
            except asyncio.QueueEmpty:
                return
            if isinstance(item, int):
                self._native_session_release(ctypes.c_void_p(item))

    def completion(self, vow: int) -> "asyncio.Future[bool]":
        """A future settled by the vow's COMPLETION event (True on SETTLE.
        FAIL raises). Register before the next step."""
        aio = self._started_loop()
        future: asyncio.Future[bool] = aio.create_future()
        if self._terminal_failure is not None:
            future.set_exception(self._terminal_failure)
            return future
        self._completions[vow] = future
        return future

    async def accept_session(self, listener: ListenerLike):
        """Await the next accepted session, wrapped as the public
        :class:`glowcap.Session` over the adopted wrapper Host: the
        accept-side twin of :meth:`connect_session`. The handshake already
        ran inside the accepting step. The session arrives open."""
        ptr = await self.accept(self._listener_id(listener))
        return self.adopt_session(ptr)
