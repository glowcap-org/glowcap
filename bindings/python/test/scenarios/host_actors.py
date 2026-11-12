"""Host actors, told async behaviors, and far-promise breaks.

A Host spawns, sends to, and tells actors with no session, and a callback's
Host verbs join its turn. A refused Host send returns a failed future, and a
spawned actor's behavior entry leaves when the actor is collected, and
Hosts spawning on two threads at once never share a behavior id. A told
async behavior runs with no answer, and its failure reaches the Host's
failure journal. A session breaks the far promises still waiting on its
partner and stays usable, and a driver-owned session refuses the break. A
partner's op:abort stays readable after its session is released.
"""

from __future__ import annotations

import asyncio
import gc
import threading

from glowcap import GlowcapError, Host, Locator, PartnerAbort, Ref, Symbol, VowBroken, tcp
from glowcap._constants import DESIGNATOR_SCHEME_ADDRESS, ERR_INVALID_ARGUMENT, TRANSPORT_TCP

from scenarios.runtime import run_managed, tcp_connect


def _counter(start: int):
    count = [start]

    def behavior(verb, args):
        if verb == "add":
            count[0] += args[0]
            return count[0]
        if verb == "get":
            return count[0]
        raise ValueError(f"unexpected verb {verb}")

    return behavior


async def host_actors_need_no_session() -> None:
    host = Host()
    try:
        counter = host.spawn(_counter(0))
        assert await host.send(counter, "add", [2]) == 2
        host.tell(counter, "add", [3])
        assert await host.send(counter, "get") == 5, "a Host tell runs before the later send"

        turn_sends: list[asyncio.Future] = []

        def factory(verb, _args):
            assert verb == "make", verb
            host.tell(counter, "add", [1])
            turn_sends.append(host.send(counter, "add", [1]))
            return [host.spawn(lambda _verb, _args: Symbol("made"))]

        made_ref = host.spawn(factory)
        made = await host.send(made_ref, "make")
        assert isinstance(made, list) and isinstance(made[0], Ref), made
        assert await host.send(made[0], "probe") == Symbol("made")
        assert await asyncio.wait_for(turn_sends[0], 5) == 7, "the turn-time send answers after its tell"
        assert await host.send(counter, "get") == 7, "turn-time tell and send both committed"

        # A refused send queues nothing and fails its own future, so gather
        # still delivers the sibling's answer.
        released = host.spawn(_counter(0))
        host.release(released)
        answers = await asyncio.gather(
            host.send(counter, "get"),
            host.send(released, "get"),
            host.send(asyncio.get_running_loop().create_future(), "get"),
            return_exceptions=True,
        )
        assert answers[0] == 7, answers
        assert isinstance(answers[1], ValueError), answers
        assert isinstance(answers[2], TypeError), answers
    finally:
        await host.close()


class _Unprintable(Exception):
    def __str__(self) -> str:
        raise RuntimeError("this exception has no text")


async def unprintable_behavior_failure_breaks_the_answer() -> None:
    """A behavior failure whose own text raises still breaks the answer with
    its type name, and nothing unwinds through the ctypes callback."""
    host = Host()
    try:

        def behavior(_verb, _args):
            raise _Unprintable()

        try:
            await asyncio.wait_for(host.send(host.spawn(behavior), "go"), 5)
        except VowBroken as broken:
            assert broken.reason == "_Unprintable", broken.reason
        else:
            raise AssertionError("a raising behavior answered")
    finally:
        await host.close()


async def _settle_collection(host: Host, tick: Ref, want: int) -> int:
    # Collection crosses a finalizer, the Host's GC drain, and the Vat's next
    # turn, which the send to ``tick`` drives. Bound the rounds.
    for _ in range(60):
        gc.collect()
        host.gc.drain_gc()
        await host.send(tick, "tick")
        if len(host._behavior_entries) == want:
            break
    return len(host._behavior_entries)


