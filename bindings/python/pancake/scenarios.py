"""Verification scenarios for the pancake-python bindings.

Run via ``python -m pancake.scenarios [scenario]`` (default: ``all``). The
load-bearing one is :func:`handshake_tcp_loopback`: two Ed25519-keyed peers
over TCP loopback that both reach ``SESSION_OPEN``.
"""

from __future__ import annotations

import sys
import threading
import time

from .constants import (
    PANCAKE_ARG_INTEGER,
    PANCAKE_ARG_LIST,
    PANCAKE_ARG_STRING,
    PANCAKE_CODEC_SYRUP,
    PANCAKE_FRAME_COMPLETE,
    PANCAKE_SESSION_OPEN,
    session_state_name,
)
from .host import Runtime
from .netlayer import WOULD_BLOCK, TcpNetlayer
from .pump import Bridge, both_open, run_until
from .values import (
    arg_integer,
    arg_list,
    arg_string,
    marshal_arguments,
    project_argument_addr,
    to_native,
)
import ctypes
from .values import PancakeArgument


def _seed(label: str) -> bytes:
    b = bytearray(32)
    src = label.encode("utf-8")[:32]
    b[: len(src)] = src
    return bytes(b)


def version(rt: Runtime = None) -> str:
    rt = rt or Runtime()
    v = rt.version()
    print(f"[version] pancake_version() = {v!r}")
    assert v.startswith("pancake-ffi"), f"unexpected version string {v!r}"
    print("OK: version")
    return v


def ocapn_uri_parse(rt: Runtime = None) -> None:
    rt = rt or Runtime()
    print("[uri] parsing peer-locator form…")
    u1 = rt.ocapn_uri_parse(
        "ocapn://IO58l1laTyhcrgDKbEzFOO32MDd6zE5w.tcp-testing-only?host=127.0.0.1&port=22045"
    )
    assert u1.transport == "tcp-testing-only", u1
    assert u1.designator == "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w", u1
    assert u1.swissnum is None, u1
    print(f"  ✓ transport={u1.transport!r} designator={u1.designator!r} swissnum=None")

    print("[uri] parsing OCapN spec sturdyref form…")
    u2 = rt.ocapn_uri_parse("ocapn://abc.iroh/s/AAECA__-_fw")
    assert u2.transport == "iroh", u2
    assert u2.designator == "abc", u2
    assert u2.swissnum == bytes([0, 1, 2, 3, 0xFF, 0xFE, 0xFD, 0xFC]), u2
    print(f"  ✓ transport={u2.transport!r} designator={u2.designator!r} swissnum={u2.swissnum!r}")

    print("[uri] asserting non-ocapn scheme is rejected…")
    rejected = False
    try:
        rt.ocapn_uri_parse("http://example.com/")
    except Exception as e:  # noqa: BLE001
        rejected = True
        print(f"  ✓ rejected: {e}")
    assert rejected, "http:// URL should have been rejected"
    print("OK: ocapn-uri-parse")


def value_roundtrip(rt: Runtime = None) -> None:
    """Build an Argument list, marshal it, project it back, assert equality."""
    print("[value] building mixed String/Integer/nested-List args…")
    original = [
        arg_list(
            [
                arg_string("hello"),
                arg_integer(42),
                arg_list([arg_string("nested-a"), arg_string("nested-b")]),
            ]
        )
    ]
    keepalive: list = []
    arr, n = marshal_arguments(original, keepalive)
    assert n == 1
    base = ctypes.addressof(arr)
    size = ctypes.sizeof(PancakeArgument)
    projected = [project_argument_addr(base + i * size) for i in range(n)]
    native_in = [to_native(a) for a in original]
    native_out = [to_native(a) for a in projected]
    print(f"  marshalled+projected: {native_out}")
    assert native_in == native_out, f"round-trip mismatch:\n in={native_in}\nout={native_out}"
    # spot-check the typed shape survived
    top = projected[0]
    assert top.kind == PANCAKE_ARG_LIST
    inner = top.payload
    assert inner[0].kind == PANCAKE_ARG_STRING and inner[0].payload == "hello"
    assert inner[1].kind == PANCAKE_ARG_INTEGER and inner[1].payload == 42
    assert inner[2].kind == PANCAKE_ARG_LIST and len(inner[2].payload) == 2
    print("OK: value-roundtrip (String / Integer / nested-List intact)")


def syrup_frame_probe(rt: Runtime = None) -> None:
    rt = rt or Runtime()
    print("[frame-probe] probing a complete Syrup integer frame…")
    # Syrup encodes a non-negative integer N as "<N>+"; 42 → b"42+".
    buf = b"42+trailing-junk"
    outcome, end = rt.syrup_frame_probe(buf)
    assert outcome == PANCAKE_FRAME_COMPLETE, (outcome, end)
    assert end == 3, end  # "42+" is 3 bytes
    print(f"  ✓ COMPLETE at end={end} (frame = {buf[:end]!r})")
    print("OK: syrup-frame-probe")


