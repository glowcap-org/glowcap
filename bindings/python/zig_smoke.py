"""Python dogfood of the Zig pancake C ABI archives, through the idiomatic
``pancake`` module: drive OCapN with native Python values, no FFI in sight.
The public ``connect`` / ``listen`` scenarios run over the native loop
archive (``libpancake_driver``, ADR-0112); the keyed-relay byte seam is tested
only through its explicit low-level adapter. This is the consumer ``zig build
bindings`` runs."""


from __future__ import annotations

import asyncio
from contextvars import ContextVar
import gc
import sys
import socket
import threading
import time

import ctypes
import pancake._host as _host_module
from pancake._lifecycle import _lifecycle_closed

from pancake import (
    tcp,
    Context,
    FailureLayer,
    FailureScope,
    Locator,
    Host,
    PancakeError,
    Ref,
    abi_version,
    Runtime,
    format_sturdyref,
    parse_sturdyref,
)
from pancake._constants import (
    ERR_INVALID_ARGUMENT,
    ERR_INTERNAL,
    ERR_IO,
    FAILURE_LAYER_TRANSPORT,
    FAILURE_SCOPE_LISTENER,
    LIFECYCLE_ACTIVE,
    LIFECYCLE_CLOSED,
)
from pancake._constants import _provenance_from_abi
from pancake.inproc import InprocNetlayer
from pancake._trampoline import _entry_for
from pancake.tcp import TcpNetlayer



from smoke import conversation, failures, lifecycle, runtime, transports, verbs

_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)

