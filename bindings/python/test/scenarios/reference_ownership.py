"""Independent reference ownership, resolution, and failed finalizer adoption."""

import asyncio
import gc
import weakref
from unittest.mock import patch

from glowcap import GlowcapError, Host, Ref, Tagged, tcp
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
        if verb == "pending":
            future = asyncio.get_running_loop().create_future()

            def completion():
                future.set_result([args[0]])

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
        elif case == "cancelled":
            await pending._begin_task
            await asyncio.sleep(0)
        del pending
        gc.collect()
        session.host.gc.drain_gc()
        await session.send(remote, "barrier")
        session.host.gc.drain_gc()
        session.release(anchor)
        try:
            extra = session.host.retain(_ref_from_id(token))
        except GlowcapError as error:
            assert error.code == ERR_NOT_FOUND, error
        else:
            session.release(extra)
            raise AssertionError(f"{case}: unexposed native reply retained its child")
