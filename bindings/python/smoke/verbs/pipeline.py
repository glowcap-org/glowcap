"""Promise-pipeline binding scenarios: target ownership, observation, and projection."""

from __future__ import annotations

import asyncio

from glowcap import FEATURE_FULL, FEATURE_MULTI_LOCATION, Host, GlowcapError, Ref, Tagged, enable_trace, tcp
from glowcap._constants import ERR_INVALID_ARGUMENT, ERR_UNSUPPORTED_VALUE

from smoke.runtime import tcp_connect


async def drives_chain() -> None:
    """An unresolved public promise pipelines and stays owned by its Host."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, _args):
                    assert verb == "create", verb
                    state = {"done": False}

                    def task(task_verb, _task_args):
                        if task_verb == "assign":
                            return "assigned"
                        if task_verb == "complete":
                            state["done"] = True
                            return "done"
                        if task_verb == "status":
                            return "done" if state["done"] else "open"
                        raise ValueError(f"no such method: {task_verb}")

                    return session.spawn(task)

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        task = session.send(root_ref, "create", ["benchmark"])
        session.send(task, "assign", ["alice"])
        session.send(task, "complete", [])
        status = session.send(task, "status", [])
        assert await status == "done"
        await session.tell(task, "assign", ["alice"])
        assert await session.send(task, "status", []) == "done"

        second_server = await tcp.listen("127.0.0.1", 0)
        second_published = asyncio.Event()

        async def serve_second() -> None:
            async for second_host_session in second_server:

                def second_root(verb, args):
                    assert verb == "create", verb
                    label = str(args[0])

                    def second_task(task_verb, _task_args):
                        if task_verb != "label":
                            raise ValueError(f"no such method: {task_verb}")
                        return label

                    return second_host_session.spawn(second_task)

                second_host_session.publish("root", second_root)
                second_published.set()
                await second_host_session.serve()
                break

        second_serve_task = asyncio.ensure_future(serve_second())
        second = await tcp_connect(tcp.locator("127.0.0.1", second_server.port))
        second.serve()
        await asyncio.wait_for(second_published.wait(), timeout=5)
        second_root_ref = await second.fetch("root")
        second_task = second.send(second_root_ref, "create", ["second"])
        assert task.vow == second_task.vow, (
            "the scenario must exercise colliding Host vow ids"
        )
        try:
            await second.send(task, "label", [])
            raise AssertionError(
                "a promise from another Host must not be reinterpreted"
            )
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        assert await second.send(second_task, "label", []) == "second"
        await second.close()
        await asyncio.wait_for(second_serve_task, timeout=5)
        await second_server.close()
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def unawaited_break_stays_silent() -> None:
    """A recorded break materializes no exception until its handle is observed."""
    loop = asyncio.get_running_loop()
    seen: list = []
    boom_seen = asyncio.Event()
    loop.set_exception_handler(lambda _loop, ctx: seen.append(ctx))
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, _args):
                    if verb == "ping":
                        return "pong"
                    boom_seen.set()
                    raise ValueError(f"boom: {verb}")

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        anchor = session.send(root_ref, "explode", [])
        assert isinstance(anchor, asyncio.Future), (
            "a send handle must be an asyncio.Future"
        )
        await asyncio.wait_for(boom_seen.wait(), timeout=5)
        assert await session.send(root_ref, "ping", []) == "pong"
        del anchor
        assert not seen, f"unawaited break must stay silent, saw {seen}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def projections_reach_a_field() -> None:
    """Projection vows remain pipelineable and preserve a late source await."""
    # Structural projection operations belong to v1.0; multi-location does not.
    expected_features = FEATURE_FULL & ~FEATURE_MULTI_LOCATION
    serve_task = None
    server = await tcp.listen(
        "127.0.0.1",
        0,
        host=Host(codec="capnp", captp_version="v1_0", features="full"),
    )
    published = asyncio.Event()
    release_make = asyncio.Event()
    pipeline_sent = asyncio.Event()
    make_pending = False
    uninstall_trace = enable_trace(
        lambda event: pipeline_sent.set()
        if event["kind"] == "ocapn.message-decoded"
        and event.get("outbound")
        and event.get("op") == "pipeline-sentinel"
        else None,
    )
    try:

        async def serve_one() -> None:
            async for session in server:
                assert session.profile.captp_version == "v1_0"
                assert session.profile.codec == "capnp"
                assert session.profile.features == expected_features, (session.profile.features, expected_features)

                def root(verb, args):
                    nonlocal make_pending
                    if verb == "release":
                        assert make_pending, "release arrived before make deferred"
                        release_make.set()
                        return "released"
                    assert verb == "make", verb
                    label = str(args[0]) if args else "anon"
                    make_pending = True

                    async def finish_make():
                        await release_make.wait()
                        return Tagged("task", [["assigned", label, 7]])

                    return finish_make()

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(
            tcp.locator("127.0.0.1", server.port),
            host=Host(codec="capnp", captp_version="v1_0", features="full"),
            codec="capnp",
        )
        assert session.profile.captp_version == "v1_0"
        assert session.profile.codec == "capnp"
        assert session.profile.features == expected_features, (session.profile.features, expected_features)
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        made = session.send(root_ref, "make", ["alice"])
        label = made.untag("task").index(1)
        await session.tell(label, "pipeline-sentinel", [])
        await asyncio.wait_for(pipeline_sent.wait(), timeout=5)
        assert await session.send(root_ref, "release", []) == "released"
        assert await label == "alice"
        full = await made
        assert isinstance(full, Tagged) and full.tag == "task", full
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        uninstall_trace()
        try:
            await server.close()
        finally:
            if serve_task is not None:
                serve_task.cancel()
                await asyncio.gather(serve_task, return_exceptions=True)


async def passes_a_pending_promise() -> None:
    """A promise is a send argument (ADR-0068): the unawaited ``make`` answer
    crosses as a capability for the pending answer, the same promise crosses
    settled as its value nested in a list, the board hands each capability
    back, and greeting through it proves both reached the greeter."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    if verb == "make":

                        def greeter(greeter_verb, _greeter_args):
                            if greeter_verb == "greet":
                                return "hello from the greeter"
                            raise ValueError(f"no such method: {greeter_verb}")

                        return session.spawn(greeter)
                    if verb == "use":
                        return args[0]
                    if verb == "use_first":
                        return args[0][0]
                    raise ValueError(f"no such method: {verb}")

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        greeter = session.send(root_ref, "make", [])
        used = await session.send(root_ref, "use", [greeter])
        # Observed settled, the promise passes as its value.
        assert isinstance(await greeter, Ref)
        used_first = await session.send(root_ref, "use_first", [[greeter]])
        assert isinstance(used, Ref) and isinstance(used_first, Ref), (used, used_first)
        assert await session.send(used, "greet", []) == "hello from the greeter"
        assert await session.send(used_first, "greet", []) == "hello from the greeter"
        loop = asyncio.get_running_loop()
        try:
            await session.send(root_ref, "use", [loop.create_future()])
            raise AssertionError("a plain Future must be refused before any frame moves")
        except GlowcapError as error:
            assert error.code == ERR_UNSUPPORTED_VALUE, error
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()