def main() -> int:
    assert not _lifecycle_closed(LIFECYCLE_ACTIVE)
    assert _lifecycle_closed(LIFECYCLE_CLOSED)
    for decode in (_lifecycle_closed, _provenance_from_abi):
        try:
            decode(0xFFFF_FFFF)
        except (PancakeError, ValueError):
            pass
        else:
            raise AssertionError("unknown native discriminant was normalized")
    failures._stale_archive_is_refused_before_use()
    failures._driver_failure_preserves_carrier_detail()
    failures._gc_release_refusal_stays_owned()
    asyncio.run(failures._websocket_close_failure_is_observable())
    print("python zig-smoke OK: WebSocket close retains its exact async failure")
    asyncio.run(failures._host_owns_async_behavior_settlement_failure())
    print("python zig-smoke OK: Host shutdown owns async behavior settlement failure")
    asyncio.run(failures._iroh_readiness_failure_settles_waiters_exactly())
    print("python zig-smoke OK: iroh readiness faults settle every waiter exactly")
    asyncio.run(failures._local_tell_failure_belongs_to_host())
    print("python zig-smoke OK: local tell failure enters its Host diagnostic seam")
    failures._native_finalizer_failure_is_nonfatal_and_observable()
    print("python zig-smoke OK: native finalizer failures stay nonfatal and observable")
    failures._allocator_callback_exceptions_are_contained()
    print("python zig-smoke OK: allocator callback exceptions stay nonfatal and observable")
    runtime.run_managed(runtime._connector_install_is_transactional())
    runtime.run_managed(runtime._cancelled_dial_does_not_report_failure())
    runtime.run_managed(runtime._driver_completion_preserves_failure_category())
    runtime.run_managed(runtime._runtime_open_is_transactional())
    print("python zig-smoke OK: Runtime.open preserves caller-owned Hosts across failed provider setup")
    print("python zig-smoke OK: connector installation is transactional")
    sturdyref = parse_sturdyref(
        "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/"
        "eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU",
        "v1_0",
    )
    assert sturdyref.locator.transport == "onion"
    assert sturdyref.swissnum == bytes.fromhex(
        "79 08 cf e2 74 76 f1 f7 d7 e5 ea 0d 08 ae 43 58 7e 83 4f f7 7b 04 8a 83 df e3 32 e3 9f 42 51 b5"
    )
    formatted_sturdyref = format_sturdyref(
        tcp.locator("127.0.0.1", 9045),
        b"durable:0123456789abcdef",
        "next",
    )
    assert parse_sturdyref(formatted_sturdyref, "next").swissnum == b"durable:0123456789abcdef"

    try:
        Ref(1)
        raise AssertionError("application code must not construct capability ids")
    except TypeError:
        pass

    # The linked library reports a nonzero ABI version.
    major, minor, patch = abi_version()
    assert major + minor + patch > 0, (major, minor, patch)

    with Context() as diagnostic_context:
        diagnostic_context._report_failure(
            layer=FAILURE_LAYER_TRANSPORT,
            scope=FAILURE_SCOPE_LISTENER,
            operation="listener.close",
            primary_name="CloseFailed",
            primary_result=ERR_IO,
            primary_message="socket refused shutdown",
            scope_id=31,
            operation_id=47,
            secondary_result=ERR_INTERNAL,
            secondary_name="ReleaseFailed",
            secondary_message="descriptor remained live",
            secondary_count=2,
        )
        taken = diagnostic_context.take_failures()
        assert len(taken) == 1, taken
        failure = taken[0]
        assert failure.sequence == 1 and failure.dropped_before == 0, failure
        assert failure.layer is FailureLayer.TRANSPORT, failure
        assert failure.scope is FailureScope.LISTENER, failure
        assert failure.scope_id == 31 and failure.operation_id == 47, failure
        assert failure.primary_result == ERR_IO, failure
        assert failure.secondary_result == ERR_INTERNAL, failure
        assert failure.secondary_count == 2, failure
        assert failure.operation == "listener.close", failure
        assert failure.primary_name == "CloseFailed", failure
        assert failure.primary_message == "socket refused shutdown", failure
        assert failure.secondary_name == "ReleaseFailed", failure
        assert failure.secondary_message == "descriptor remained live", failure
        assert diagnostic_context.next_failure() is None
    print("python zig-smoke OK: Context preserves the cross-language native failure vector exactly once")

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
    assert stopped_host.released, "release must not queue cleanup onto a stopped event loop"
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

    stopped_work_host = stopped_work_loop.run_until_complete(make_host_with_active_work())
    stopped_work_loop.run_until_complete(stopped_work_host.close())
    assert stopped_work_finished, "CANCEL_DIAL did not join its ticketed task"
    assert stopped_work_host._raw is None, "stopped-loop close retained the native Host after joining work"
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
    finalized, finalized_ctx = finalizer_loop.run_until_complete(make_finalizable_host())
    handoff = [finalized]
    del finalized
    finalizer_loop.close()

    def collect_host() -> None:
        handoff.pop()
        gc.collect()

    collector = threading.Thread(target=collect_host)
    collector.start()
    collector.join()
    assert _entry_for(finalized_ctx) is None, "off-thread Host finalization must retire native and trampoline authority"

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
        assert _host_module._pending_finalizer_retry_count() == 1
        _host_module._drain_deferred_finalizer_states()
        assert retry_state.raw is None
        assert _host_module._pending_finalizer_retry_count() == 0
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
        assert isinstance(cleanup, PancakeError) and cleanup.code == ERR_INVALID_ARGUMENT
        assert construction_context.released == 0, (
            "pre-commit construction cleanup freed the borrowed Context"
        )
        assert _host_module._pending_finalizer_retry_count() == 1
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
        assert consumed_state.raw is None, "a consumed Host release retained a dangling pointer"
        assert _host_module._pending_finalizer_retry_count() == 0
        assert len(reports) == 1 and reports[0]["scope_id"] == 73, reports
        assert reports[0]["operation"] == "host.finalizer.release", reports
    finally:
        _host_module._host.pancake_host_release = original_host_release

    # Run a real frame over a TCP socket: one frame, loopback. The blocking TCP
    # shuttle is its own à-la-carte archive, composed from `pancake.tcp`.
    with TcpNetlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        port = listener.port()
        received: list[bytes] = []

        def serve() -> None:
            accepted = listener.accept()
            received.append(accepted.read_frame())
            accepted.close()

        thread = threading.Thread(target=serve)
        thread.start()
        client = nl.connect("127.0.0.1", port)
        client.write_frame(b"<8'op:abort3\"bye>")
        thread.join()
        assert received == [b"<8'op:abort3\"bye>"], received
    assert client._native.closed and listener._native.closed, (
        "TCP netlayer release must retire its borrowed child handles first"
    )
    client.close()
    listener.close()

    # A dropped wrapper still owns its native handle. Listener collection must
    # stop accepting, and endpoint collection must close the connected socket;
    # otherwise the parent's WeakSet silently forgets leaked C authority.
    with TcpNetlayer() as nl:
        orphan_listener = nl.listen("127.0.0.1", 0)
        orphan_port = orphan_listener.port()
        del orphan_listener
        gc.collect()
        with socket.socket() as probe:
            probe.settimeout(1)
            assert probe.connect_ex(("127.0.0.1", orphan_port)) != 0

        listener = nl.listen("127.0.0.1", 0)
        peer = socket.create_connection(("127.0.0.1", listener.port()), timeout=1)
        orphan_endpoint = listener.accept()
        del orphan_endpoint
        gc.collect()
        peer.settimeout(1)
        assert peer.recv(1) == b""
        peer.close()
        listener.close()

    # ctypes may release the GIL in every blocking transport call. Closing a
    # connection or its owner must interrupt a blocked read, join that lease,
    # and only then free native storage.
    nl = TcpNetlayer()
    listener = nl.listen("127.0.0.1", 0)
    peer = socket.create_connection(("127.0.0.1", listener.port()), timeout=1)
    accepted = listener.accept()
    entered = threading.Event()
    read_errors: list[BaseException] = []

    def blocked_tcp_read() -> None:
        entered.set()
        try:
            accepted.read_frame()
        except BaseException as exc:
            read_errors.append(exc)

    reader = threading.Thread(target=blocked_tcp_read, daemon=True)
    reader.start()
    assert entered.wait(1)
    time.sleep(0.05)
    accepted.close()
    reader.join(timeout=2)
    assert not reader.is_alive(), "TCP close did not join a blocked read"
    assert read_errors, "TCP shutdown did not interrupt a blocked read"
    peer.close()
    listener.close()
    nl.release()

    nl = TcpNetlayer()
    listener = nl.listen("127.0.0.1", 0)
    entered = threading.Event()
    accept_errors: list[BaseException] = []

    def blocked_tcp_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_tcp_accept, daemon=True)
    accepter.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "TCP owner release did not join a blocked accept"
    assert accept_errors, "TCP listener shutdown did not interrupt a blocked accept"

    # The socket-free in-process transport is its own archive too, surfaced as
    # `pancake.inproc`: a listener binds an opaque designator and a dialer names
    # it, the same frame shuttle as TCP, no kernel socket touched.
    with InprocNetlayer() as nl:
        listener = nl.listen("smoke")
        received_inproc: list[bytes] = []

        def serve_inproc() -> None:
            accepted = listener.accept()
            received_inproc.append(accepted.read_frame())
            accepted.close()

        thread = threading.Thread(target=serve_inproc)
        thread.start()
        client = nl.connect("smoke")
        client.write_frame(b"<8'op:abort3\"bye>")
        thread.join()
        assert received_inproc == [b"<8'op:abort3\"bye>"], received_inproc
    assert client._native.closed and listener._native.closed, (
        "inproc netlayer release must retire its borrowed child handles first"
    )
    client.close()
    listener.close()

    with InprocNetlayer() as nl:
        orphan_listener = nl.listen("orphan-smoke")
        del orphan_listener
        gc.collect()
        try:
            nl.connect("orphan-smoke")
        except PancakeError:
            pass
        else:
            raise AssertionError("a collected inproc listener kept native authority")

    nl = InprocNetlayer()
    listener = nl.listen("blocked-read")
    client = nl.connect("blocked-read")
    accepted = listener.accept()
    entered = threading.Event()
    read_errors = []

    def blocked_inproc_read() -> None:
        entered.set()
        try:
            accepted.read_frame()
        except BaseException as exc:
            read_errors.append(exc)

    reader = threading.Thread(target=blocked_inproc_read, daemon=True)
    reader.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    reader.join(timeout=2)
    assert not reader.is_alive(), "inproc owner release did not join a blocked read"
    assert read_errors, "inproc shutdown did not interrupt a blocked read"
    client.close()

    nl = InprocNetlayer()
    listener = nl.listen("blocked-accept")
    entered = threading.Event()
    accept_errors = []

    def blocked_inproc_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_inproc_accept, daemon=True)
    accepter.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "inproc owner release did not join a blocked accept"
    assert accept_errors, "inproc listener shutdown did not interrupt a blocked accept"

    print("python zig-smoke OK: the blocking TCP and in-process transports shuttled a frame")

    transports._onion_against_a_fake_daemon()
    print("python zig-smoke OK: the onion transport reached a fake Tor and reported its service")

    transports._loop_archive_stepping_parity()
    print(
        "python zig-smoke OK: the public Session surface ran over the driver archive — connect, fetch, an eventual-send round trip, VowBroken, and close"
    )

    runtime.run_managed(conversation._allocator_context_round_trip())
    print("python zig-smoke OK: drove a published counter round-trip from a context-backed Host")

    runtime.run_managed(conversation._live_trace_produces_timeline())
    print("python zig-smoke OK: the live trace produced the timeline schema for a whole conversation")

    runtime.run_managed(conversation._async_behavior_defers())
    print("python zig-smoke OK: an async behavior deferred its answer onto a resolver vow and settled off-turn")

    runtime.run_managed(conversation._capnp_codec_round_trip())
    print("python zig-smoke OK: a capnp session opens and big-integer + keyword args round-trip")

    runtime.run_managed(conversation._empty_codec_is_not_the_default())
    print("python zig-smoke OK: an empty codec offer is refused, not rewritten as Syrup")

    runtime.run_managed(conversation._feed_refusals_are_typed())
    print("python zig-smoke OK: an over-cap frame refuses typed and a refused frame carries its abort cause")

    runtime.run_managed(conversation._tightened_admission_cap_refuses())
    print("python zig-smoke OK: a tightened session limit refuses a frame the default cap admits")

    runtime.run_managed(conversation._disconnect_rejects_pending_send())
    print("python zig-smoke OK: an outstanding send rejects on disconnect")

    runtime.run_managed(lifecycle._listen_surfaces_bound_port())
    print("python zig-smoke OK: high-level listen() surfaces the bound port and accepts")

    runtime.run_managed(lifecycle._rude_probe_cannot_close_the_listener())
    print("python zig-smoke OK: a rude probe cannot close the listener")

    runtime.run_managed(lifecycle._supplied_host_tcp_listener_ownership())
    print("python zig-smoke OK: supplied TCP Hosts transfer to the driver transactionally")

    runtime.run_managed(lifecycle._failed_listener_preserves_supplied_host())
    print("python zig-smoke OK: failed listener setup preserves its supplied Host for retry")

    runtime.run_managed(lifecycle._listener_close_preserves_sibling())
    print("python zig-smoke OK: closing one listener preserves a sibling listener")

    runtime.run_managed(lifecycle._host_release_joins_dial_task())
    print("python zig-smoke OK: Host close joins every registered DIAL task")

    runtime.run_managed(lifecycle._supplied_host_iroh_listener_ownership())
    print("python zig-smoke OK: supplied iroh Hosts transfer to the resident driver")

    runtime.run_managed(lifecycle._proof_refusal_releases_minted_session())
    print("python zig-smoke OK: proof refusal releases the newly minted session")

    runtime.run_managed(lifecycle._cancelled_iroh_open_releases_constructed_endpoint())
    print("python zig-smoke OK: canceled iroh startup joins and releases its endpoint")

    runtime.run_managed(lifecycle._iroh_close_joins_after_cancellation())
    print("python zig-smoke OK: canceled iroh close still joins native teardown")

    runtime.run_managed(lifecycle._session_close_joins_owned_transport_release())
    print("python zig-smoke OK: Session.close joins owned transport teardown")

    runtime.run_managed(lifecycle._session_repeated_close_joins_published_failure())
    print("python zig-smoke OK: repeated Session.close joins its published failure")

    runtime.run_managed(lifecycle._session_close_retains_every_terminal_failure())
    print("python zig-smoke OK: Session.close retains every terminal failure in order")

    runtime.run_managed(lifecycle._session_wire_failure_is_exact_and_retired())
    print("python zig-smoke OK: Session wire failure is exact and joins retirement")

    runtime.run_managed(lifecycle._host_close_joins_session_transport_failure())
    print("python zig-smoke OK: Host close preserves a session transport-close failure")

    runtime.run_managed(lifecycle._cancelled_session_close_waiter_does_not_stop_driver())
    print("python zig-smoke OK: canceled Session.close waiter leaves the shared close driver running")

    runtime.run_managed(lifecycle._repeated_host_close_observes_recorded_timeout())
    print("python zig-smoke OK: repeated Host.close observes the recorded finish timeout")

    runtime.run_managed(lifecycle._loop_finish_close_reports_finite_grace_timeout())
    print("python zig-smoke OK: a loop finish close that outlives its finite grace reports the typed timeout")

    runtime.run_managed(lifecycle._silent_loop_dial_reaches_native_handshake_deadline())
    print("python zig-smoke OK: a silent loop dial reaches pancake's native handshake deadline")

    runtime.run_managed(lifecycle._host_close_shuts_a_still_open_listener())
    print("python zig-smoke OK: Host.close completes over an open listener and ends its accept stream")

    runtime.run_managed(verbs._structured_args_round_trip())
    print("python zig-smoke OK: a Set round-trips as a Set, a nested capability stays sendable, a break is typed")

    runtime.run_managed(verbs._enliven_round_trips_then_caches())
    print("python zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache")

    runtime.run_managed(verbs._gc_releases_projected_capabilities())
    print("python zig-smoke OK: GC releases fetched, replied, and delivered capability occurrences")

    runtime.run_managed(verbs._fetch_failed_is_typed())
    print("python zig-smoke OK: a non-capability fetch raises the typed FetchFailed")

    runtime.run_managed(verbs._pipelining_drives_chain())
    print("python zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch")

    runtime.run_managed(verbs._turn_spawn_survives_originating_port_close())
    print("python zig-smoke OK: turn-time spawn uses the Host after the originating Port closes")

    runtime.run_managed(verbs._unawaited_break_stays_silent())
    print("python zig-smoke OK: an unawaited send is an asyncio.Future whose far break stays silent")

    runtime.run_managed(verbs._projections_reach_a_field())
    print(
        "python zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles"
    )

    runtime.run_managed(verbs._forwarding_proxies_over_the_wire())
    print("python zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire")

    runtime.run_managed(verbs._forwarding_proxy_local_call())
    print("python zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)")

    runtime.run_managed(verbs._mid_turn_driving_verb_breaks_the_answer())
    print("python zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer")

    runtime.run_managed(verbs._mid_turn_host_release_orders_sessions_before_host())
    print("python zig-smoke OK: callback-time Host close records native intent")

    runtime.run_managed(transports._send_redeeming_surfaces_the_direct_exporter())
    print(
        "python zig-smoke OK: send_redeeming surfaces the redeemed exporter session, and a reply capability hosted on it routes"
    )
    return 0



if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"python zig-smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
