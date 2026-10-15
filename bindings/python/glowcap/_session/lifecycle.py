"""Session byte-pump and terminal-lifecycle ownership.

The public :class:`Session` owns the fields. This leaf owns every transition
from a live byte channel to one published terminal outcome. It has no
initializer or finalizer: construction belongs to the package root,
and explicit close remains the only release policy.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import TYPE_CHECKING, Any, Awaitable, Optional, cast

from .. import _constants as _abi
from .. import _pump
from .._errors import AbortDetail, GlowcapError, _check_host, _retain_terminal_failure
from .._ffi_host import _host
from .._lifecycle import PendingWork, _UNSET, _close_options, _lifecycle_closed, _monotonic_ms
from .._trampoline import _inside_turn

if TYPE_CHECKING:
    from .._host import Host
    from . import Session


class _LifecycleMixin:
    """One close coordinator and the byte-pump operations it retires."""

    if TYPE_CHECKING:
        _host: Host
        _transport: Any
        _ptr: ctypes.c_void_p | None
        _key: int
        _serve_task: Optional[asyncio.Task]
        _closing: bool
        _released: bool
        _release_pending: bool
        _close_future: Optional[asyncio.Future[None]]
        _wire_failure: Optional[BaseException]
        _terminal_failures: list[BaseException]
        _terminal_failure_count: int
        _terminal_task: Optional[asyncio.Task[None]]
        _loop_close_tasks: set[asyncio.Task[None]]
        _close_request_signature: Optional[tuple[int, int, int]]
        _transport_lost: bool
        _transport_close_started: bool
        _close_task: Optional[asyncio.Task[None]]
        _retirement: asyncio.Event

    # ── The pump ────────────────────────────────────────────────────────────

    def serve(self) -> "asyncio.Task":
        """Run the inbound loop as a background task, started once.

        A loop-backed session has no byte pump of its own: the driver loop
        reads, feeds, and drains, so its serve task only awaits closure.
        """
        self._host._assert_owner()
        if self._serve_task is None:
            transport = self._transport
            if getattr(transport, "_driver_loop", None) is not None:
                transport._driver_loop.serve_session(self._key)
                self._serve_task = asyncio.get_running_loop().create_task(
                    transport.wait_closed(),
                )
            else:
                self._serve_task = asyncio.get_running_loop().create_task(
                    _pump._serve_loop(self),
                )
        return self._serve_task

    def _publish_retirement(self) -> None:
        retirement = getattr(self, "_retirement", None)
        if retirement is None:
            retirement = asyncio.Event()
            self._retirement = retirement
        retirement.set()

    async def closed(self) -> None:
        """Observe terminal session retirement without requesting close or
        starting inbound delivery.

        Independent and late observers share the terminal result. Cancelling
        an observer leaves the connection and its other observers live.
        ``serve`` remains the inbound loop.
        """
        self._host._assert_owner()
        if getattr(self, "_retirement", None) is None:
            self._retirement = asyncio.Event()
        await self._retirement.wait()
        terminal = self._terminal_task
        if terminal is not None:
            await asyncio.shield(terminal)
            return
        failures = self.terminal_failures
        if failures:
            raise failures[0]
        self.raise_wire_failure()

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of the most recent local dispatch failure."""
        return _pump.last_abort(self)

    async def flush_outbound(self) -> None:
        """Drain encoded frames to this session's transport, in order."""
        try:
            loop_ref = getattr(self._transport, "_driver_loop", None)
            if loop_ref is not None:
                loop_ref.step_now()
                return
            await _pump.flush_outbound(self)
        except BaseException as error:
            self.record_outbound_failure(error)
            self.close_transport()
            raise

    def record_wire_failure(self, error: BaseException) -> None:
        """Retain the exact first terminal failure. Pump-internal seam."""
        self._record_terminal_failure(error)
        if self._wire_failure is None:
            self._wire_failure = error

    def _record_terminal_failure(self, error: BaseException) -> None:
        failures = getattr(self, "_terminal_failures", None)
        if failures is None:
            failures = []
            self._terminal_failures = failures
        self._terminal_failure_count = _retain_terminal_failure(
            failures, getattr(self, "_terminal_failure_count", 0), error
        )
        self._host._track_session_retirement_failure(error)

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        """Terminal failures in observation order. The first is authoritative."""
        return tuple(getattr(self, "_terminal_failures", ()))

    @property
    def terminal_failure_count(self) -> int:
        """Total distinct terminal occurrences, including bounded overflow."""
        return getattr(self, "_terminal_failure_count", 0)

    def mark_transport_lost(self) -> None:
        """Make inbound/protocol teardown the terminal owner. Pump seam."""
        self._transport_lost = True

    def record_outbound_failure(self, error: BaseException) -> None:
        """Retain a write failure only when it precedes transport teardown."""
        if (
            not self._released
            and not self._transport_close_started
            and not self._transport_lost
        ):
            self.record_wire_failure(error)

    def raise_wire_failure(self) -> None:
        if self._wire_failure is not None:
            raise self._wire_failure

    # ── One terminal coordinator ────────────────────────────────────────────

    async def _join_terminal_child(self, awaitable: Awaitable[None]) -> None:
        """Observe one coordinator-owned child without replacing the primary."""
        try:
            await awaitable
        except BaseException as error:
            self._record_terminal_failure(error)

    async def _drain_loop_close_requests(self) -> None:
        """Join every policy escalation admitted while close was in flight."""
        while self._loop_close_tasks:
            tasks = tuple(self._loop_close_tasks)
            self._loop_close_tasks.difference_update(tasks)
            for task in tasks:
                await self._join_terminal_child(task)

    async def _coordinate_terminal(
        self, result: Optional[Awaitable[None]] = None
    ) -> None:
        """Own FFI result, physical retirement, serve join, and publication.

        This task is retained by the Session. Callers shield this one task, so
        cancelling a waiter never abandons a transport coroutine or turns that
        caller cancellation into terminal evidence.
        """
        if self._wire_failure is not None:
            self._record_terminal_failure(self._wire_failure)
        if result is not None:
            await self._join_terminal_child(result)
        await self._drain_loop_close_requests()
        if not self._released and not self._release_pending:
            self.close_transport()
        wait_closed = getattr(self._transport, "wait_closed", None)
        if wait_closed is not None:
            await self._join_terminal_child(wait_closed())
        task = self._serve_task
        if task is not None and task is not asyncio.current_task():
            await self._join_terminal_child(task)
        # A repeated loop-backed close may have escalated while the physical
        # transport or serve task was retiring. Join it before publication.
        await self._drain_loop_close_requests()
        if self._wire_failure is not None:
            self._record_terminal_failure(self._wire_failure)
        failures = self.terminal_failures
        if failures:
            raise failures[0]

    def _start_terminal_coordinator(
        self, result: Optional[Awaitable[None]] = None
    ) -> "asyncio.Task[None]":
        task = self._terminal_task
        if task is None:
            task = asyncio.get_running_loop().create_task(
                self._coordinate_terminal(result)
            )
            self._terminal_task = task
        elif result is not None:
            raise AssertionError("terminal result already has an owner")
        return task

    async def _await_terminal(self) -> None:
        task = self._terminal_task
        if task is None:
            task = self._start_terminal_coordinator()
        await asyncio.shield(task)

    def _request_loop_close(self, loop_ref, ptr, options) -> "asyncio.Task[None]":
        """Start one loop request. The coordinator retains and observes it."""
        task = asyncio.get_running_loop().create_task(
            loop_ref.close_session(ptr, options)
        )
        if self._terminal_task is not None:
            self._loop_close_tasks.add(task)
        return task

    # ── Teardown ─────────────────────────────────────────────────────────────

    async def close(
        self,
        *,
        pending: PendingWork = PendingWork.CANCEL,
        grace: object = _UNSET,
    ) -> None:
        """Close this session and join its one complete retirement outcome."""
        options = _close_options(pending, grace)
        signature = (options.pending, options.grace_mode, options.grace_ms)
        self._host._assert_owner()
        terminal = self._terminal_task
        if terminal is not None:
            if (
                not terminal.done()
                and not self._released
                and signature != getattr(self, "_close_request_signature", None)
            ):
                ptr = self._ptr
                assert ptr is not None
                loop_ref = getattr(self._transport, "_driver_loop", None)
                if loop_ref is not None:
                    self._request_loop_close(loop_ref, ptr, options)
                    self._close_request_signature = signature
                else:
                    _check_host(
                        _host.glowcap_host_session_close(
                            ptr,
                            ctypes.byref(options),
                            _monotonic_ms(),
                        )
                    )
                    self._close_request_signature = signature
                    self._closing = True
                    self._host.signal_close_activity()
                    self._start_close_driver()
                    self._host.schedule_kick()
            await asyncio.shield(terminal)
            return

        if self._released:
            self._start_terminal_coordinator()
            await self._await_terminal()
            return

        ptr = self._ptr
        assert ptr is not None
        loop_ref = getattr(self._transport, "_driver_loop", None)
        if loop_ref is not None:
            result = self._request_loop_close(loop_ref, ptr, options)
            self._close_request_signature = signature
            self._start_terminal_coordinator(result)
        else:
            close_future = asyncio.get_running_loop().create_future()
            _check_host(
                _host.glowcap_host_session_close(
                    ptr,
                    ctypes.byref(options),
                    _monotonic_ms(),
                )
            )
            self._closing = True
            self._host.signal_close_activity()
            self._close_future = close_future
            self._close_request_signature = signature
            self._start_close_driver()
            self._host.schedule_kick()
            self._start_terminal_coordinator(close_future)
        await self._await_terminal()

    def _start_close_driver(self) -> None:
        task = self._close_task
        if task is not None and not task.done():
            return
        task = asyncio.get_running_loop().create_task(self._drive_close())
        self._close_task = task

        def retire(finished: "asyncio.Task[None]") -> None:
            if self._close_task is finished:
                self._close_task = None

        task.add_done_callback(retire)

    async def _drive_close(self) -> None:
        try:
            while not self._released:
                ptr = self._ptr
                if ptr is None:
                    break
                self._host.arm_close_activity()
                state = ctypes.c_uint32()
                rc = _host.glowcap_host_session_close_progress(
                    ptr,
                    _monotonic_ms(),
                    ctypes.byref(state),
                )
                if rc not in (_abi.OK, _abi.ERR_TIMEOUT):
                    _check_host(rc)
                _lifecycle_closed(state.value)
                await self._host.kick_actions()
                if not self._released:
                    await self._host.wait_close_wake()
        except BaseException as error:
            self.close_transport()
            future = self._close_future
            if future is not None and not future.done():
                future.set_exception(error)

    def _finish_close(self, result: int) -> None:
        future = self._close_future
        if future is None or future.done():
            return
        if self._wire_failure is not None:
            future.set_exception(self._wire_failure)
        elif result == _abi.ERR_TIMEOUT:
            future.set_exception(
                GlowcapError(_abi.ERR_TIMEOUT, "finish close exhausted its grace period")
            )
        elif result != _abi.OK:
            future.set_exception(GlowcapError(result, "session close failed"))
        else:
            future.set_result(None)

    def _ffi_owner_did_release(self) -> None:
        """Commit wrapper retirement after the driver loop was released."""
        self._closing = True
        self._released = True
        self._release_pending = False
        self._ptr = None
        self._publish_retirement()
        if not self._transport_close_started:
            self._transport_close_started = True
            try:
                self._transport.close()
            except BaseException as error:
                self.record_wire_failure(error)

    def close_transport(self) -> None:
        """Retire this session's transport and FFI handle exactly once."""
        if self._host._schedule_cleanup(self.close_transport):
            return
        self._host._assert_owner()
        self._closing = True
        if not self._transport_close_started:
            self._transport_close_started = True
            try:
                self._transport.close()
            except BaseException as error:
                self.record_wire_failure(error)
        if self._released or self._release_pending:
            return
        ptr = self._ptr
        loop_ref = getattr(self._transport, "_driver_loop", None)

        def commit_release(p=ptr):
            try:
                if loop_ref is not None:
                    loop_ref._ffi_session_release(p)
                else:
                    _check_host(_host.glowcap_host_session_release(p))
            except BaseException as error:
                self._release_pending = False
                self.record_wire_failure(error)
                future = self._close_future
                if future is not None and not future.done():
                    future.set_exception(error)
                self._host.signal_close_activity()
                return
            self._released = True
            self._release_pending = False
            self._host.unregister_session(self._key)
            self._ptr = None
            self._publish_retirement()
            self._host.signal_close_activity()
            self._host.schedule_kick()

        self._release_pending = True
        if _inside_turn():
            self._host.park_release(commit_release)
        else:
            commit_release()

    async def __aenter__(self) -> "Session":
        return cast("Session", self)

    async def __aexit__(self, *exc) -> None:
        await self.close()