async def spawned_entries_leave_at_collection() -> None:
    host = Host()
    try:
        tick = host.spawn(lambda _verb, _args: None)
        baseline = len(host._behavior_entries)
        probe = host.spawn(lambda _verb, _args: Symbol("alive"))
        assert await host.send(probe, "ping") == Symbol("alive")
        assert len(host._behavior_entries) == baseline + 1
        del probe
        assert await _settle_collection(host, tick, baseline) == baseline, "a collected actor kept its entry"

        # A capability in a Host-send answer is tracked like any other owned
        # reference, so dropping it collects the actor it names.
        factory = host.spawn(lambda _verb, _args: [host.spawn(lambda _v, _a: Symbol("made"))])
        made = await host.send(factory, "make")
        assert await host.send(made[0], "probe") == Symbol("made")
        assert len(host._behavior_entries) == baseline + 2
        del made
        left = await _settle_collection(host, tick, baseline + 1)
        assert left == baseline + 1, "an answer's capability was not released"
    finally:
        await host.close()


async def _spawn_on_own_thread(tag: str, barrier: threading.Barrier, ids: dict[str, set[int]]) -> None:
    host = Host()
    try:
        tick = host.spawn(lambda _verb, _args: None)
        baseline = len(host._behavior_entries)
        barrier.wait()
        actors = [(host.spawn(lambda _verb, _args, name=f"{tag}{i}": name), f"{tag}{i}") for i in range(40)]
        ids[tag] = set(host._behavior_entries)
        # Both Hosts hold every actor before either collects, so a shared id
        # would let this Host's collection retire the other's live entry.
        barrier.wait()
        survivors = actors[1::2]
        del actors
        left = await _settle_collection(host, tick, baseline + len(survivors))
        assert left == baseline + len(survivors), f"{tag}: collection released {left} of the expected entries"
        barrier.wait()
        for actor, name in survivors:
            assert await host.send(actor, "who") == name, f"{tag}: a survivor answered as another actor"
    finally:
        await host.close()


def concurrent_spawns_take_their_own_ids() -> None:
    barrier = threading.Barrier(2, timeout=30)
    ids: dict[str, set[int]] = {}
    failures: list[BaseException] = []

    def racer(tag: str) -> None:
        try:
            asyncio.run(_spawn_on_own_thread(tag, barrier, ids))
        except BaseException as err:
            barrier.abort()
            failures.append(err)

    threads = [threading.Thread(target=racer, args=(tag,)) for tag in ("a", "b")]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(60)
    if failures:
        raise failures[0]
    assert not (ids["a"] & ids["b"]), "two concurrent spawns took the same behavior id"


async def told_async_behavior_runs_and_reports() -> None:
    host = Host()
    ran = asyncio.Event()

    async def notice(verb, _args):
        await asyncio.sleep(0)
        ran.set()
        if verb == "fail":
            raise RuntimeError("told behavior failed")

    try:
        target = host.spawn(notice)
        host.tell(target, "ok")
        await asyncio.wait_for(ran.wait(), 5)
        ran.clear()
        host.tell(target, "fail")
        await asyncio.wait_for(ran.wait(), 5)
        for _ in range(10):
            failures = host.take_failures()
            if failures:
                break
            await asyncio.sleep(0)
        assert len(failures) == 1, failures
        assert failures[0].operation == "tell.behavior", failures[0]
        assert failures[0].primary_message == "told behavior failed", failures[0]
    finally:
        await host.close()


class _MemoryChannel:
    """One half of an in-memory byte channel for a byte-fed session pair."""

    designator_scheme = DESIGNATOR_SCHEME_ADDRESS

    def __init__(self) -> None:
        self.inbound: asyncio.Queue[bytes | None] = asyncio.Queue()
        self.peer: _MemoryChannel | None = None
        self.closed = False

    async def read(self) -> bytes | None:
        return await self.inbound.get()

    async def write(self, data: bytes) -> None:
        assert self.peer is not None
        await self.peer.inbound.put(bytes(data))

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.inbound.put_nowait(None)
        if self.peer is not None:
            self.peer.inbound.put_nowait(None)

    async def wait_closed(self) -> None:
        return None


