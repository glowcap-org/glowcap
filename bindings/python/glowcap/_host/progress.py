"""Internal Host action-drain progress."""

from __future__ import annotations

import asyncio
import functools
from typing import Any, Callable, Coroutine

from .._action import _Handlers, _park_actions, _run_action
from .._errors import _check_host
from .._ffi_host import _host
from .._trampoline import _enter_host_deliver, _exit_deliver, _inside_turn
from .finalizer import _drain_deferred_finalizer_states, _parked_releases
from .state import HostMixinBase


async def _next_loop_turn() -> None:
    loop = asyncio.get_running_loop()
    resumed = loop.create_future()

    def resume() -> None:
        if not resumed.done():
            resumed.set_result(None)

    loop.call_soon(resume)
    await resumed


class _ProgressMixin(HostMixinBase):
    @functools.cached_property
    def action_handlers(self) -> _Handlers:
        """The one executor for this Host's popped actions."""
        return _Handlers(self)

    def vow_minted(self, vow: int, *, track_gc: bool = False) -> None:
        """Record a freshly minted vow so the drain can route its completion.
        Runs in the same synchronous block as the minting FFI call, so no drain
        can pop the completion first. Binding-internal."""
        self._vows.minted(vow, track_gc=track_gc)

    def await_vow(self, vow: int) -> "asyncio.Future":
        """A future for the vow's eventual outcome: the fulfilled wire value,
        or an exception: :class:`VowBroken` for a partner break, the typed
        ``ERR_CLOSED`` :class:`GlowcapError` when the settle was the
        disconnect's own break. Settles immediately from the recorded state
        when the outcome already landed. Binding-internal."""
        return self._vows.await_vow(vow)

    def settle_vow(self, vow: int, ok: bool, payload) -> None:
        self._vows.settle(vow, ok, payload)

    def abandon_vow(self, vow: int) -> None:
        """Retire completion state for a public vow no Python handle owns."""
        self._vows.abandon(vow)

    def get_session(self, ptr: int):
        """Look up a live session by session address. Binding-internal: the
        action drain's FLUSH/CLOSE arms route through it."""
        return self._sessions.get(ptr)

    def park_release(self, release: "Callable[[], None]") -> None:
        """Park a C release the host refused inside a behavior callback. The
        next drain, the head of :meth:`kick_actions`, or the feed's unwind,
        runs it where it is legal. The parked list is thread-local (see
        ``_parked_releases``), so independent Host threads cannot drain one
        another's callback-time releases. Binding-internal."""
        _parked_releases().append(release)

    def drain_parked_releases(self) -> None:
        """Run every parked release, always outside a callback frame where the
        C tier accepts them. Called at the head of :meth:`kick_actions` and
        right after a feed returns. Binding-internal."""
        if _inside_turn():
            return
        releases = _parked_releases()
        ran_any = bool(releases)
        while releases:
            releases.popleft()()
        _drain_deferred_finalizer_states()
        # A parked release retires a native session or Host handle, which is
        # close-relevant state; wake any parked close driver to re-check.
        if ran_any:
            self.signal_close_activity()

    def pending_release_count(self) -> int:
        """How many releases are parked: test observability for the mid-turn
        close park. Binding-internal."""
        return len(_parked_releases())

    def schedule_kick(self) -> None:
        """Kick the action drain from a synchronous verb: schedule it as its
        own task, retained until done. Binding-internal. On a loop-adopted
        host the native loop is the one drain, so the kick becomes a
        scheduled loop step."""
        if self._driver_loop is not None:
            self._driver_loop.schedule_step()
            return
        if _inside_turn() or not self._raw:
            return
        if self._schedule_cleanup(self.schedule_kick):
            return
        self._assert_owner()
        try:
            task = asyncio.get_running_loop().create_task(self.kick_actions())
        except RuntimeError:
            # No running loop (a sync teardown path); the next verb drains.
            return
        self._own_action_drain(task)

    def _own_action_drain(self, task: "asyncio.Task") -> None:
        """Retain a detached action drain and consume its terminal result."""
        self._action_drains.add(task)

        def done(finished: "asyncio.Task") -> None:
            self._action_drains.discard(finished)
            if finished.cancelled():
                return
            error = finished.exception()
            if error is not None:
                self._record_terminal_failure(error)
                self.signal_close_activity()

        task.add_done_callback(done)

    async def _join_action_drains(self) -> None:
        current = asyncio.current_task()
        while True:
            pending = tuple(task for task in self._action_drains if task is not current)
            if not pending:
                return
            await asyncio.gather(*pending, return_exceptions=True)
            # A completed task's add_done_callback is only scheduled. Retire
            # the snapshot synchronously here so this loop cannot immediately
            # gather the same done tasks again and starve those callbacks.
            self._action_drains.difference_update(pending)

    def start_dial_task(
        self,
        ticket: int,
        route_index: int,
        run: "Callable[[], Coroutine[Any, Any, None]]",
    ) -> None:
        """Retain a popped DIAL independently of the drain that discovered it."""
        if not self._raw:
            return
        self._assert_owner()
        task = asyncio.get_running_loop().create_task(run())
        key = (ticket, route_index)
        self._dial_tasks[key] = task

        def done(finished: "asyncio.Task") -> None:
            if self._dial_tasks.get(key) is finished:
                self._dial_tasks.pop(key, None)
            # Retrieve terminal exceptions so Host-owned cancellation does not
            # become an unhandled task warning.
            if not finished.cancelled():
                finished.exception()
            if self._raw:
                self.schedule_kick()

        task.add_done_callback(done)

    async def cancel_dial_task(self, ticket: int, route_index: int) -> None:
        """Interrupt and join one core-selected DIAL, then acknowledge retirement."""
        task = self._dial_tasks.get((ticket, route_index))
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        if self._raw:
            _check_host(_host.glowcap_host_dial_cancelled(
                self._raw, ticket, route_index
            ))
            # Retiring a pending dial is close-relevant pending work.
            self.signal_close_activity()

    async def kick_actions(self) -> None:
        """Run the shared C action drain, then honor each parked arm. Reentrant
        by necessity: the DIAL arm's dial executor establishes a whole new
        connection *inside* an action, and that establish must itself drain
        (its start-session FLUSH): a single-flighted drain would await its own
        completion there. Arms are parked under ``glowcap_host_pump_drain``
        (sync hooks only) and awaited after the C loop returns, so overlapping
        kickers never await inside the C callback. Re-parks until empty: a
        NEED_GIFT_ID's ``provide_gift_id`` can queue FLUSH legs after the C
        drain returns (same as Racket's ``drain-host-actions!``). A no-op
        inside a hosted turn: the host refuses the driving verbs there, and
        everything the turn enqueued pumps when the enclosing feed unwinds
        into this same drain. Binding-internal."""
        task = asyncio.current_task()
        admitted_task = (
            task if task is not None and task not in self._action_drains else None
        )
        if admitted_task is not None:
            self._action_drains.add(admitted_task)
        try:
            if self._driver_loop is not None:
                # The native loop is the drain; one step flushes what a verb
                # queued.
                self._driver_loop.step_now()
                return
            if _inside_turn():
                return
            self._assert_owner()
            # Parked closes run first: before the raw-handle check, because a
            # mid-turn Host.close cleared `_raw` while parking the actual free.
            self.drain_parked_releases()
            if not self._raw:
                return
            while True:
                if not self._raw:
                    return
                # The native drain resumes queued Host work before its first
                # external action and may synchronously invoke a behavior.
                prior = _enter_host_deliver(self)
                try:
                    parked, yielded = _park_actions(self)
                finally:
                    _exit_deliver(prior)
                if not parked and not yielded:
                    return
                first_failure: Exception | None = None
                for action in parked:
                    # One failing action must not strand the rest of the drain:
                    # work behind it can belong to another live session.
                    try:
                        await _run_action(self, action)
                    except Exception as error:  # noqa: BLE001 — drain every action
                        if first_failure is None:
                            first_failure = error
                # A drained batch may have advanced close-relevant state
                # (FLUSH, CLOSE, SETTLE, dial retirement); wake any parked
                # close driver. Signaling only when work ran keeps a close
                # driver's own no-op kicks from waking the waiter it just
                # armed.
                if parked:
                    self.signal_close_activity()
                if first_failure is not None:
                    raise first_failure
                if yielded:
                    await _next_loop_turn()
        finally:
            if admitted_task is not None:
                self._action_drains.discard(admitted_task)
