"""Forwarding authority and callback-latch scenarios for the Python binding."""

from __future__ import annotations

import asyncio

from glowcap import Host, Ref, VowBroken, tcp

from smoke.runtime import tcp_connect


async def _forwarding_proxies_over_the_wire() -> None:
    """Object-capability forwarding proxies over the wire (ADR-0064). The server
    fetches the client's published tool, a far reference on the server side,
    wraps it in a caretaker and an attenuator, and hands the proxies back. A
    call through the proxy forwards across the server to the client's tool (the
    far deferred-answer path) and settles the caller's answer. The attenuator
    passes only its allow-listed verb, and a revoke breaks every later call."""
    server = await tcp.listen("127.0.0.1", 0)
    tool_ready = asyncio.Event()
    proxy_ready = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:
                session.serve()
                await tool_ready.wait()
                tool = await session.fetch("tool")
                care = session.caretaker(tool)
                readonly = session.attenuate(tool, ["get"])

                def root(verb, args):
                    if verb == "proxy":
                        return care.proxy
                    if verb == "readonly":
                        return readonly
                    if verb == "revoke":
                        care.revoke()
                        return None
                    raise ValueError(f"no such method: {verb}")

                session.publish("root", root)
                proxy_ready.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()  # serve so the server's forwarded call arrives

        def tool(verb, args):
            if verb == "add":
                n = args[0] if args and isinstance(args[0], int) else 0
                return n + 1
            if verb == "get":
                return 7
            raise ValueError(f"no such method: {verb}")

        session.publish("tool", tool)
        tool_ready.set()
        await proxy_ready.wait()
        root_ref = await session.fetch("root")

        # Live caretaker: a call forwards across the server to the far tool.
        proxy = await session.send(root_ref, "proxy", [])
        assert isinstance(proxy, Ref), "the caretaker proxy lifts to a Ref"
        total = await session.send(proxy, "add", [41])
        assert total == 42, f"caretaker forwards to the far tool, got {total!r}"

        # Attenuator: the allow-listed verb forwards; any other breaks.
        readonly = await session.send(root_ref, "readonly", [])
        assert isinstance(readonly, Ref), "the attenuator proxy lifts to a Ref"
        got = await session.send(readonly, "get", [])
        assert got == 7, f"the attenuator forwards an allowed verb, got {got!r}"
        denied = None
        try:
            await session.send(readonly, "add", [1])
        except VowBroken as error:
            denied = error
        assert denied is not None and "Attenuated" in str(denied), "an out-of-list verb breaks Attenuated"

        # Revoke: every later call through the proxy breaks.
        await session.send(root_ref, "revoke", [])
        severed = None
        try:
            await session.send(proxy, "add", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), "a revoked proxy breaks Revoked"

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _forwarding_proxy_local_call() -> None:
    """The wart ADR-0064 closes: a forwarding proxy is an ordinary spawned actor,
    so its own host calls it locally as a partner calls it over the
    wire. A caretaker over a *local* tool answers a local send. A caretaker
    over a *far* tool forwards across the wire and the local send still
    settles, and a revoke breaks the local call too, no second-class behavior
    on the hosting side."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def tool(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"no such method: {verb}")

                session.publish("tool", tool)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()

        # A caretaker over a local tool, called locally by its own host.
        def local_tool(verb, args):
            if verb == "double":
                return (args[0] if args and isinstance(args[0], int) else 0) * 2
            raise ValueError(f"no such method: {verb}")

        local = session.publish("local-double", local_tool)
        care_local = session.caretaker(local)
        doubled = await session.send(care_local.proxy, "double", [21])
        assert doubled == 42, f"a local proxy answers a local call, got {doubled!r}"

        # A caretaker over a far tool, called locally: the proxy forwards across
        # the wire and the local send still settles on the partner's reply.
        await asyncio.wait_for(published.wait(), timeout=5)
        far = await session.fetch("tool")
        care_far = session.caretaker(far)
        pong = await session.send(care_far.proxy, "ping", [])
        assert pong == "pong", f"a local call to a proxy over a far tool settles, got {pong!r}"

        # Revoke severs the local call as it severs a partner's.
        care_local.revoke()
        severed = None
        try:
            await session.send(care_local.proxy, "double", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), "revoke breaks a local call too"

        retained = session.published_ref("local-double")
        assert retained is not None and retained == local
        released_forward = session.caretaker(local)
        session.release(local)
        for invoke in (
            lambda: session.send(local, "double", [1]),
            lambda: session.tell(local, "double", [1]),
            lambda: session.send(released_forward.proxy, "double", [1]),
        ):
            try:
                await invoke()
            except (ValueError, VowBroken) as error:
                assert "released" in str(error), error
            else:
                raise AssertionError("a released occurrence invoked a still-live local target")
        assert await session.send(retained, "double", [21]) == 42
        session.release(retained)

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _mid_turn_driving_verb_breaks_the_answer() -> None:
    """The callback latch crosses the binding: a behavior that reaches for a
    host-driving verb mid-turn (publish, here) is refused by the C tier, the
    refusal surfaces as the behavior's own raise, and the answer breaks with
    it: the turn neither deadlocks nor corrupts the host. The connection
    stays fully usable afterwards."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    if verb == "reenter":
                        # A driving verb inside the turn: the latch refuses it
                        # and the raised GlowcapError's words become the broken
                        # answer.
                        session.publish("nested", lambda v, a: None)
                        return "unreachable"
                    return "pong"

                session.publish("svc", svc)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        broke = None
        try:
            await session.send(svc_ref, "reenter", [])
        except VowBroken as error:
            broke = error
        assert broke is not None, "a mid-turn driving verb breaks the answer"
        # The turn unwound cleanly: the same session still answers.
        pong = await session.send(svc_ref, "ping", [])
        assert pong == "pong", f"the connection survives the refused turn, got {pong!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _mid_turn_host_release_orders_sessions_before_host() -> None:
    """A behavior records driver-owned Host close intent immediately. Python
    schedules only the completion barrier. Native code owns session teardown."""
    host = Host()
    server = await tcp.listen("127.0.0.1", 0, host=host)
    loop = asyncio.get_running_loop()
    callback_errors = []
    prior_exception_handler = loop.get_exception_handler()
    loop.set_exception_handler(lambda _loop, context: callback_errors.append(context))
    accepted = asyncio.Event()
    during = loop.create_future()

    def svc(verb, args):
        if verb != "release-host":
            return None
        host._request_close()
        if not during.done():
            during.set_result(host.pending_release_count())
        return "closing"

    host.publish("svc", svc)

    async def accept_two() -> None:
        count = 0
        async for session in server:
            session.serve()
            count += 1
            if count == 2:
                accepted.set()
                break

    hosted = asyncio.ensure_future(accept_two())
    first = await tcp_connect(tcp.locator("127.0.0.1", server.port))
    first.serve()
    second = await tcp_connect(tcp.locator("127.0.0.1", server.port))
    second.serve()
    try:
        await asyncio.wait_for(accepted.wait(), timeout=5)
        cap = await first.fetch("svc")
        try:
            await first.send(cap, "release-host", [])
        except Exception:
            # Host teardown may close the wire before this answer arrives.
            pass
        assert await asyncio.wait_for(during, timeout=5) == 0, (
            "callback-time native close must not park binding teardown policy"
        )
        assert host.pending_release_count() == 0, "native-authoritative close leaves no binding release transaction"
        await asyncio.wait_for(hosted, timeout=5)
        await host.close()
        assert host._raw is None, "Host teardown retained native authority"
        assert not callback_errors, callback_errors
    finally:
        loop.set_exception_handler(prior_exception_handler)
        await first.close()
        await second.close()
        await server.close()
