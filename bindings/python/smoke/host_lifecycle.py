"""Host construction, close, and implicit-release lifecycle evidence."""

from __future__ import annotations

import asyncio
import ctypes
import gc
import threading

import pancake._host as _host_module
import pancake._host.finalizer as _host_finalizer
from pancake import Host, Locator, PancakeError
from pancake._constants import ERR_INVALID_ARGUMENT, ERR_IO
from pancake._trampoline import _entry_for


def run() -> None:
    for invalid_seed in (b"\0" * 31, b"\0" * 33):
        try:
            Host(seed=invalid_seed)
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("Host must reject a seed that is not 32 bytes")

    caller_seed = bytearray(range(32))
    owned_seed_host = Host(seed=caller_seed)
    try:
        expected_designator = owned_seed_host.designator()
        caller_seed[0] ^= 0xFF
        assert owned_seed_host.designator() == expected_designator
        assert owned_seed_host.seed == bytes(range(32))
    finally:
        asyncio.run(owned_seed_host.close())

    locator_host = Host()
    locator_host.set_advertised_locator(Locator("tcp", "127.0.0.1:7441", {}))
    locator_host.remove_advertised_locator("tcp")
    asyncio.run(locator_host.close())

    async def make_loop_bound_host() -> Host:
        return Host()

    stopped_loop = asyncio.new_event_loop()
    stopped_host = stopped_loop.run_until_complete(make_loop_bound_host())
    assert not stopped_loop.is_running() and not stopped_loop.is_closed()
    stopped_loop.run_until_complete(stopped_host.close())
    assert stopped_host.released, (
        "release must not queue cleanup onto a stopped event loop"
    )
    stopped_loop.close()

    stopped_work_loop = asyncio.new_event_loop()
    stopped_work_finished = False

    async def make_host_with_active_work() -> Host:
        host = Host()
        started = asyncio.Event()

        async def pending() -> None:
            nonlocal stopped_work_finished
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped_work_finished = True

        host.start_dial_task(1, pending)
        await started.wait()
        await host.cancel_dial_task(1)
        return host

    stopped_work_host = stopped_work_loop.run_until_complete(
        make_host_with_active_work()
    )
    stopped_work_loop.run_until_complete(stopped_work_host.close())
    assert stopped_work_finished, "CANCEL_DIAL did not join its ticketed task"
    assert stopped_work_host._raw is None, (
        "stopped-loop close retained the native Host after joining work"
    )
    stopped_work_loop.close()

    # Collection is not an operational Host verb and may run on any Python
    # thread. The finalizer therefore owns raw teardown state rather than
    # trying to hop a dead event loop or touching the collected wrapper.
    async def make_finalizable_host() -> tuple[Host, int]:
        host = Host()
        # Deliberately close the ownership cycle: Host -> behavior -> Host.
        # The process-global trampoline lookup must not turn it into a root.
        host.publish_giftable(
            "finalized",
            lambda _verb, _args: host.released,
        )
        return host, host._giftables["finalized"]

    finalizer_loop = asyncio.new_event_loop()
    finalized, finalized_ctx = finalizer_loop.run_until_complete(
        make_finalizable_host()
    )
    handoff = [finalized]
    del finalized
    finalizer_loop.close()

    def collect_host() -> None:
        handoff.pop()
        gc.collect()

    collector = threading.Thread(target=collect_host)
    collector.start()
    collector.join()
    assert _entry_for(finalized_ctx) is None, (
        "off-thread Host finalization must retire native and trampoline authority"
    )

    # A finalizer release refused outside a callback transfers to one process
    # retry owner. The next safe Host boundary retries it instead of retaining
    # the raw Host and allocator context forever.
    original_host_release = _host_module._host.pancake_host_release
    attempts = 0

    def refuse_once(_raw) -> int:
        nonlocal attempts
        attempts += 1
        return ERR_INVALID_ARGUMENT if attempts == 1 else 0

    retry_state = _host_module._HostFinalizerState(
        ctypes.c_void_p(1), {}, [], {}, None, 0
    )
    _host_module._host.pancake_host_release = refuse_once
    try:
        _host_module._release_finalizer_state(retry_state, checked=False)
        assert _host_finalizer._pending_finalizer_retry_count() == 1
        _host_module._drain_deferred_finalizer_states()
        assert retry_state.raw is None
        assert _host_finalizer._pending_finalizer_retry_count() == 0
        assert attempts == 2
    finally:
        _host_module._host.pancake_host_release = original_host_release

    construction_releases = []

    class ConstructionContext:
        def __init__(self) -> None:
            self.released = 0

        def _release_handle(self) -> None:
            self.released += 1

    construction_context = ConstructionContext()
    _host_module._host.pancake_host_release = lambda raw: (
        construction_releases.append(raw) or ERR_INVALID_ARGUMENT
    )
    try:
        cleanup = _host_module._release_unpublished_host(
            ctypes.c_void_p(3), construction_context
        )
        assert (
            isinstance(cleanup, PancakeError) and cleanup.code == ERR_INVALID_ARGUMENT
        )
        assert construction_context.released == 0, (
            "pre-commit construction cleanup freed the borrowed Context"
        )
        assert _host_finalizer._pending_finalizer_retry_count() == 1
        _host_module._host.pancake_host_release = lambda raw: (
            construction_releases.append(raw) or 0
        )
        _host_module._drain_deferred_finalizer_states()
        assert construction_context.released == 1
        assert len(construction_releases) == 2
    finally:
        _host_module._host.pancake_host_release = original_host_release

    reports = []

    class FinalizerRecorder:
        def _report_failure(self, **report) -> None:
            reports.append(report)

        def _release_handle(self) -> None:
            pass

    consumed_state = _host_module._HostFinalizerState(
        ctypes.c_void_p(2), {}, [], {}, FinalizerRecorder(), 73
    )
    _host_module._host.pancake_host_release = lambda _raw: ERR_IO
    try:
        _host_module._release_finalizer_state(consumed_state, checked=False)
        assert consumed_state.raw is None, (
            "a consumed Host release retained a dangling pointer"
        )
        assert _host_finalizer._pending_finalizer_retry_count() == 0
        assert len(reports) == 1 and reports[0]["scope_id"] == 73, reports
        assert reports[0]["operation"] == "host.finalizer.release", reports
    finally:
        _host_module._host.pancake_host_release = original_host_release
