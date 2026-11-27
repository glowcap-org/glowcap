"""Independent reference ownership, resolution, and failed finalizer adoption."""

import asyncio
import gc
import weakref
from unittest.mock import patch

from glowcap import Forward, GlowcapError, Host, Ref, Tagged, tcp
from glowcap._constants import BINDING_UNOBSERVED_OUTCOME_CAP, ERR_NOT_FOUND
from glowcap._value import _ref_from_id

from scenarios.runtime import tcp_connect


async def run() -> None:
    host = Host()
    child = host.spawn(lambda _verb, _args: "child")
    completion = None

    def echo(verb, args):
        nonlocal completion
        if verb == "anchor":
            return child
        if verb == "compound":
            return [child, Tagged("nested", [child])]
        if verb == "barrier":
            return None
        if verb in ("pending", "pending_compound"):
            future = asyncio.get_running_loop().create_future()

            def completion():
                future.set_result([args[0]] if args else [child, Tagged("nested", [child])])

            return future
        return args[0]

    host.publish("echo", echo)
    server = await tcp.listen("127.0.0.1", 0, host=host)

    async def serve() -> None:
        async for session in server:
            await session.serve()

    serving = asyncio.create_task(serve())
    session = None
    try:
        for gc_enabled in (False, True):
            session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
            if gc_enabled:
                session.with_gc()
            owner = session.host
            original = session.spawn(lambda verb, args: "alive")
            held = owner.retain(original)
            assert held is not original and held == original
            session.release(original)
            assert await session.send(held, "ping", []) == "alive"
            resolved = await session.resolve(held)
            assert isinstance(resolved, Ref) and resolved is not held
            owner.release(held)
            assert await session.send(resolved, "ping", []) == "alive"
            foreign = Host()
            try:
                for target, ref in ((owner, held), (foreign, resolved)):
                    try:
                        target.retain(ref)
                    except (GlowcapError, ValueError):
                        pass
                    else:
                        raise AssertionError("released or foreign reference retained")
                failure = RuntimeError("finalizer registration refused")
                with patch.object(owner.gc, "track_ref", side_effect=failure):
                    try:
                        owner.retain(resolved)
                    except RuntimeError as raised:
                        assert raised is failure
                    else:
                        raise AssertionError("failed adoption returned a reference")
                assert owner.gc.pending == [resolved.id], "failed adoption lost its retain"
                owner.gc.drain_gc()
                assert await session.send(resolved, "ping", []) == "alive"
                remote = await session.fetch("echo")
                await _unexposed_replies(session, remote)
                forwarder = session.spawn(lambda verb, args: Forward(remote, verb, args))
                nested = session.spawn(lambda verb, args: Forward(forwarder, verb, args))
                for target in (remote, forwarder, nested):
                    for case in ("cancelled", "timeout", "unread", "raced", "callback", "gather", "late"):
                        anchor = await session.send(remote, "anchor")
                        await _observer_lifetime(session, target, remote, case, lambda: completion())
                        _release_last(session, anchor, (case, target is remote))
                session.release(nested)
                session.release(forwarder)
                remote_resolved = await session.resolve(remote)
                assert isinstance(remote_resolved, Ref)
                pending = session.send(remote, "pending", [remote])
                promise_ref = await session.send(remote, "echo", [pending])
                assert isinstance(promise_ref, Ref)
                resolving = asyncio.create_task(session.resolve(promise_ref))
                await asyncio.sleep(0)
                assert not resolving.done()
                completion()
                settled = await asyncio.wait_for(resolving, timeout=2)
                assert isinstance(settled[0], Ref)
                owner.release(settled[0])
                owner.release((await pending)[0])
                owner.release(promise_ref)

                source = session.spawn(lambda verb, args: "temporary")
                final_owner = owner.retain(source)
                token = final_owner.id
                collected = weakref.ref(final_owner)
                owner.release(source)
                del final_owner
                gc.collect()
                owner.gc.drain_gc()
                assert collected() is None
                try:
                    owner.retain(_ref_from_id(token))
                except GlowcapError:
                    pass
                else:
                    raise AssertionError("collection did not retire the final C retain")
                assert await session.send(remote, "echo", [19]) == 19
                session.release(remote)
                assert await session.send(remote_resolved, "echo", [19]) == 19
                owner.release(remote_resolved)
                owner.release(resolved)
            finally:
                await foreign.close()
            try:
                foreign.retain(resolved)
            except GlowcapError:
                pass
            else:
                raise AssertionError("closed Host accepted a retain")
            await session.close()
    finally:
        if session is not None:
            await session.close()
        await server.close()
        await serving
        await host.close()


