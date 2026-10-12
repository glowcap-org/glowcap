"""The low-level transport seams: send_redeeming's direct exporter, the
fake SOCKS and Tor control daemons, loop-archive stepping parity, and
onion listen authentication."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar
import select
import socket
import threading

import glowcap

from glowcap import (
    tcp,
    Forward,
    Host,
    GlowcapError,
    SendRedeemingResult,
    Ref,
    VowBroken,
    Runtime,
)
from glowcap.onion import (
    AUTH_COOKIE,
    AUTH_PASSWORD,
    OnionConfig,
    OnionNetlayer,
    SERVICE_ID_LENGTH,
    listen as onion_listen,
    provider as onion_provider,
)

from smoke.runtime import tcp_connect



_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)


def _wait_for_native_call(owner, label: str) -> None:
    """Wait until a blocking wrapper has transferred one lease to native code."""
    native = owner._native
    with native._condition:
        entered = native._condition.wait_for(lambda: native._active != 0, timeout=1)
    if not entered:
        raise AssertionError(f"{label} did not acquire its native lease")


async def _send_redeeming_surfaces_the_direct_exporter() -> None:
    """A three-party handoff with glowcap as all three parties, over loopback:
    the exporter (Bob) publishes a Host publication inbox, the broker holds it
    and introduces members to it, and the recipient (Carol) asks for an
    introduction with ``send_redeeming``.

    The reply's ``via`` is the *direct* Carol-to-Bob session the binding opened
    to redeem the give, not the broker session Carol sent on. That is the one
    place a reply capability is valid, because a near export names a position
    in one specific CapTP session: Carol spawns her reply inbox on ``via``, and
    Bob answers by calling it back, so the message and its answer both travel
    over the direct connection while the broker stays out of the path. A
    second introduction resolves the same ``via`` with no fresh dial, which is
    what makes the attribution deterministic rather than a which-dial-ran
    guess."""
    delivered: list = []
    acked: list = []

    bob = await tcp.listen("127.0.0.1", 0)
    broker = await tcp.listen("127.0.0.1", 0)
    accepting: list = []
    try:

        def dm(verb, args):
            if verb == "dm":
                delivered.append(args[0])
                # Answer by calling back the capability the sender spawned. It
                # is a live export only in the session the redeemed token
                # routes to, so this call reaching Carol is the proof that
                # `via` named that session.
                return Forward(args[1], "note", [f"bob got {args[0]}"])
            return None

        bob.host.publish("dm", dm)

        async def accept_all(server) -> None:
            async for session in server:
                session.serve()

        accepting.append(asyncio.ensure_future(accept_all(bob)))
        accepting.append(asyncio.ensure_future(accept_all(broker)))

        # The broker dials Bob under its own identity and fetches his Host publication
        # inbox; returning that ref into a *different* session is what trips
        # the transparent gifter.
        broker_to_bob = await tcp_connect(tcp.locator("127.0.0.1", bob.port), host=broker.host)
        broker_to_bob.serve()
        bob_dm = await broker_to_bob.fetch("dm")

        # Replace the alias with a decoy before any introduction: the gift
        # must retain the exact inbox the broker holds, not whatever the name
        # resolves to at withdrawal (ADR-0096, on the binding path).
        decoy_delivered: list = []
        bob.host.publish(
            "dm",
            lambda verb, args: (decoy_delivered.append(args[0]) if verb == "dm" else None),
        )

        broker.host.publish(
            "introducer",
            lambda verb, args: bob_dm if verb == "introduce" else "no capability here",
        )

        # Keep Carol's Host on the byte-fed tier. The handoff redeem below must
        # open its exporter TCP channel on that same active Host; attempting to
        # transfer it into the driver would fail and split ownership.
        carol_locator = tcp.locator("127.0.0.1", broker.port)
        carol_host = Host()
        from glowcap.tcp import connector as tcp_connector

        runtime = await Runtime.open(
            adopt_host=carol_host,
            connector=tcp_connector(),
            handshake_timeout_ms=10_000,
        )
        carol = await runtime.connect(carol_locator)
        carol.serve()
        introducer = await carol.fetch("introducer")

        settled = await carol.send_redeeming(introducer, "introduce", [])
        assert isinstance(settled, SendRedeemingResult), settled
        reply, via = settled
        assert isinstance(reply, Ref), f"introduce returned a capability, got {reply!r}"
        assert via is not None, "the redeemed reply surfaces its direct exporter session"
        assert via is not carol, "`via` is the direct exporter session, not the broker one"
        assert via.host is carol.host, "the redeem shares Carol's Host"

        # The reply inbox is hosted where the reply lives, and the DM goes out
        # over that session's connection: Bob's answer is his call back into it.
        inbox = via.spawn(lambda verb, args: acked.append(args[0]))
        note = await via.send(reply, "dm", ["hello bob", inbox])
        assert delivered == ["hello bob"], f"the DM reached Bob directly, got {delivered!r}"
        assert acked == ["bob got hello bob"], f"Bob called the reply inbox back, got {acked!r}"
        assert note is None, f"the forwarded answer settles from the inbox, got {note!r}"
        assert decoy_delivered == [], f"the DM leaked to the alias's decoy, got {decoy_delivered!r}"

        # Deterministic re-redeem: the second introduction routes to the
        # exporter already dialed, so `via` is that same live session.
        again = await carol.send_redeeming(introducer, "introduce", [])
        assert again.via is via, "a re-redeem resolves the same exporter session, no second dial"

        # A reply that is no capability at all has no exporter to name.
        plain = await carol.send_redeeming(introducer, "ping", [])
        assert plain.reply == "no capability here", plain.reply
        assert plain.via is None, "a non-capability reply names no exporter session"

        await carol.close()
        await broker_to_bob.close()
    finally:
        for task in accepting:
            task.cancel()
        await broker.close()
        await bob.close()


# --- The onion transport, against a fake Tor daemon ---------------------------
#
# `glowcap.onion` is the one netlayer the OCapN draft standardizes. It reaches a
# Tor daemon the deployment runs, so exercising it here means standing one up: two
# loopback servers answering the exact requests glowcap sends. The bytes those
# requests must contain are pinned on the Zig side against the pinned Spritely
# Goblins netlayer and the upstream OCapN suite; this proves the Python surface
# reaches them and reads the answers back.

_ONION_SERVICE_ID = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd"
_ONION_SERVICE_KEY = b"ED25519-V3:c3RvcmVk"


def _fake_control(sock: "socket.socket", seen: list[str]) -> None:
    """Answer one control conversation, recording the AUTHENTICATE line.

    Recording the credential is the point of this fake. Every other assertion here
    uses an unauthenticated endpoint, where a mapping that sent no credential at all
    would look exactly like success.
    """
    conn, _ = sock.accept()
    with conn:
        pending = b""
        while True:
            try:
                chunk = conn.recv(1024)
            except OSError:
                return
            if not chunk:
                return
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                text = line.rstrip(b"\r").decode()
                if text.startswith("AUTHENTICATE") or text.startswith("ADD_ONION"):
                    seen.append(text)
                if text.startswith("ADD_ONION"):
                    reply = (
                        f"250-ServiceID={_ONION_SERVICE_ID}\r\n"
                        f"250-PrivateKey={_ONION_SERVICE_KEY.decode()}\r\n250 OK\r\n"
                    )
                else:
                    reply = "250 OK\r\n"
                try:
                    conn.sendall(reply.encode())
                except OSError:
                    return


def _loopback() -> "socket.socket":
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(4)
    return sock


def _address_of(sock: "socket.socket") -> str:
    host, port = sock.getsockname()
    return f"{host}:{port}"


# The SOCKS endpoint for the checks that never dial: an absolute Unix socket path,
# which is the other form OnionNetlayer accepts and the one a distribution's Tor
# offers. Nothing is bound there, so a check that reached it would fail
# rather than quietly connect somewhere.
_ABSENT_SOCKS = "/run/glowcap-smoke/absent.socks"


def _fake_socks(sock: "socket.socket", wrote: list[bytes]) -> None:
    """Answer one SOCKS5 handshake, then record the first bytes the dialer sent.

    The fake does not proxy. A real Tor splices the circuit onto the service's
    forward target. What the transport owes is that the stream is a transparent byte
    pipe positioned after the reply, so this stands in for the far peer directly.
    """
    conn, _ = sock.accept()
    with conn:
        # Version 5, one method, no authentication.
        assert _recv_exactly(conn, 3) == b"\x05\x01\x00"
        conn.sendall(b"\x05\x00")
        # Four header bytes, the length byte, the 62-character address, the port.
        request = _recv_exactly(conn, 69)
        assert request[:5] == b"\x05\x01\x00\x03\x3e", request[:5]
        assert request[5:67].decode() == f"{_ONION_SERVICE_ID}.onion"
        assert request[67:] == (9045).to_bytes(2, "big"), request[67:]
        # Success, reserved, IPv4, then the null bound address Tor reports.
        conn.sendall(b"\x05\x00\x00\x01" + bytes(6))
        wrote.append(conn.recv(256))


def _recv_exactly(conn: "socket.socket", count: int) -> bytes:
    out = b""
    while len(out) < count:
        chunk = conn.recv(count - len(out))
        if not chunk:
            raise AssertionError("the dialer closed mid-handshake")
        out += chunk
    return out


def _listen_with_auth(auth_kind: int, secret) -> str:
    """Drive one `listen` against a fake daemon and report the AUTHENTICATE line."""
    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    with OnionNetlayer(
        socks=_ABSENT_SOCKS,
        control=_address_of(control),
        auth_kind=auth_kind,
        auth_secret=secret,
    ) as nl:
        nl.listen().close()
    control.close()
    thread.join(timeout=2)
    authenticate = [line for line in seen if line.startswith("AUTHENTICATE")]
    assert authenticate, "the fake daemon saw no AUTHENTICATE"
    return authenticate[0]


def _loop_archive_stepping_parity() -> None:
    """The driver archive from Python (ADR-0112): two stepping loops,
    the server driven by a plain thread, the client parked on the readiness
    descriptor via asyncio: dial as an operation id, session as an OPENED event,
    vow outcomes as COMPLETION events routed through the adopted wrapper
    Host's vow table, and a hangup. The server publishes through its own
    wrapper Host, so the trampoline, the fetch's settle (a real ``Ref``),
    and a missing-name break (``VowBroken``) all cross the loop tier.
    """
    from glowcap._loop import DriverLoop
    from glowcap.relay import RelayConfig, connector as relay_connector

    # A managed WebSocket is only the carrier.  The byte-fed Host owns the
    # keyed/noise profile, so one connector truthfully advertises both.
    relay = relay_connector(RelayConfig.dial_only("ws://127.0.0.1:1"))
    assert relay.handles("keyed-relay")
    assert relay.handles("noise-relay")

    ready = threading.Event()
    stop = threading.Event()
    server_errors: list[BaseException] = []
    designator_box: list[str] = []

    def serve() -> None:
        try:
            server = DriverLoop.open(wire_buffer_bytes=1024, max_pending_opens=8)
            asyncio.run(tcp.provider().install(server))
            server.wrapper_host().publish("widget", lambda verb, args: "poked through the loop tier")
            listener = server.listen("tcp", "127.0.0.1:0")
            while not listener.ready and listener.failure is None:
                server.step(20)
            if listener.failure is not None:
                raise listener.failure
            server.select_listener(listener)
            designator_box.append(server.listener_locator(listener).designator)
            ready.set()
            while not stop.is_set():
                server.step(20)
                while (accepted := server.try_accept(listener)) is not None:
                    server.serve_session(accepted)
            server.close()
        except BaseException as exc:
            server_errors.append(exc)
            ready.set()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    assert ready.wait(10), "the loop server never bound"
    assert not server_errors, server_errors
    designator = designator_box[0]

    async def client() -> None:
        loop = DriverLoop.open()
        await tcp.provider().install(loop)
        loop.start()

        # The whole public Session surface over the loop tier: fetch settles
        # as a real Ref, an eventual-send round-trips through the server's
        # trampoline, a missing name classifies as VowBroken, and close
        # releases through the loop's own verb.
        session = await asyncio.wait_for(loop.connect_session(glowcap.format_peer_uri("tcp", designator)), 10)
        widget = await asyncio.wait_for(session.fetch("widget"), 10)
        assert isinstance(widget, Ref), widget
        reply = await asyncio.wait_for(session.send(widget, "poke", []), 10)
        assert reply == "poked through the loop tier", reply
        try:
            await asyncio.wait_for(session.fetch("nobody-home"), 10)
            raise AssertionError("fetching an unpublished name must break the vow")
        except VowBroken:
            pass
        await asyncio.wait_for(session.close(), 10)
        loop.close()

    asyncio.run(client())
    stop.set()
    thread.join(timeout=10)
    assert not thread.is_alive(), "the loop server thread did not stop"
    assert not server_errors, server_errors


def _onion_against_a_fake_daemon() -> None:
    # The generic driver retains the package callback context after the onion
    # constructor reference is dropped by the transport-owned installer.
    from glowcap._loop import DriverLoop

    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    loop = DriverLoop.open()
    try:
        asyncio.run(onion_provider(OnionConfig(_ABSENT_SOCKS, control=_address_of(control))).install(loop))
        assert loop._has_transport("onion")
        listener = loop.listen("onion", "")
        while not listener.ready and listener.failure is None:
            loop.step(20)
        if listener.failure is not None:
            raise listener.failure
        locator = loop.listener_locator(listener)
        assert locator.transport == "onion", locator
        assert locator.designator == _ONION_SERVICE_ID, locator
        assert loop.listener_restoration_state(listener) == _ONION_SERVICE_KEY
        loop.close_listener(listener)
    finally:
        loop.close()
        control.close()
        thread.join(timeout=2)
        assert not thread.is_alive(), "driver release did not close the onion control session"

    # The public composition owns only the generic driver listener and projects
    # its locator, Host wrapper, and opaque restoration state.
    control = _loopback()
    seen = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    supplied = Host()

    async def driver_server_surface() -> None:
        server = None
        try:
            server = await onion_listen(
                socks=_ABSENT_SOCKS,
                control=_address_of(control),
                host=supplied,
            )
            assert server.uri == f"ocapn://{_ONION_SERVICE_ID}.onion", server.uri
            assert server.service_id == _ONION_SERVICE_ID, server.service_id
            assert server.service_key == _ONION_SERVICE_KEY, server.service_key
            assert server.host is supplied
            assert server.__aiter__() is server
        finally:
            if server is not None:
                await server.close()
            if not supplied.released:
                await supplied.close()

    asyncio.run(driver_server_surface())
    control.close()
    thread.join(timeout=2)
    assert not thread.is_alive(), "driver server release did not close onion control"

    # Hosting reports the id the daemon named, and the key that restores it.
    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    with OnionNetlayer(socks=_ABSENT_SOCKS, control=_address_of(control)) as nl:
        listener = nl.listen()
        assert listener.service_id == _ONION_SERVICE_ID, listener.service_id
        assert len(listener.service_id) == SERVICE_ID_LENGTH
        assert listener.service_key == _ONION_SERVICE_KEY, listener.service_key

        # The readiness descriptor must be the live accept socket, not merely a
        # number. Nothing has dialed, so selecting on it reports not-ready and an
        # accept would park.
        fd = listener.readiness_fd()
        assert fd >= 0, fd
        assert select.select([fd], [], [], 0.05) == ([], [], []), "readable with no circuit"

        # Stand in for Tor forwarding a circuit: connect to the local endpoint the
        # listener bound and told the daemon about.
        add_onion = next(line for line in seen if line.startswith("ADD_ONION"))
        # `PORT=<virtual>,<target>`: the target is what follows the comma.
        forward = add_onion.split("PORT=", 1)[1].split(",", 1)[1]
        host, port = forward.rsplit(":", 1)
        with socket.create_connection((host, int(port))):
            # Now the same descriptor reports arrival, so accept returns rather than
            # parking.
            ready, _, _ = select.select([fd], [], [], 2.0)
            assert ready == [fd], "not readable after a circuit arrived"
            assert listener.wait(1000) is True
            accepted = listener.accept()
            assert accepted.readiness_fd() >= 0
            accepted.close()
        # Releasing the owner closes every child before its std.Io backend.
        nl.release()
        try:
            listener.readiness_fd()
            raise AssertionError("an owner-released listener remained callable")
        except RuntimeError:
            pass
        listener.close()  # idempotent after owner-driven release
    control.close()
    thread.join(timeout=2)

    # ctypes releases the GIL around CDLL calls. Owner release must therefore
    # interrupt an accept already parked in native code, wait for its lease to
    # return, and only then free the listener and netlayer storage.
    control = _loopback()
    seen = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    nl = OnionNetlayer(socks=_ABSENT_SOCKS, control=_address_of(control))
    listener = nl.listen()
    entered = threading.Event()
    accept_errors: list[BaseException] = []

    def blocked_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_accept, daemon=True)
    accepter.start()
    assert entered.wait(1), "the accept thread did not start"
    _wait_for_native_call(listener, "onion accept")
    assert accepter.is_alive(), "the empty listener did not block accept"
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "owner release did not drain blocked accept"
    assert accept_errors, "shutdown did not report the interrupted accept"
    control.close()
    thread.join(timeout=2)

    # Each credential form reaches the daemon as itself.
    assert _listen_with_auth(0, None) == "AUTHENTICATE"
    assert _listen_with_auth(AUTH_COOKIE, bytes([0x00, 0x01, 0x0F, 0xFF])) == "AUTHENTICATE 00010fff"
    assert _listen_with_auth(AUTH_PASSWORD, "hunter2") == 'AUTHENTICATE "hunter2"'

    # The dial half: a circuit carries a framed message. What reaches the wire is
    # the frame inside its netstring envelope, a Syrup byte string whose length
    # prefix the reader strips again.
    socks = _loopback()
    wrote: list[bytes] = []
    dialer = threading.Thread(target=_fake_socks, args=(socks, wrote), daemon=True)
    dialer.start()
    with OnionNetlayer(socks=_address_of(socks)) as nl:
        conn = nl.connect(_ONION_SERVICE_ID)
        payload = b"<8'op:abort3\"bye>"
        conn.write_frame(payload)
        dialer.join(timeout=2)
        assert wrote == [b"%d:%s" % (len(payload), payload)], wrote
        conn.close()
    socks.close()

    # A dial-only netlayer can reach out and cannot host.
    with OnionNetlayer(socks=_ABSENT_SOCKS) as nl:
        try:
            nl.listen()
            raise AssertionError("a dial-only netlayer should not host")
        except GlowcapError:
            pass
        # A designator that is not a well-formed version 3 address is refused before
        # any socket opens, so this is an argument fault rather than a dial failure.
        try:
            nl.connect("not-an-onion-address")
            raise AssertionError("a malformed designator should be refused")
        except GlowcapError:
            pass
