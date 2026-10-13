"""Internal: the asyncio face of the driver archive (ADR-0112).

One thread drives one native loop and drains its events into asyncio futures.
The loop owns provider packages and adopts a real ``GlowcapHost`` handle, so
sessions opened by native transports use the same ``glowcap_host_*`` verbs as
byte-fed Hosts.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
from typing import TYPE_CHECKING, Optional, Union

if TYPE_CHECKING:
    from .._host import Host

from .. import _constants as _c
from .._abi_value import _DEFAULT_CODEC, _codec_id
from .._errors import (
    _check_host,
    _retain_cleanup_failure,
    GlowcapError,
)
from .._driver_failure import _add_provider
from .._driver.release import _DriverReleaseOwner
from .._driver_event import LoopEvent as LoopEvent
from .._listener import ListenerOwner
from .._ffi_driver import _driver, _TransportProvider
from .._ffi_host import _host
from .._locator import Locator
from .._trampoline import _enter_host_deliver, _exit_deliver

from .configuration import _driver_options
from .dialing import _DialingMixin
from .errors import _as_driver_error, _check
from .lifecycle import _LifecycleMixin
from .listeners import _ListenersMixin
from .progress import _ProgressMixin
from .sessions import _SessionsMixin


class DriverLoop(
    _LifecycleMixin, _SessionsMixin, _ProgressMixin, _DialingMixin, _ListenersMixin
):
    """One stepping native loop over one multi-session host.

    Construct with :meth:`open` on the asyncio thread that will drive it,
    ``start()`` to park on the readiness descriptor, and ``close()`` before
    dropping it. ``host`` is a real ``GlowcapHost`` handle
    for every application verb.
    """

    def __init__(self, handle: int, host: int, context=None) -> None:
        self._h = ctypes.c_void_p(handle)
        self._host = ctypes.c_void_p(host)
        self._aio: Optional[asyncio.AbstractEventLoop] = None
        self._fd: Optional[int] = None
        self._stepping = False
        self._pending_dials: dict[int, asyncio.Future[int]] = {}
        self._progress_timer: Optional[asyncio.TimerHandle] = None
        self._completions: dict[int, asyncio.Future[bool]] = {}
        self._accepts: "dict[int, asyncio.Queue[Union[int, object]]]" = {}
        self._listeners: dict[int, ListenerOwner] = {}
        self._listener_waiters: dict[int, asyncio.Future[None]] = {}
        self._closing_listeners: set[int] = set()
        self._listener_close_waiters: dict[int, asyncio.Future[None]] = {}
        # Event-delivered handles not yet wrapped. The pair preserves both
        # terminal state and its exact failure when SESSION_CLOSED follows an
        # OPENED/ACCEPTED event in the same drain.
        self._unclaimed_sessions: dict[int, tuple[bool, Optional[GlowcapError]]] = {}
        self._session_closes: dict[int, asyncio.Future[None]] = {}
        self._wrapper: "Optional[Host]" = None
        self._seed_material: Optional[bytes] = None
        self._codec = _DEFAULT_CODEC
        self._released = False
        self._release_attempted = False
        self._terminal_failure: "Optional[GlowcapError]" = None
        self._terminal_failures: "list[BaseException]" = []
        self._terminal_failure_count = 0
        self._closing = False
        self._close_task: "Optional[asyncio.Task[None]]" = None
        self._close_error: "Optional[BaseException]" = None
        self._started = False
        self._closed_event = asyncio.Event()
        # The shared loop-activity notifier (wake-all): a close driver clears
        # it before stepping, and every path that steps the loop or drains its
        # events sets it after running work. Mirrors the byte-fed Host tier's
        # close-activity event one tier down.
        self._loop_activity = asyncio.Event()
        # Session close drivers, retained strongly for their lifetime because
        # asyncio holds tasks weakly.
        self._session_close_tasks: set["asyncio.Task[None]"] = set()
        self._release_owner = _DriverReleaseOwner(self, handle, context)

    def _adopt_host_finalizer_state(self, state) -> None:
        """Transfer detached Host bookkeeping to this loop's raw finalizer."""
        try:
            self._release_owner.adopt_host_state(state)
        except RuntimeError as error:
            raise GlowcapError(_c.ERR_INVALID_ARGUMENT, str(error)) from error

    # ── Lifecycle ────────────────────────────────────────────────────────────

    @classmethod
    def open(
        cls,
        seed: Optional[bytes] = None,
        *,
        codec: str = _DEFAULT_CODEC,
        frame_cap: int = _c.DEFAULT_FRAME_CAP,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        listener_setup_ms: int = _c.DRIVER_DEFAULT_LISTENER_SETUP_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Create the loop. ``seed`` is the host constructor's 64-byte
        contract (durable identity, then a fresh session-key root). ``None``
        draws both halves fresh."""
        options = _driver_options(
            wire_buffer_bytes,
            max_pending_opens,
            handshake_ms,
            listener_setup_ms,
            settle_ms,
        )
        material = seed if seed is not None else secrets.token_bytes(64)
        if len(material) != 64:
            raise GlowcapError(_c.ERR_INVALID_ARGUMENT, "seed must be 64 bytes")
        from .._context import Context

        context = Context()
        context_raw = context._acquire_handle()
        host = ctypes.c_void_p(None)
        try:
            _check_host(
                _host.glowcap_host_new_in(
                    context_raw,
                    material,
                    len(material),
                    frame_cap,
                    1,
                    _codec_id(codec),
                    _c.DEFAULT_CAPTP_VERSION,
                    _c.DEFAULT_FEATURES,
                    0,
                    0,
                    ctypes.byref(host),
                )
            )
        except BaseException:
            context._release_handle()
            raise
        assert host.value is not None
        slot = ctypes.c_void_p(None)
        try:
            _check(
                _driver.glowcap_driver_take_host(
                    host,
                    ctypes.byref(options),
                    ctypes.byref(slot),
                )
            )
        except BaseException as primary:
            from .._host import _release_unpublished_host

            cleanup = _release_unpublished_host(host, context)
            if cleanup is not None:
                _retain_cleanup_failure(primary, cleanup)
            raise
        assert slot.value is not None
        loop = cls(slot.value, host.value, context)
        loop._seed_material = material
        loop._codec = codec
        return loop

    @classmethod
    def take_host(
        cls,
        host: "Host",
        *,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        listener_setup_ms: int = _c.DRIVER_DEFAULT_LISTENER_SETUP_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Transfer a byte-fed Host into a native driver transactionally.

        ``glowcap_driver_take_host`` is called before the Python Host changes
        state. On failure the caller still owns the original Host. On success
        this exact Host wrapper becomes the loop's application face and the
        loop becomes its sole native release authority.
        """
        if host.driver_loop is not None:
            raise GlowcapError(
                _c.ERR_INVALID_ARGUMENT, "host already belongs to a driver loop"
            )
        raw = host.raw
        options = _driver_options(
            wire_buffer_bytes,
            max_pending_opens,
            handshake_ms,
            listener_setup_ms,
            settle_ms,
        )
        out = ctypes.c_void_p(None)
        _check(
            _driver.glowcap_driver_take_host(
                raw,
                ctypes.byref(options),
                ctypes.byref(out),
            )
        )
        assert out.value is not None
        assert raw.value is not None
        loop = cls(out.value, raw.value)
        loop._codec = host.codec
        loop._wrapper = host
        loop._adopt_host_finalizer_state(host._adopt_driver_loop(loop))
        return loop

    @property
    def host(self) -> ctypes.c_void_p:
        """The wrapped ``GlowcapHost`` handle for ``glowcap_host_*`` verbs.
        Never release it separately. ``close`` releases the loop and the
        host together."""
        return self._host

    def schedule_step(self) -> None:
        """Schedule one loop step soon, from the driving thread: how a
        wrapper verb's kick reaches the drain. A thread-driven loop (no
        :meth:`start`) pumps continuously and needs no nudge."""
        if self._released or self._terminal_failure is not None:
            return
        if self._aio is not None:
            try:
                self._aio.call_soon(self._step_background)
            except BaseException as error:
                self._fail_background(error)
                failure = self._terminal_failure
                assert failure is not None
                raise failure from error

    def _step_background(self) -> None:
        """Drive one scheduled step and terminalize any uncaught failure."""
        try:
            self.step_now()
        except BaseException as error:
            self._fail_background(error)

    def _fail_background(self, error: BaseException) -> None:
        """Complete every binding waiter before releasing a failed loop."""
        if self._terminal_failure is not None:
            self._record_terminal_failure(error)
            return
        failure = _as_driver_error(error)
        self._terminal_failure = failure
        self._close_error = failure
        self._record_terminal_failure(failure)
        if self._aio is not None and self._fd is not None:
            self._aio.remove_reader(self._fd)
        if self._progress_timer is not None:
            self._progress_timer.cancel()
            self._progress_timer = None
        for dial_future in self._pending_dials.values():
            if not dial_future.done():
                dial_future.set_exception(failure)
        self._pending_dials.clear()
        for listener_future in self._listener_waiters.values():
            if not listener_future.done():
                listener_future.set_exception(failure)
        self._listener_waiters.clear()
        for close_future in self._listener_close_waiters.values():
            if not close_future.done():
                close_future.set_exception(failure)
        self._listener_close_waiters.clear()
        self._closing_listeners.clear()
        for completion_future in self._completions.values():
            if not completion_future.done():
                completion_future.set_exception(failure)
        self._completions.clear()
        for close_future in self._session_closes.values():
            if not close_future.done():
                close_future.set_exception(failure)
        self._session_closes.clear()
        for owner in self._listeners.values():
            owner._mark_failed(failure)
        for accepts in self._accepts.values():
            accepts.put_nowait(failure)
        self._listeners.clear()
        self._unclaimed_sessions.clear()
        if self._wrapper is not None:
            self._wrapper._driver_failed(failure)
        if self._release_attempted:
            self._closed_event.set()
            return
        self._release_attempted = True
        release_attempt = self._release_owner.release(
            "driver-loop.background.release", self._retire_native_release
        )
        if release_attempt.error is not None and not release_attempt.consumed:
            release_error = release_attempt.error
            self._record_terminal_failure(release_error)
        self._closed_event.set()

    def serve_session(self, ptr: int):
        """Announce the embedder is serving the session at ``ptr``: post-open
        setup is done, so the loop may deliver its inbound (bytes that arrived
        early replay in order). Idempotent. The loop tier's spelling of the
        byte-fed rule that ``serve`` resumes frames held behind the
        handshake. Returns the registered public Session wrapper."""
        if self._terminal_failure is not None:
            raise self._terminal_failure
        if self._released or not ptr:
            return None
        session = self.adopt_session(ptr)
        # Serving releases application frames parked behind the handshake and
        # may invoke a hosted behavior before the native call returns.
        prior = _enter_host_deliver(self._wrapper)
        try:
            _check(_driver.glowcap_driver_session_serve(self._h, ctypes.c_void_p(ptr)))
        finally:
            _exit_deliver(prior)
        self.schedule_step()
        return session

    # ── Extension transports ────────────────────────────────────────────────

    def _install_provider(self, prepare) -> None:
        """Install one package while its archive-owned construction owner is live.

        ``prepare`` receives a registrar valid only for the dynamic extent of
        this call, so copied callback tables cannot escape independently of
        the object they borrow.
        """
        registered = False
        active = True

        def register(package: _TransportProvider) -> None:
            nonlocal registered
            if not active or registered:
                raise RuntimeError("provider registrar is no longer active")
            _add_provider(_driver, self._h, package)
            registered = True

        try:
            prepare(register)
            if not registered:
                raise RuntimeError("provider installer did not register a package")
        finally:
            active = False

    def _has_transport(self, transport: Union[str, bytes]) -> bool:
        """Ask the native provider registry whether ``transport`` is owned."""
        name = transport.encode() if isinstance(transport, str) else transport
        present = ctypes.c_uint8(0)
        _check(
            _driver.glowcap_driver_has_transport(
                self._h, name, len(name), ctypes.byref(present)
            )
        )
        return present.value != 0

    # ── Parking and stepping ─────────────────────────────────────────────────

    # ── Dial, accept, listen ─────────────────────────────────────────────────

    # ── Vows ─────────────────────────────────────────────────────────────────


async def dial_shared_loop(
    driver_loop: "DriverLoop",
    locator: Locator,
):
    """Begin one dial through an already-composed provider package."""
    return await driver_loop.connect_session(locator)