async def _unexposed_replies(session, remote):
    for case in ("abandoned", "evicted", "cancelled", "observed"):
        anchor = await session.send(remote, "anchor")
        token = anchor.id
        pending = session.send(remote, "compound")
        if case == "cancelled":
            pending.add_done_callback(lambda _: None)
            pending.cancel()
        await session.send(remote, "barrier")
        if case == "evicted":
            # The native compound result is real. Only the pressure is synthesized.
            for offset in range(BINDING_UNOBSERVED_OUTCOME_CAP):
                vow = (1 << 64) - 1 - offset
                session.host.vow_minted(vow)
                session.host.settle_vow(vow, True, None)
        elif case == "observed":
            first, tagged = await pending
            assert first.id == tagged.value[0].id == token
            session.release(first)
            session.release(tagged.value[0])
        del pending
        gc.collect()
        session.host.gc.drain_gc()
        await session.send(remote, "barrier")
        session.host.gc.drain_gc()
        _release_last(session, anchor, case)


def _release_last(session, anchor, case):
    token = anchor.id
    session.release(anchor)
    try:
        extra = session.host.retain(_ref_from_id(token))
    except GlowcapError as error:
        assert error.code == ERR_NOT_FOUND, error
    else:
        session.release(extra)
        raise AssertionError(f"{case}: unexposed native reply retained its child")


async def _observer_lifetime(session, target, remote, case, finish):
    p = session.send(target, "pending_compound")
    collected = weakref.ref(p)
    retrieved = []
    fired = asyncio.Event()
    if case == "callback":

        def accept(settled):
            retrieved.append(settled.result())
            fired.set()

        p.add_done_callback(accept)
    elif case == "raced":

        async def observe():
            return await p

        p.add_done_callback(lambda _: waiter.cancel())
        waiter = asyncio.create_task(observe())
    elif case == "gather":
        aggregate = asyncio.gather(p)
    elif case == "timeout":
        done, waiting = await asyncio.wait({p}, timeout=0)
        assert not done
        del waiting
    else:
        p.add_done_callback(lambda _: fired.set())
    await session.send(remote, "barrier")
    if case == "cancelled":
        assert p.cancel()
    if case not in ("late", "raced"):
        del p
    for _ in range(4):
        await asyncio.sleep(0)
    gc.collect()
    if case in ("timeout", "cancelled"):
        assert collected() is None, f"{case}: pending peer kept its detached observer alive"
    elif case == "callback":
        assert collected() is not None, "registered callback lost its wrapper"
    session.host.gc.drain_gc()
    finish()
    await session.send(remote, "barrier")
    if case == "raced":
        try:
            await waiter
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("the waiter claimed a reply after cancellation")
        del waiter, p
    if case in ("unread", "late", "callback"):
        await fired.wait()
    if case == "gather":
        retrieved.extend(await aggregate)
    elif case == "late":
        assert p.done()
        retrieved.append(await p)
        del p
    if case in ("gather", "late", "callback"):
        ((first, tagged),) = retrieved
        assert await session.send(first, "ping") == "child"
        session.release(first)
        session.release(tagged.value[0])
    gc.collect()
    await asyncio.sleep(0)
    session.host.gc.drain_gc()
