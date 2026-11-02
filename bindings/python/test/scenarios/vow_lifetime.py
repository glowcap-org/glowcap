"""FFI vow adoption, release retry, and finalizer ownership scenarios."""

from __future__ import annotations

import threading

from glowcap import GlowcapError
from glowcap._constants import ERR_CLOSED, ERR_NULL_POINTER
from glowcap._gc import HostGc
from glowcap._host.vows import VowTable
from glowcap._promise import _promise_for


async def abandoned_vow_drops_pending_completion() -> None:
    table = VowTable(HostGc())
    table.minted(11)
    table.abandon(11)
    try:
        await table.await_vow(11)
    except GlowcapError as error:
        assert error.code == ERR_CLOSED, error
    else:
        raise AssertionError("abandoned vow retained a pending completion row")


async def promise_adoption_releases_every_post_mint_failure() -> None:
    """A binding setup refusal cannot orphan the FFI vow it follows."""

    for failing in ("mint", "serve", "schedule", "track"):
        failure = RuntimeError(failing)
        parked: list[int] = []

        class FakeHost:
            raw = None

            def vow_minted(self, _vow: int, *, track_gc: bool) -> None:
                assert track_gc is False
                if failing == "mint":
                    raise failure

            def await_vow(self, _vow: int):
                raise AssertionError("an unobserved wrapper awaited its vow")

            async def kick_actions(self) -> None:
                raise AssertionError("an unobserved wrapper kicked synchronously")

            def schedule_kick(self) -> None:
                if failing == "schedule":
                    raise failure

        class FakeGc:
            def track_vow(self, _handle, _vow: int) -> None:
                if failing == "track":
                    raise failure

            def park_vow(self, vow: int) -> None:
                parked.append(vow)

        class FakeSession:
            host = FakeHost()
            gc = FakeGc()
            gc_enabled = False

            def serve(self) -> None:
                if failing == "serve":
                    raise failure

        try:
            _promise_for(FakeSession(), 19)
        except RuntimeError as observed:
            assert observed is failure, (failing, observed)
        else:
            raise AssertionError(f"{failing}: adoption unexpectedly succeeded")
        assert parked == [19], (failing, parked)


def gc_release_refusal_stays_owned() -> None:
    """A scheduled GC refusal remains queued and reaches the next verb head."""

    class RefusingHost:
        released = False
        host_raw = None

        def kick(self) -> None:
            raise AssertionError("a refused release must not kick")

        def schedule_drain(self, _run) -> None:
            pass

    host_gc = HostGc()
    host_gc.bind(RefusingHost())
    host_gc.pending.append(17)
    host_gc._drain_scheduled()
    background_failure = host_gc._background_failure
    assert isinstance(background_failure, GlowcapError), background_failure
    assert background_failure.code == ERR_NULL_POINTER, background_failure
    assert host_gc.pending == [17], host_gc.pending
    try:
        host_gc.drain_gc()
    except GlowcapError as surfaced:
        assert surfaced is background_failure
    else:
        raise AssertionError("scheduled GC refusal did not reach the next drain")
    assert host_gc.pending == [17], host_gc.pending


def retired_gc_ignores_late_finalizers() -> None:
    """A consumed FFI Host leaves no queue for late wrapper collection."""

    class LiveHost:
        released = False
        host_raw = None

        def __init__(self) -> None:
            self.scheduled = 0

        def kick(self) -> None:
            pass

        def schedule_drain(self, _run) -> None:
            self.scheduled += 1

        def abandon_vow(self, _vow: int) -> None:
            raise AssertionError("retired GC touched vow state")

    host_gc = HostGc()
    live = LiveHost()
    host_gc.bind(live)
    host_gc.pending.append(17)
    host_gc.pending_vows.append(19)
    host_gc.retire()
    host_gc._on_capability_dropped(23)
    host_gc.park_vow(29)
    assert host_gc.pending == []
    assert host_gc.pending_vows == []
    assert live.scheduled == 0, "late finalizer woke a retired Host"

    append_entered = threading.Event()
    finish_append = threading.Event()

    class BlockingPending(list[int]):
        def append(self, token: int) -> None:
            append_entered.set()
            finish_append.wait()
            super().append(token)

    raced_gc = HostGc()
    raced = LiveHost()
    raced_gc.bind(raced)
    raced_gc.pending = BlockingPending()
    enqueue = threading.Thread(target=raced_gc._on_capability_dropped, args=(31,))
    enqueue.start()
    append_entered.wait()
    retire = threading.Thread(target=raced_gc.retire)
    retire.start()
    finish_append.set()
    enqueue.join()
    retire.join()
    assert raced_gc.pending == [], "retirement left a concurrently enqueued token"
    assert raced.scheduled <= 1, "one finalizer scheduled more than one GC drain"

    class RefusingSchedule(LiveHost):
        def __init__(self) -> None:
            super().__init__()
            self.refuse = True

        def schedule_drain(self, _run) -> None:
            if self.refuse:
                self.refuse = False
                raise RuntimeError("scheduler refused")
            super().schedule_drain(_run)

    retry_gc = HostGc()
    retry_host = RefusingSchedule()
    retry_gc.bind(retry_host)
    try:
        retry_gc.park_vow(37)
    except RuntimeError:
        pass
    else:
        raise AssertionError("scheduler refusal disappeared")
    retry_gc.park_vow(37)
    assert retry_gc.pending_vows == [37], "retry duplicated one FFI vow release"
    assert retry_host.scheduled == 1, "retry did not reschedule the retained release"