def handshake_tcp_loopback(
    host: str = "127.0.0.1", timeout_s: float = 10.0, tls: bool = False
) -> None:
    """Two Ed25519-keyed peers over TCP loopback; both reach SESSION_OPEN."""
    transport = "tcp-tls" if tls else "tcp-testing-only"
    rt = Runtime()
    print(f"[loopback] pancake version: {rt.version()} (transport={transport})")
    tcp = TcpNetlayer()
    do_listen = tcp.tls_listen if tls else tcp.listen
    do_connect = tcp.tls_connect if tls else tcp.connect

    # 1. Server listens on an OS-chosen port.
    listener = do_listen(host, 0)
    bound = listener.bound_addr
    print(f"[loopback] server listening on {bound}")

    # 2. Dialer connects on a background thread. For tcp-tls the connect
    #    blocks on the TLS handshake inline, which only completes once the
    #    server accepts — so connect + accept must run concurrently. ctypes
    #    releases the GIL during the foreign call, so the accept loop below
    #    runs in parallel. (Cleartext connect returns immediately; threading
    #    it is harmless.)
    dial_result = {}

    def dial():
        try:
            dial_result["conn"] = do_connect(*_split_addr(bound))
        except Exception as e:  # noqa: BLE001
            dial_result["error"] = e

    dial_thread = threading.Thread(target=dial, name="loopback-dialer", daemon=True)
    dial_thread.start()

    # 3. Server accepts the inbound connection.
    server_conn = None
    accept_deadline = time.monotonic() + 5.0
    while server_conn is None:
        got = listener.accept_timed(200)
        if got is not WOULD_BLOCK:
            server_conn = got
            break
        if time.monotonic() > accept_deadline:
            raise TimeoutError("server never accepted the loopback connection")
    listener.close()
    print("[loopback] server accepted")

    dial_thread.join(timeout=5.0)
    if "error" in dial_result:
        raise dial_result["error"]
    dialer_conn = dial_result.get("conn")
    if dialer_conn is None:
        raise TimeoutError("dialer connect did not complete")
    print(f"[loopback] dialer connected to {bound}")

    # 4. Construct two Ed25519-keyed peers (production handshake path).
    dialer_kp = rt.keypair_from_seed(_seed("python-dialer"))
    server_kp = rt.keypair_from_seed(_seed("python-server"))
    print(f"[loopback] dialer pubkey[:4]={dialer_kp.pubkey()[:4].hex()} "
          f"server pubkey[:4]={server_kp.pubkey()[:4].hex()}")
    dialer = rt.peer_new(dialer_kp, PANCAKE_CODEC_SYRUP)
    server = rt.peer_new(server_kp, PANCAKE_CODEC_SYRUP)
    print(f"[loopback] dialer my-peer-id[:4]={dialer.get_my_peer_id()[:4].hex()} "
          f"server my-peer-id[:4]={server.get_my_peer_id()[:4].hex()}")

    # 5. Bridges. The dialer enqueues its start-session first (run_until
    #    sends start-session in list order).
    dialer_bridge = Bridge(
        dialer, dialer_conn, transport, "client-side-no-listen", "dialer"
    )
    server_bridge = Bridge(
        server, server_conn, transport, bound, "server"
    )

    last_states = [None, None]

    def trace():
        states = [dialer.session_state(), server.session_state()]
        if states != last_states:
            print(f"[loopback] states: dialer={session_state_name(states[0])} "
                  f"server={session_state_name(states[1])}")
            last_states[0], last_states[1] = states

    # 6. Pump both round-robin until BOTH reach Open.
    run_until(
        [dialer_bridge, server_bridge],
        both_open([dialer_bridge, server_bridge]),
        timeout_s=timeout_s,
        on_tick=trace,
    )
    assert dialer.session_state() == PANCAKE_SESSION_OPEN
    assert server.session_state() == PANCAKE_SESSION_OPEN
    print("[loopback] ✓ BOTH peers reached SESSION_OPEN")

    # 7. Drain SessionEstablished events for the partner locators / pubkeys.
    for label, peer in (("dialer", dialer), ("server", server)):
        peer.step()
        ev = peer.poll_event_session_established()
        if ev:
            pubkey, locator = ev
            print(f"[loopback] {label} SessionEstablished — partner pubkey[:4]="
                  f"{pubkey[:4].hex()} locator={locator!r}")
        pid = peer.get_partner_peer_id()
        if pid:
            print(f"[loopback] {label} learned partner-peer-id[:4]={pid[:4].hex()}")

    # 8. Teardown.
    dialer.free()
    server.free()
    dialer_conn.close()
    server_conn.close()
    print("OK: handshake-tcp-tls-loopback" if tls else "OK: handshake-tcp-loopback")


def handshake_tcp_tls_loopback(host: str = "127.0.0.1", timeout_s: float = 10.0) -> None:
    """Same as :func:`handshake_tcp_loopback` but over the rustls TLS surface."""
    handshake_tcp_loopback(host=host, timeout_s=timeout_s, tls=True)


def _split_addr(addr: str):
    host, _, port = addr.rpartition(":")
    return host, int(port)


SCENARIOS = {
    "version": version,
    "ocapn-uri-parse": ocapn_uri_parse,
    "value-roundtrip": value_roundtrip,
    "syrup-frame-probe": syrup_frame_probe,
    "handshake-tcp-loopback": handshake_tcp_loopback,
    "handshake-tcp-tls-loopback": handshake_tcp_tls_loopback,
}


def run_all() -> None:
    rt = Runtime()
    version(rt)
    print()
    ocapn_uri_parse(rt)
    print()
    value_roundtrip(rt)
    print()
    syrup_frame_probe(rt)
    print()
    handshake_tcp_loopback()
    print()
    print("=" * 60)
    print("ALL SCENARIOS PASSED")
    print("=" * 60)


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    name = argv[0] if argv else "all"
    if name == "all":
        run_all()
        return 0
    fn = SCENARIOS.get(name)
    if not fn:
        print(f"unknown scenario {name!r}; choices: all, {', '.join(SCENARIOS)}")
        return 2
    fn()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