async def break_far_promises_keeps_the_session() -> None:
    from glowcap._session import Session

    client_channel = _MemoryChannel()
    server_channel = _MemoryChannel()
    client_channel.peer = server_channel
    server_channel.peer = client_channel
    client_host = Host()
    server_host = Host()
    designator = tcp.address_designator("127.0.0.1", 1)
    server_session, session = await asyncio.gather(
        Session.establish_accepted(server_host, TRANSPORT_TCP, designator, server_channel, verified_channel_key=None),
        Session.establish_dialed_locator(
            client_host,
            Locator(TRANSPORT_TCP, designator, {}, "boolean-false"),
            client_channel,
            verified_channel_key=None,
        ),
    )
    parked = asyncio.Event()

    async def hang(verb, _args):
        if verb != "hang":
            return Symbol("alive")
        parked.set()
        await asyncio.Future()

    try:
        server_session.publish("svc", hang)
        server_session.serve()
        session.serve()
        svc = await session.fetch("svc")
        pending = session.send(svc, "hang")
        await asyncio.wait_for(parked.wait(), 5)
        session.break_far_promises("gave up waiting")
        try:
            await asyncio.wait_for(pending, 5)
        except VowBroken as broken:
            assert "gave up waiting" in str(broken), broken
        else:
            raise AssertionError("a broken far promise fulfilled")
        assert await session.send(svc, "ping") == Symbol("alive")
        assert server_session.partner_abort() is None, "no partner abort before close"
        # The close sends op:abort, and its kind and message outlive the
        # released handle that retained them.
        await session.close()
        await server_session.close()
        assert server_session.released, "the server session released its handle"
        assert server_session.partner_abort() == PartnerAbort("NormalShutdown", "session closing"), (
            server_session.partner_abort()
        )
        assert session.partner_abort() is None, "the closing side received no abort"
    finally:
        await session.close()
        await server_session.close()
        await asyncio.gather(client_host.close(), server_host.close())


async def driver_owned_session_refuses_break() -> None:
    host = Host()
    host.publish("echo", lambda _verb, args: args[0])
    server = await tcp.listen("127.0.0.1", 0, host=host)

    async def serve() -> None:
        async for accepted in server:
            await accepted.serve()

    serving = asyncio.create_task(serve())
    try:
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        echo = await session.fetch("echo")
        try:
            session.break_far_promises("not ours to break")
        except GlowcapError as refused:
            assert refused.code == ERR_INVALID_ARGUMENT, refused
        else:
            raise AssertionError("a driver-owned session accepted a far-promise break")
        assert await session.send(echo, "echo", [3]) == 3, "the refused break left the session usable"
        await session.close()
    finally:
        await server.close()
        await serving
        await host.close()


def run() -> None:
    asyncio.run(host_actors_need_no_session())
    print("python test OK: a Host spawned, sent to, and told actors with no session")
    asyncio.run(unprintable_behavior_failure_breaks_the_answer())
    print("python test OK: a behavior failure with unprintable text broke its answer by type name")
    asyncio.run(spawned_entries_leave_at_collection())
    print("python test OK: a collected Host actor released its behavior entry")
    concurrent_spawns_take_their_own_ids()
    print("python test OK: Hosts spawning on two threads took their own behavior ids")
    run_managed(driver_owned_session_refuses_break())
    print("python test OK: a driver-owned session refused the far-promise break")
    asyncio.run(told_async_behavior_runs_and_reports())
    print("python test OK: a told async behavior ran and reported its failure as callerless")
    asyncio.run(break_far_promises_keeps_the_session())
    print(
        "python test OK: breaking far promises failed the waiting send and kept the session, and a close left its partner abort"
    )
