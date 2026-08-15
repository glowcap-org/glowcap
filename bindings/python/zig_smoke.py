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
import re
import sys
import select
import socket
import threading
import time

import ctypes
import pancake
import pancake._host as _host_module
import pancake._loop as _loop_module
from pancake._gc import HostGc
from pancake._lifecycle import _close_options
from pancake._errors import _retain_cleanup_failure, _retain_terminal_failure
from pancake._failure import _RuntimeFailureQueue
from pancake._server import _rollback_listener_construction

from pancake import (
    tcp,
    Context,
    FetchFailed,
    FailureLayer,
    FailureScope,
    Forward,
    Keyword,
    Locator,
    Host,
    PancakeError,
    PendingWork,
    SendRedeemingResult,
    Ref,
    Set,
    Symbol,
    Tagged,
    VowBroken,
    abi_version,
    Runtime,
    encode_peer_locator,
    format_locator_uri,
    format_sturdyref,
    parse_locator,
    parse_sturdyref,
)
from pancake._transport import Connector, Provider
from pancake._native import NativeHandle
from pancake._ws import _WebSocketTransport
from pancake._constants import (
    DESIGNATOR_SCHEME_ADDRESS,
    ERR_CLOSED,
    ERR_FRAME_TOO_LARGE,
    ERR_INVALID_ARGUMENT,
    ERR_INTERNAL,
    ERR_IO,
    ERR_NULL_POINTER,
    ERR_TIMEOUT,
    FAILURE_LAYER_TRANSPORT,
    FAILURE_SCOPE_LISTENER,
    TRANSPORT_KEYED_TCP,
    TRANSPORT_NOISE_TCP,
    TRANSPORT_TCP,
)
from pancake.inproc import InprocNetlayer
from pancake._trampoline import _entry_for
from pancake.onion import (
    AUTH_COOKIE,
    AUTH_PASSWORD,
    OnionConfig,
    OnionNetlayer,
    SERVICE_ID_LENGTH,
    listen as onion_listen,
    provider as onion_provider,
)
from pancake.tcp import TcpNetlayer


_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)


def _gc_release_refusal_stays_owned() -> None:
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
    assert isinstance(background_failure, PancakeError), background_failure
    assert background_failure.code == ERR_NULL_POINTER, background_failure
    assert host_gc.pending == [17], host_gc.pending
    try:
        host_gc.drain_gc()
    except PancakeError as surfaced:
        assert surfaced is background_failure
    else:
        raise AssertionError("scheduled GC refusal did not reach the next drain")
    assert host_gc.pending == [17], host_gc.pending


async def _websocket_close_failure_is_observable() -> None:
    failure = RuntimeError("WebSocket close handshake failed")

    class RefusingWebSocket:
        async def close(self) -> None:
            raise failure

    transport = _WebSocketTransport(RefusingWebSocket())
    transport.close()
    try:
        await transport.wait_closed()
    except RuntimeError as observed:
        assert observed is failure
    else:
        raise AssertionError("WebSocket close failure disappeared")


async def _host_owns_async_behavior_settlement_failure() -> None:
    """An admitted behavior settlement belongs to Host shutdown even after
    its originating callback frame has returned."""
    failure = RuntimeError("deferred resolver settlement failed")

    async def fail_settlement() -> None:
        raise failure

    async def remain_pending() -> None:
        await asyncio.Future()

    host = Host.__new__(Host)
    host._behavior_tasks = set()
    host._terminal_failures = []
    host._terminal_failure_count = 0
    host._close_activity = asyncio.Event()
    failed = asyncio.create_task(fail_settlement())
    host._own_behavior_task(failed)
    await asyncio.gather(failed, return_exceptions=True)
    await asyncio.sleep(0)
    consequence = RuntimeError("second settlement failure from the same operation")
    host._record_terminal_failure(consequence)
    try:
        host._raise_terminal_failure()
    except BaseException as observed:
        assert observed is failure, "Host replaced its async settlement failure"
    else:
        raise AssertionError("Host discarded its async settlement failure")
    assert host.terminal_failures == (failure, consequence)
    assert host.terminal_failure_count == 2

    pending = asyncio.create_task(remain_pending())
    host._own_behavior_task(pending)
    await host._join_behavior_tasks()
    assert pending.cancelled(), "Host shutdown left an admitted settlement task alive"
    assert not host._behavior_tasks, "Host shutdown retained completed settlement tasks"
    try:
        host._raise_terminal_failure()
    except BaseException as observed:
        assert observed is failure, "task cancellation replaced the earlier failure"
    else:
        raise AssertionError("Host shutdown lost its retained settlement failure")

    drain_failure = RuntimeError("scheduled action drain failed")

    async def fail_drain() -> None:
        raise drain_failure

    host._action_drains = set()
    drain = asyncio.create_task(fail_drain())
    host._own_action_drain(drain)
    await asyncio.gather(drain, return_exceptions=True)
    await asyncio.sleep(0)
    assert host.terminal_failures == (
        failure,
        consequence,
        drain_failure,
    ), host.terminal_failures
    try:
        host._raise_terminal_failure()
    except BaseException as observed:
        assert observed is failure, "a later drain failure replaced the first cause"
    else:
        raise AssertionError("Host shutdown lost its ordered terminal failures")

    from pancake._transport import _rollback_failed_provider, _rollback_failed_transport

    rollback_failure = RuntimeError("connector rollback failed")

    class FailedTransport:
        closed = False

        def close(self) -> None:
            self.closed = True

        async def wait_closed(self) -> None:
            raise rollback_failure

    transport = FailedTransport()
    await _rollback_failed_transport(host, transport)
    assert transport.closed, "connector rollback did not start transport close"
    assert host.terminal_failures == (
        failure,
        consequence,
        drain_failure,
        rollback_failure,
    ), host.terminal_failures

    provider_failure = RuntimeError("provider rollback failed")

    class Loop:
        def wrapper_host(self):
            return host

    def fail_provider_rollback() -> None:
        raise provider_failure

    _rollback_failed_provider(Loop(), fail_provider_rollback)
    assert host.terminal_failures == (
        failure,
        consequence,
        drain_failure,
        rollback_failure,
        provider_failure,
    ), host.terminal_failures


async def _iroh_readiness_failure_settles_waiters_exactly() -> None:
    from pancake.iroh import _IrohLoop

    failure = RuntimeError("iroh readiness drain failed")

    class Netlayer:
        def drain_ready(self, _buffer, _cap):
            raise failure

        def cancel_connect(self, _request_id):
            return None

    class Connection:
        def key(self):
            return 7

        def close(self):
            return None

    loop = _IrohLoop(Netlayer())
    connection = Connection()
    loop.register(connection)
    readable = loop.wait_readable(connection)
    writable = loop.wait_writable(connection)
    dial = asyncio.get_running_loop().create_future()
    loop._dials[11] = dial
    accepted = loop.next_accept()
    loop._on_ready()
    assert loop.failure is failure, "iroh loop replaced its readiness failure"
    for waiter in (readable, writable, dial, accepted):
        try:
            await waiter
        except BaseException as observed:
            assert observed is failure, "iroh waiter replaced its readiness failure"
        else:
            raise AssertionError("iroh readiness failure became a clean close")

    future = loop.next_accept()
    try:
        await future
    except BaseException as observed:
        assert observed is failure, "future iroh waiter lost the terminal failure"
    else:
        raise AssertionError("future iroh waiter observed a clean close")


async def _local_tell_failure_belongs_to_host() -> None:
    from pancake._trampoline import _BehaviorEntry, _tell_local

    failure = RuntimeError("local tell behavior failed")

    def fail(_verb, _args):
        raise failure

    host = Host()
    session = type("LocalTellSession", (), {"host": host})()
    ctx = host._register_behavior(_BehaviorEntry(run=fail, resolve_local=None))
    try:
        await _tell_local(session, ctx, "notify", [])
        failures = host.take_failures()
        assert len(failures) == 1, failures
        retained = failures[0]
        assert retained.operation == "tell.behavior", retained
        assert retained.scope_id > 0, retained
        assert retained.primary_name == "RuntimeError", retained
        assert retained.primary_message == str(failure), retained
    finally:
        host._unregister_behavior(ctx)
        await host.close()


def _native_finalizer_failure_is_nonfatal_and_observable() -> None:
    one_slot = _RuntimeFailureQueue(1)
    one_slot.record(FailureLayer.BINDING, "x" * 600, RuntimeError("first"))
    one_slot.record(FailureLayer.BINDING, "second", RuntimeError("second"))
    bounded = one_slot.claim()
    assert len(bounded) == 1 and bounded[0].dropped_before == 1, bounded
    assert bounded[0].truncated_fields == 0, bounded

    text_queue = _RuntimeFailureQueue(1)
    text_queue.record(FailureLayer.BINDING, "x" * 600, RuntimeError("unretained"))
    truncated = text_queue.claim()[0]
    assert len(truncated.operation.encode()) <= 512, truncated
    assert truncated.truncated_fields & 1, truncated

    unicode_queue = _RuntimeFailureQueue(1)
    unicode_queue.record(FailureLayer.BINDING, "☃" * 600, RuntimeError("unretained"))
    unicode_truncated = unicode_queue.claim()[0]
    assert len(unicode_truncated.operation.encode()) <= 512, unicode_truncated
    assert "�" not in unicode_truncated.operation, unicode_truncated

    typed_queue = _RuntimeFailureQueue(1)
    typed_primary = PancakeError(ERR_IO, "primary")
    typed_secondary = PancakeError(ERR_INTERNAL, "cleanup")
    _retain_cleanup_failure(typed_primary, typed_secondary)
    typed_queue.record(FailureLayer.TRANSPORT, "listener.close", typed_primary)
    typed = typed_queue.claim()[0]
    assert typed.primary_result == ERR_IO, typed
    assert typed.secondary_result == ERR_INTERNAL, typed
    assert typed.secondary_count == 1, typed
    assert typed.secondary_name == "PancakeError", typed
    assert typed.secondary_message == str(typed_secondary), typed

    pancake.take_runtime_failures()
    explicit_failure = RuntimeError("explicit native release failed")
    release_failure = RuntimeError("explicit native release cleanup failed")

    def fail_shutdown(_raw) -> None:
        raise explicit_failure

    def fail_release(_raw) -> None:
        raise release_failure

    explicit = NativeHandle(
        object(), fail_release, fail_shutdown, label="explicit-test"
    )
    try:
        explicit.close()
    except BaseException as observed:
        assert observed is explicit_failure, "explicit release replaced its failure"
    else:
        raise AssertionError("explicit native release failure disappeared")
    assert explicit.terminal_failures == (
        explicit_failure,
        release_failure,
    ), explicit.terminal_failures
    try:
        explicit.close()
    except BaseException as observed:
        assert observed is explicit_failure, "repeated close replaced its first failure"
    else:
        raise AssertionError("repeated explicit close forgot its failure")
    assert not pancake.take_runtime_failures(), (
        "explicit close leaked into finalizer diagnostics"
    )

    finalizer_failure = RuntimeError("finalizer native release failed")

    def fail_finalizer(_raw) -> None:
        raise finalizer_failure

    abandoned = NativeHandle(object(), fail_finalizer, label="finalizer-test")
    del abandoned
    gc.collect()
    diagnostics = pancake.take_runtime_failures()
    assert len(diagnostics) == 1, diagnostics
    assert diagnostics[0].operation == "finalizer-test.finalize", diagnostics
    assert diagnostics[0].primary_name == "RuntimeError", diagnostics
    assert diagnostics[0].primary_message == str(finalizer_failure), diagnostics

    reports = []

    class FinalizerContext:
        def _report_failure(self, **report) -> None:
            reports.append(report)

        def _release_handle(self) -> None:
            pass

    state = _loop_module._DriverFinalizerState(123, FinalizerContext())
    original_release = _loop_module._driver.pancake_driver_release
    attempts = 0

    def refuse_once(_handle) -> int:
        nonlocal attempts
        attempts += 1
        return ERR_IO if attempts == 1 else 0

    _loop_module._driver.pancake_driver_release = refuse_once
    try:
        _loop_module._release_driver_finalizer_state(state)
        assert state.handle is not None, "refused final release lost its native lease"
        assert len(reports) == 1, reports
        assert reports[0]["operation"] == "driver-loop.finalize.release", reports
        assert reports[0]["primary_result"] == ERR_IO, reports
        _loop_module._release_driver_finalizer_state(state)
        assert state.handle is None, "successful retry retained the native lease"
        assert len(reports) == 1, "release retry duplicated its diagnostic"
    finally:
        _loop_module._driver.pancake_driver_release = original_release
        with _loop_module._deferred_driver_finalizers_lock:
            if state in _loop_module._deferred_driver_finalizers:
                _loop_module._deferred_driver_finalizers.remove(state)

    pancake.take_runtime_failures()
    original = RuntimeError("observer failed")
    recorder = RuntimeError("Context recorder failed")

    class BrokenContext:
        def _report_failure(self, **_kwargs) -> None:
            raise recorder

    owner = type(
        "BrokenDiagnosticOwner",
        (),
        {"_context": BrokenContext(), "_diagnostic_id": 17},
    )()
    _host_module.Host._record_callerless_failure(owner, "trace.sink", original)
    fallback = pancake.take_runtime_failures()
    assert len(fallback) == 2, fallback
    assert fallback[0].operation == "trace.sink", fallback
    assert fallback[0].layer is FailureLayer.APPLICATION_OBSERVER, fallback
    assert fallback[0].primary_message == str(original), fallback
    assert fallback[1].operation == "trace.sink.diagnostic", fallback
    assert fallback[1].layer is FailureLayer.BINDING, fallback
    assert fallback[1].primary_message == str(recorder), fallback


def _allocator_callback_exceptions_are_contained() -> None:
    pancake.take_runtime_failures()
    alloc_error = RuntimeError("allocator refused")

    def fail_alloc(_size: int, _alignment: int) -> int:
        raise alloc_error

    try:
        Context.with_allocator(fail_alloc, lambda *_args: None)
    except PancakeError:
        pass
    else:
        raise AssertionError("null allocator result must refuse Context construction")
    failures = pancake.take_runtime_failures()
    assert len(failures) == 1, failures
    assert failures[0].operation == "context.allocator.alloc", failures
    assert failures[0].primary_message == str(alloc_error), failures

    live = {}
    free_error = RuntimeError("allocator free refused")

    def allocate(size: int, alignment: int) -> int:
        backing = (ctypes.c_uint8 * (size + alignment))()
        base = ctypes.addressof(backing)
        address = (base + alignment - 1) & ~(alignment - 1) if alignment > 1 else base
        live[address] = backing
        return address

    def fail_free(_address: int, _size: int, _alignment: int) -> None:
        raise free_error

    context = Context.with_allocator(allocate, fail_free)
    context.close()
    failures = pancake.take_runtime_failures()
    assert failures, "free callback exception disappeared"
    assert failures[0].operation == "context.allocator.free", failures
    assert failures[0].primary_message == str(free_error), failures
    assert live, "failed free fabricated successful ownership release"


def run_managed(awaitable):
    """Run one async scenario and cross every Runtime teardown barrier."""

    async def scoped():
        runtimes: list[Runtime] = []
        token = _scenario_runtimes.set(runtimes)
        try:
            return await awaitable
        finally:
            try:
                await asyncio.gather(*(runtime.close() for runtime in reversed(runtimes)))
            finally:
                _scenario_runtimes.reset(token)

    return asyncio.run(scoped())


async def tcp_connect(partner, **kwargs):
    """Open one managed TCP runtime for this smoke scenario."""
    host = kwargs.pop("host", None)
    codec = kwargs.pop("codec", "syrup")
    timeout = kwargs.pop("handshake_timeout_ms", None)
    runtime = await Runtime.open(
        provider=tcp.provider(),
        adopt_host=host,
        codec=codec,
        handshake_timeout_ms=timeout if timeout is not None else 10_000,
    )
    try:
        session = await runtime.connect(partner)
    except BaseException:
        await runtime.close()
        raise
    runtimes = _scenario_runtimes.get()
    if runtimes is None:
        await runtime.close()
        raise RuntimeError("tcp_connect must run inside run_managed")
    runtimes.append(runtime)
    return session


async def _connector_install_is_transactional() -> None:
    """A conflicting later symbol cannot publish an earlier connector."""
    host = Host()

    def never(_host, _locator, _timeout):
        return None

    first = Connector((TRANSPORT_TCP, TRANSPORT_KEYED_TCP), never)
    second = Connector((TRANSPORT_NOISE_TCP, TRANSPORT_TCP), never)
    try:
        try:
            host.install_connectors((first, second))
        except PancakeError:
            pass
        else:
            raise AssertionError("conflicting connector set was accepted")
        assert host._connector_for(TRANSPORT_TCP) is None
        assert host._connector_for(TRANSPORT_KEYED_TCP) is None
        assert host._connector_for(TRANSPORT_NOISE_TCP) is None
    finally:
        await host.close()


async def _cancelled_dial_does_not_report_failure() -> None:
    """Core-selected cancellation is acknowledged only by the CANCEL_DIAL arm."""
    import pancake._dial as dial_module

    started = asyncio.Event()
    failures = 0

    class HostStub:
        released = False
        raw = 1

    class OwnedLocatorStub:
        def __enter__(self):
            return self

        def __exit__(self, *_exc) -> None:
            pass

        def value(self):
            return Locator("cancel-test", "peer", {})

    def pending_dial(*_args) -> int:
        return 0

    def dial_failed(*_args) -> int:
        nonlocal failures
        failures += 1
        return 0

    async def blocked_dial(*_args):
        started.set()
        await asyncio.Event().wait()

    original_pending = dial_module._host.pancake_host_pending_dial
    original_failed = dial_module._host.pancake_host_dial_failed
    original_clone = dial_module._OwnedLocator.__dict__["clone_view"]
    original_dial = dial_module.dial_exporter
    dial_module._host.pancake_host_pending_dial = pending_dial
    dial_module._host.pancake_host_dial_failed = dial_failed
    setattr(
        dial_module._OwnedLocator,
        "clone_view",
        classmethod(lambda _cls, _view: OwnedLocatorStub()),
    )
    dial_module.dial_exporter = blocked_dial
    try:
        task = asyncio.create_task(dial_module.run_dial_ticket(HostStub(), 7))
        await asyncio.wait_for(started.wait(), 1)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("dial cancellation did not propagate")
        assert failures == 0, "cancelled dial reported dial_failed"
    finally:
        dial_module._host.pancake_host_pending_dial = original_pending
        dial_module._host.pancake_host_dial_failed = original_failed
        setattr(dial_module._OwnedLocator, "clone_view", original_clone)
        dial_module.dial_exporter = original_dial


async def _driver_completion_preserves_failure_category() -> None:
    from pancake import _constants
    from pancake._host_action_gen import Fail
    from pancake._loop import DriverLoop, LoopEvent

    loop = DriverLoop.__new__(DriverLoop)
    loop._wrapper = None
    failure = asyncio.get_running_loop().create_future()
    loop._completions = {9: failure}
    loop._dispatch(
        LoopEvent(
            _constants.DRIVER_EVENT_COMPLETION,
            _constants.ERR_CLOSED,
            0,
            0,
            0,
            0,
            None,
            primary_name="closed by owner",
            settled_ok=False,
            decoded=Fail(9, _constants.ERR_CLOSED, "closed by owner"),
        )
    )
    try:
        await failure
    except PancakeError as error:
        assert error.code == _constants.ERR_CLOSED, error
    else:
        raise AssertionError("failed driver completion resolved successfully")


async def _runtime_open_is_transactional() -> None:
    """Failed Runtime setup releases only resources it already owns."""

    async with Host() as managed_host:
        assert not managed_host.released
    assert managed_host.released, "Host async context did not cross its close barrier"

    async def never(_host, _locator, _timeout):
        raise AssertionError("the failed connector must never be dialed")

    connector = Connector(("runtime-test",), never)

    retryable = await Runtime.open(connector=connector)
    try:
        await retryable.close(grace=1)
    except PancakeError as error:
        assert error.code == ERR_INVALID_ARGUMENT, error
    else:
        raise AssertionError("Runtime accepted grace for cancel close")
    await retryable
    await retryable.close()
    for operation in (
        lambda: retryable,
        lambda: retryable.connect(Locator("runtime-test", "peer", {})),
    ):
        try:
            await operation()
        except PancakeError as error:
            assert error.code == ERR_CLOSED, error
        else:
            raise AssertionError("closed Runtime admitted another operation")

    grace_host = Host()
    try:
        maximum = _close_options(PendingWork.FINISH, 0xFFFF_FFFF / 1_000)
        assert maximum.grace_ms == 0xFFFF_FFFF
        try:
            await grace_host.close(PendingWork.FINISH, grace=10**10_000)
        except PancakeError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("Host accepted a grace value outside the C range")
        assert not grace_host.released, "invalid grace closed the Host"
    finally:
        await grace_host.close()

    original_install = Host.install_connectors
    original_close = Host.close
    created: list[Host] = []
    adopted_host = None
    setup_failure = PancakeError(
        ERR_INVALID_ARGUMENT, "synthetic connector install failure"
    )
    cleanup_failure = RuntimeError("synthetic failed-open cleanup failure")

    retained_primary = PancakeError(ERR_INVALID_ARGUMENT, "synthetic primary")
    retained_cleanup = PancakeError(ERR_IO, "synthetic cleanup")
    assert _retain_cleanup_failure(retained_primary, retained_cleanup) is retained_primary
    assert retained_primary.secondary == (retained_cleanup,)
    assert retained_primary.secondary_count == 1

    rollback_primary = PancakeError(ERR_INVALID_ARGUMENT, "listener setup failed")
    listener_cleanup = PancakeError(ERR_IO, "listener cleanup failed")
    loop_cleanup = PancakeError(ERR_INTERNAL, "loop cleanup failed")
    cleanup_order: list[str] = []

    class FailedListener:
        def close(self) -> None:
            cleanup_order.append("listener")
            raise listener_cleanup

    class FailedLoop:
        def close(self) -> None:
            cleanup_order.append("loop")
            raise loop_cleanup

    assert _rollback_listener_construction(
        rollback_primary, FailedLoop(), FailedListener(), True
    ) is rollback_primary
    assert cleanup_order == ["listener", "loop"]
    assert rollback_primary.secondary == (listener_cleanup, loop_cleanup)
    assert rollback_primary.secondary_count == 2

    retained_occurrences: list[BaseException] = []
    occurrence_count = 0
    for index in range(65):
        occurrence_count = _retain_terminal_failure(
            retained_occurrences, occurrence_count, RuntimeError(f"occurrence {index}")
        )
    assert len(retained_occurrences) == 64
    assert occurrence_count == 65

    def fail_install(host, _connectors) -> None:
        created.append(host)
        raise setup_failure

    async def fail_after_close(host, *args, **kwargs) -> None:
        await original_close(host, *args, **kwargs)
        raise cleanup_failure

    setattr(Host, "install_connectors", fail_install)
    try:
        runtime = Runtime.open(connector=connector)
        setattr(Host, "close", fail_after_close)
        try:
            await runtime
        except PancakeError as error:
            assert error is setup_failure, "Runtime replaced its setup failure"
        else:
            raise AssertionError("failed connector installation opened a Runtime")
        finally:
            setattr(Host, "close", original_close)
        assert len(created) == 1
        assert created[0].released, "a newly created Host survived failed open"
        assert runtime._host is None, "failed open published a Host before commit"
        assert runtime.terminal_failures == (
            setup_failure,
            cleanup_failure,
        ), runtime.terminal_failures

        adopted_host = Host()
        adopted = Runtime.open(adopt_host=adopted_host, connector=connector)
        try:
            await adopted
        except PancakeError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("failed adopted connector installation opened a Runtime")
        assert not adopted_host.released, "failed open released an adopted Host before transfer"
        assert adopted._host is None, "failed adopted open published a Host before commit"
    finally:
        setattr(Host, "install_connectors", original_install)
        setattr(Host, "close", original_close)
        if adopted_host is not None and not adopted_host.released:
            await adopted_host.close()

    async def fail_provider(_loop) -> None:
        raise PancakeError(ERR_INVALID_ARGUMENT, "synthetic provider install failure")

    created_provider_loop = None

    async def fail_created_provider(loop) -> None:
        nonlocal created_provider_loop
        created_provider_loop = loop
        raise PancakeError(ERR_INVALID_ARGUMENT, "synthetic provider install failure")

    created_runtime = Runtime.open(provider=Provider(fail_created_provider))
    try:
        await created_runtime
    except PancakeError as error:
        assert error.code == ERR_INVALID_ARGUMENT, error
    else:
        raise AssertionError("failed provider installation opened a Runtime")
    assert created_provider_loop is not None
    assert created_provider_loop._released, "failed provider setup returned before its created loop released"

    supplied = Host()
    runtime = Runtime.open(
        adopt_host=supplied,
        provider=Provider(fail_provider),
    )
    try:
        try:
            await runtime
        except PancakeError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("failed provider installation opened a Runtime")
        assert not supplied.released, "failed provider setup released the caller-owned Host"
        assert supplied.driver_loop is not None, "failed provider setup discarded the adopted loop"
        assert runtime._host is None, "failed provider setup published a Host"
        retry = Runtime.open(adopt_host=supplied, provider=tcp.provider())
        await retry
        await retry.close()
    finally:
        if not supplied.released:
            await supplied.close()

    from pancake._loop import DriverLoop

    installer_called = False

    async def fail_existing_install(_loop) -> None:
        nonlocal installer_called
        installer_called = True
        raise PancakeError(ERR_INVALID_ARGUMENT, "synthetic existing-loop install failure")

    existing_host = Host()
    existing_loop = DriverLoop.take_host(existing_host)
    runtime = Runtime.open(
        adopt_host=existing_host,
        provider=Provider(fail_existing_install),
    )
    try:
        try:
            await runtime
        except PancakeError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("failed existing-loop provider installation opened a Runtime")
        assert installer_called, "Runtime bypassed provider installation for an existing driver loop"
        assert not existing_host.released, "failed open released a caller-owned driver loop"
    finally:
        existing_loop.close()


def main() -> int:
    _gc_release_refusal_stays_owned()
    asyncio.run(_websocket_close_failure_is_observable())
    print("python zig-smoke OK: WebSocket close retains its exact async failure")
    asyncio.run(_host_owns_async_behavior_settlement_failure())
    print("python zig-smoke OK: Host shutdown owns async behavior settlement failure")
    asyncio.run(_iroh_readiness_failure_settles_waiters_exactly())
    print("python zig-smoke OK: iroh readiness faults settle every waiter exactly")
    asyncio.run(_local_tell_failure_belongs_to_host())
    print("python zig-smoke OK: local tell failure enters its Host diagnostic seam")
    _native_finalizer_failure_is_nonfatal_and_observable()
    print("python zig-smoke OK: native finalizer failures stay nonfatal and observable")
    _allocator_callback_exceptions_are_contained()
    print("python zig-smoke OK: allocator callback exceptions stay nonfatal and observable")
    run_managed(_connector_install_is_transactional())
    run_managed(_cancelled_dial_does_not_report_failure())
    run_managed(_driver_completion_preserves_failure_category())
    run_managed(_runtime_open_is_transactional())
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
        failures = diagnostic_context.take_failures()
        assert len(failures) == 1, failures
        failure = failures[0]
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

    retry_state = _host_module._HostFinalizerState(ctypes.c_void_p(1), {}, [], {}, None)
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

    _onion_against_a_fake_daemon()
    print("python zig-smoke OK: the onion transport reached a fake Tor and reported its service")

    _loop_archive_stepping_parity()
    print(
        "python zig-smoke OK: the public Session surface ran over the driver archive — connect, fetch, an eventual-send round trip, VowBroken, and close"
    )

    run_managed(_allocator_context_round_trip())
    print("python zig-smoke OK: drove a published counter round-trip from a context-backed Host")

    run_managed(_live_trace_produces_timeline())
    print("python zig-smoke OK: the live trace produced the timeline schema for a whole conversation")

    run_managed(_async_behavior_defers())
    print("python zig-smoke OK: an async behavior deferred its answer onto a resolver vow and settled off-turn")

    run_managed(_capnp_codec_round_trip())
    print("python zig-smoke OK: a capnp session opens and big-integer + keyword args round-trip")

    run_managed(_empty_codec_is_not_the_default())
    print("python zig-smoke OK: an empty codec offer is refused, not rewritten as Syrup")

    run_managed(_feed_refusals_are_typed())
    print("python zig-smoke OK: an over-cap frame refuses typed and a refused frame carries its abort cause")

    run_managed(_tightened_admission_cap_refuses())
    print("python zig-smoke OK: a tightened session limit refuses a frame the default cap admits")

    run_managed(_disconnect_rejects_pending_send())
    print("python zig-smoke OK: an outstanding send rejects on disconnect")

    run_managed(_listen_surfaces_bound_port())
    print("python zig-smoke OK: high-level listen() surfaces the bound port and accepts")

    run_managed(_rude_probe_cannot_close_the_listener())
    print("python zig-smoke OK: a rude probe cannot close the listener")

    run_managed(_supplied_host_tcp_listener_ownership())
    print("python zig-smoke OK: supplied TCP Hosts transfer to the driver transactionally")

    run_managed(_failed_listener_preserves_supplied_host())
    print("python zig-smoke OK: failed listener setup preserves its supplied Host for retry")

    run_managed(_listener_close_preserves_sibling())
    print("python zig-smoke OK: closing one listener preserves a sibling listener")

    run_managed(_host_release_joins_dial_task())
    print("python zig-smoke OK: Host close joins every registered DIAL task")

    run_managed(_supplied_host_iroh_listener_ownership())
    print("python zig-smoke OK: supplied iroh Hosts transfer to the resident driver")

    run_managed(_proof_refusal_releases_minted_session())
    print("python zig-smoke OK: proof refusal releases the newly minted session")

    run_managed(_cancelled_iroh_open_releases_constructed_endpoint())
    print("python zig-smoke OK: canceled iroh startup joins and releases its endpoint")

    run_managed(_iroh_close_joins_after_cancellation())
    print("python zig-smoke OK: canceled iroh close still joins native teardown")

    run_managed(_session_close_joins_owned_transport_release())
    print("python zig-smoke OK: Session.close joins owned transport teardown")

    run_managed(_session_repeated_close_joins_published_failure())
    print("python zig-smoke OK: repeated Session.close joins its published failure")

    run_managed(_session_close_retains_every_terminal_failure())
    print("python zig-smoke OK: Session.close retains every terminal failure in order")

    run_managed(_session_wire_failure_is_exact_and_retired())
    print("python zig-smoke OK: Session wire failure is exact and joins retirement")

    run_managed(_cancelled_session_close_waiter_does_not_stop_driver())
    print("python zig-smoke OK: canceled Session.close waiter leaves the shared close driver running")

    run_managed(_repeated_host_close_observes_recorded_timeout())
    print("python zig-smoke OK: repeated Host.close observes the recorded finish timeout")

    run_managed(_loop_finish_close_reports_finite_grace_timeout())
    print("python zig-smoke OK: a loop finish close that outlives its finite grace reports the typed timeout")

    run_managed(_silent_loop_dial_reaches_native_handshake_deadline())
    print("python zig-smoke OK: a silent loop dial reaches pancake's native handshake deadline")

    run_managed(_host_close_shuts_a_still_open_listener())
    print("python zig-smoke OK: Host.close completes over an open listener and ends its accept stream")

    run_managed(_structured_args_round_trip())
    print("python zig-smoke OK: a Set round-trips as a Set, a nested capability stays sendable, a break is typed")

    run_managed(_enliven_round_trips_then_caches())
    print("python zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache")

    run_managed(_gc_releases_dropped_import())
    print("python zig-smoke OK: a dropped fetched import releases its export when GC is opted in")

    run_managed(_fetch_failed_is_typed())
    print("python zig-smoke OK: a non-capability fetch raises the typed FetchFailed")

    run_managed(_pipelining_drives_chain())
    print("python zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch")

    run_managed(_turn_spawn_survives_originating_port_close())
    print("python zig-smoke OK: turn-time spawn uses the Host after the originating Port closes")

    run_managed(_unawaited_break_stays_silent())
    print("python zig-smoke OK: an unawaited send is an asyncio.Future whose far break stays silent")

    run_managed(_projections_reach_a_field())
    print(
        "python zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles"
    )

    run_managed(_forwarding_proxies_over_the_wire())
    print("python zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire")

    run_managed(_forwarding_proxy_local_call())
    print("python zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)")

    run_managed(_mid_turn_driving_verb_breaks_the_answer())
    print("python zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer")

    run_managed(_mid_turn_host_release_orders_sessions_before_host())
    print("python zig-smoke OK: callback-time Host close records native intent")

    run_managed(_send_redeeming_surfaces_the_direct_exporter())
    print(
        "python zig-smoke OK: send_redeeming surfaces the redeemed exporter session, and a reply capability hosted on it routes"
    )
    return 0


async def _start_relay(target_port: int, rewrite=None, observe=None):
    """A byte-level TCP relay between a client and a server that are both real
    pancake connections: it shuttles raw bytes both ways, optionally rewriting
    the client->server stream and observing the traffic. This is how the smoke
    watches the wire (a gc release frame) or doctors it (a retargeted fetch)
    without either endpoint dropping out of the application surface."""
    writers: list = []

    async def handle(client_reader, client_writer) -> None:
        try:
            server_reader, server_writer = await asyncio.open_connection("127.0.0.1", target_port)
        except OSError:
            client_writer.close()
            return
        writers.extend([client_writer, server_writer])

        async def pump(src, dst, rewriting: bool) -> None:
            try:
                while True:
                    chunk = await src.read(65536)
                    if not chunk:
                        break
                    if observe is not None:
                        observe(chunk, rewriting)
                    dst.write(rewrite(chunk) if (rewriting and rewrite is not None) else chunk)
                    await dst.drain()
            except OSError:
                pass
            finally:
                dst.close()

        asyncio.ensure_future(pump(client_reader, server_writer, True))
        asyncio.ensure_future(pump(server_reader, client_writer, False))

    relay = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = relay.sockets[0].getsockname()[1]

    def close() -> None:
        relay.close()
        for w in writers:
            w.close()

    return port, close


async def _live_trace_produces_timeline() -> None:
    """The live timeline producer: the veneer stamps and forwards the native
    tap's facts, one flat record per fact -- session-opened with the codec
    the handshake actually negotiated, the same verb outbound at the client
    and inbound at the server, and session-closed. Endpoint labeling belongs
    to the consumer, so the records carry only the session and direction."""
    from pancake import annotate_session, enable_trace

    events: list = []
    host = Host()
    trace_failure = RuntimeError("trace sink failure must stay observer-only")

    def record_then_raise(event) -> None:
        events.append(event)
        raise trace_failure

    # Trace configuration is process-global, but every native Host remains
    # owner-thread confined. Installing from a worker must hop back to this
    # loop rather than calling through a retained raw pointer.
    uninstall = await asyncio.to_thread(lambda: enable_trace(record_then_raise, self_label="smoke"))
    host.publish_giftable("greeter", lambda verb, args: f"hello {verb}")
    server = await tcp.listen("127.0.0.1", 0, host=host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        client_host = client.host
        client.serve()
        greeter = await client.fetch("greeter")
        reply = await client.send(greeter, "trace-me", [])
        assert reply == "hello trace-me", f"traced call answers, got {reply!r}"
        # The annotation channel: the application states which partner a
        # session carries, named for the same session row the tap names.
        annotate_session(client, label="greeter-server")
        await client.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()
        await host.close()
    await asyncio.to_thread(uninstall)
    trace_diagnostics = host.take_failures() + client_host.take_failures()
    assert trace_diagnostics, "trace sink failures disappeared"
    assert all(
        failure.operation == "trace.sink"
        and failure.scope_id > 0
        and failure.primary_name == "RuntimeError"
        and failure.primary_message == str(trace_failure)
        for failure in trace_diagnostics
    ), trace_diagnostics

    opened = [ev for ev in events if ev["kind"] == "ocapn.session-opened"]
    assert len(opened) >= 2, f"both hosts' opens reached the one sink: {events}"
    assert all(ev["codec"] == "syrup" and ev["a_label"] == "smoke" for ev in opened)
    # And what this producer RUNS, because this schema is not pancake's alone:
    # a consumer must not read an implementation off the fact that a record
    # arrived, so a pancake host says so in words.
    assert all(ev["a_profile"] == "pancake" for ev in opened)
    # Identity and label are two facts. ``a`` is the host's own key designator
    # -- the name a partner knows it by, and so the only name two producers can
    # agree on -- and the label never stands in for it.
    assert all(re.fullmatch(r"[0-9a-f]{64}", ev["a"]) for ev in opened)
    # The OCapN Session ID is what lets a consumer merging two producers'
    # feeds tell one session watched twice from two unrelated ones: both peers
    # of a session derive it to the same value.
    assert all(ev.get("session_id") == opened[0].get("session_id") for ev in opened)
    assert re.fullmatch(r"[0-9a-f]{64}", opened[0].get("session_id", ""))
    outbound = [
        ev for ev in events if ev["kind"] == "ocapn.message-decoded" and ev.get("op") == "trace-me" and ev["outbound"]
    ]
    assert outbound, "the client's send traced outbound"
    inbound = [
        ev
        for ev in events
        if ev["kind"] == "ocapn.message-decoded" and ev.get("op") == "trace-me" and not ev["outbound"]
    ]
    assert inbound, "the server's deliver traced inbound"
    assert inbound[0]["session"] != outbound[0]["session"], "each host names its own session row"
    # Payload: both fact sites sit at the wire boundary (inbound dispatch,
    # the outbound drain), so both records carry the whole (sub-cap) frame
    # with its true length and the verb inside it.
    import base64 as _b64mod

    for rec in (inbound[0], outbound[0]):
        frame = _b64mod.b64decode(rec["bytes_b64"])
        assert rec["len"] == len(frame), "true length rides beside the frame"
        assert b"trace-me" in frame, "the frame bytes contain the delivered verb"
    assert any(ev["kind"] == "ocapn.session-closed" for ev in events)
    metas = [ev for ev in events if ev["kind"] == "ocapn.session-meta"]
    assert metas and metas[0]["meta"]["label"] == "greeter-server", "the annotation reached the sink with its label"
    assert metas[0]["session"] == outbound[0]["session"], "the annotation names the same session row the tap names"
    stamps = [ev["sim_t_ns"] for ev in events]
    assert stamps == sorted(stamps), "sim_t_ns is monotone"


async def _async_behavior_defers() -> None:
    """An async behavior (off-turn settlement): the worker returns a
    coroutine, the binding defers the turn's answer onto a resolver vow, and
    the settle re-enters as its own task after real awaited work, so the
    host's turn loop never blocks on it. A raise crosses as the caller's
    break carrying the behavior's own words."""
    host = Host()

    async def work(verb, args):
        await asyncio.sleep(0.005)
        if verb == "fail":
            raise ValueError("worker gave up")
        if verb == "unsupported":
            return object()
        return "computed off-turn"

    host.publish_giftable("worker", work)
    server = await tcp.listen("127.0.0.1", 0, host=host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        client.serve()
        worker = await client.fetch("worker")
        reply = await client.send(worker, "work", [])
        assert reply == "computed off-turn", f"async behavior reply, got {reply!r}"
        try:
            await client.send(worker, "fail", [])
        except VowBroken as broke:
            assert "worker gave up" in str(broke), f"async raise carries the reason, got {broke!s}"
        else:
            raise AssertionError("an async behavior's raise must break the caller")
        try:
            await client.send(worker, "unsupported", [])
        except VowBroken as broke:
            assert "unsupported" in str(broke).lower(), f"async marshal failure carries the reason, got {broke!s}"
        else:
            raise AssertionError("an unsupported async result must break the caller")
        await client.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()
    await asyncio.wait_for(host.close(), timeout=1)


async def _allocator_context_round_trip() -> None:
    """The basic round-trip: publish a counter, fetch it, drive it with sends.
    The server Host lives in a caller-supplied allocation context, so every
    byte the host owns routes through the custom allocator — proving
    :class:`Context` against the byte-fed host, released in the documented
    order (Host before context)."""
    stats = {"allocs": 0}
    live: dict = {}  # address -> owning ctypes buffer, kept alive until freed

    def host_alloc(size: int, alignment: int) -> int:
        stats["allocs"] += 1
        # Over-allocate so we can hand back an aligned address.
        backing = (ctypes.c_uint8 * (size + alignment))()
        base = ctypes.addressof(backing)
        addr = (base + alignment - 1) & ~(alignment - 1) if alignment > 1 else base
        live[addr] = backing
        return addr

    def host_free(address: int, size: int, alignment: int) -> None:
        live.pop(address, None)

    with Context.with_allocator(host_alloc, host_free) as ctx:
        host = Host(context=ctx)
        # Closing an allocation scope is a request: the live Host retains its
        # policy until teardown, while the closing Context refuses new families.
        ctx.close()
        try:
            Host(context=ctx)
        except RuntimeError:
            pass
        else:
            raise AssertionError("a released Context must refuse a new Host")
        count = {"value": 10}

        def counter(verb, args):
            if verb == "add":
                count["value"] += args[0]
                return count["value"]
            if verb == "get":
                return count["value"]
            raise ValueError(f"no such method {verb!r}")

        host.publish_giftable("counter", counter)
        server = await tcp.listen("127.0.0.1", 0, host=host)
        try:

            async def serve_one() -> None:
                async for session in server:
                    local_counter = session.published_ref("counter")
                    assert local_counter is not None, "the Host alias projects onto the accepted session"
                    assert await session.send(local_counter, "get", []) == 10
                    await session.serve()
                    break

            hosted = asyncio.ensure_future(serve_one())
            client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
            client.serve()
            counter_ref = await client.fetch("counter")
            grown = await client.send(counter_ref, "add", [5])
            assert grown == 15, f"counter.add(5) returns 15, got {grown!r}"
            read = await client.send(counter_ref, "get", [])
            assert read == 15, f"counter.get() returns 15, got {read!r}"

            # Alias-only unpublish: discovery moves, the issued capability does
            # not. A removed alias misses even on the session that fetched it,
            # a second removal is a loud miss, and the ref still answers.
            assert host.unpublish_giftable("counter") is True
            assert host.unpublish_giftable("counter") is False
            try:
                await client.fetch("counter")
            except VowBroken:
                pass
            else:
                raise AssertionError("fetch of an unpublished alias must break")
            still = await client.send(counter_ref, "get", [])
            assert still == 15, f"issued ref survives unpublish, got {still!r}"

            # Durable publication (ADR-0098): the minted swiss name fetches on
            # the live session, removal makes a later fetch miss, and the
            # capability issued before removal still answers.
            swiss = host.publish_durable(counter)
            assert swiss.startswith("pancake-durable-1-") and len(swiss) == 50, swiss
            durable_ref = await client.fetch(swiss)
            assert await client.send(durable_ref, "get", []) == 15
            assert host.remove_durable(swiss) is True
            assert host.remove_durable(swiss) is False
            try:
                await client.fetch(swiss)
            except VowBroken:
                pass
            else:
                raise AssertionError("fetch of a removed durable name must break")
            kept = await client.send(durable_ref, "get", [])
            assert kept == 15, f"issued ref survives remove_durable, got {kept!r}"
            await client.close()
            await asyncio.wait_for(hosted, timeout=5)
        finally:
            await server.close()
        await host.close()
        assert stats["allocs"] > 0, "the host allocator serviced the Host"
        assert not live, "Context release returned every custom allocation"


async def _capnp_codec_round_trip() -> None:
    """The codec selector end-to-end: both nodes minted with the Cap'n Proto
    wire grammar complete the keyed handshake and carry a deliver whose
    arguments round-trip through the capnp codec — a big integer past int64 and
    a Keyword included, so the two rare marshal arms are witnessed alongside
    the codec."""
    big = 2**80
    server = await tcp.listen("127.0.0.1", 0, codec="capnp")
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    assert verb == "probe", verb
                    assert args[0] == big, args
                    assert isinstance(args[1], Keyword) and args[1] == "prio", args
                    assert args[2] == b"hi", args
                    return Keyword("done")

                session.publish("svc", svc)
                published.set()
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port), codec="capnp")
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [big, Keyword("prio"), b"hi"])
        assert isinstance(reply, Keyword) and reply == "done", reply
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()


async def _empty_codec_is_not_the_default() -> None:
    """An omitted codec gets the Goblins-compatible floor. An explicit empty
    codec is not omission: it is invalid input and must fail before a socket is
    opened or a Host is minted with Syrup by accident."""
    for verb, action in (
        ("listen", lambda: tcp.listen("127.0.0.1", 0, codec="")),
        (
            "connect",
            lambda: Runtime.open(provider=tcp.provider(), codec="", handshake_timeout_ms=10_000),
        ),
    ):
        try:
            opened = await action()
        except ValueError as exc:
            assert "unknown OCapN codec" in str(exc), (verb, exc)
        else:
            close = getattr(opened, "close", None)
            if close is not None:
                result = close()
                if hasattr(result, "__await__"):
                    await result
            raise AssertionError(f"{verb} accepted an empty codec")


class _InjectTransport:
    """A transport that delivers nothing, so a scene can feed bytes through the
    session's own feed seam — a binding-internal probe, the sibling of the
    Racket smoke's ``feed-bytes!``."""

    designator_scheme = DESIGNATOR_SCHEME_ADDRESS

    async def read(self):
        await asyncio.get_running_loop().create_future()  # never resolves

    async def write(self, data):
        pass

    def close(self):
        pass


def _dial_injected(host: Host):
    from pancake._session import Session as _Session

    return _Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, tcp.address_designator("127.0.0.1", 1), {}, "boolean-false"),
        _InjectTransport(),
    )


async def _feed_refusals_are_typed() -> None:
    """Bounded inbox and typed abort causes over the byte-fed host. A frame
    declaring more than the frame cap is a typed refusal the moment that is
    knowable, never "read more" (ADR-0041); a refused frame names its typed
    cause (the flat PancakeError code says the failure family, the attached
    AbortDetail says the member)."""
    from pancake import _pump

    # Over-cap: the length prefix declares past the cap, refused during the scan.
    # Bytes ride the named pump module (`_pump._feed`), not a Session verb.
    session = _dial_injected(Host())
    try:
        await _pump._feed(session, b"2000000:")
        raise AssertionError("an over-cap frame must refuse typed instead of buffering")
    except PancakeError as exc:
        assert exc.code == ERR_FRAME_TOO_LARGE, exc.code
    finally:
        session.close_transport()

    # Garbage: the refusal carries the typed abort detail.
    session = _dial_injected(Host())
    try:
        assert session.last_abort() is None, "no dispatch failure recorded yet"
        try:
            await _pump._feed(session, b"this is not a frame")
            raise AssertionError("feeding garbage must raise")
        except PancakeError as exc:
            assert exc.abort is not None, "the refused frame carries its typed cause"
            assert exc.abort.domain == "codec", exc.abort
            assert exc.abort.kind == "MalformedFrame", exc.abort
            assert exc.abort.error_name == "MalformedFrame", exc.abort
            assert exc.abort.abort_delivery_error_name is None, exc.abort
            assert exc.abort.secondary_error_name is None, exc.abort
            assert exc.abort.secondary_error_count == 0, exc.abort
    finally:
        session.close_transport()


async def _tightened_admission_cap_refuses() -> None:
    """``Host.set_session_limits`` moves the admission cap the sessions minted
    after it are held to (ADR-0082). One frame decides it: at the default cap a
    4000-byte declaration is simply incomplete, and at a tightened 1024 the same
    prefix is a typed over-cap refusal."""
    from pancake import _pump

    prefix = b"4000:"

    session = _dial_injected(Host())
    try:
        await _pump._feed(session, prefix)  # under the default cap: still incomplete
    finally:
        session.close_transport()

    tightened = Host()
    tightened.set_session_limits(max_frame_bytes=1024)
    session = _dial_injected(tightened)
    try:
        await _pump._feed(session, prefix)
        raise AssertionError("a tightened admission cap must refuse an over-cap frame")
    except PancakeError as exc:
        assert exc.code == ERR_FRAME_TOO_LARGE, exc.code
    finally:
        session.close_transport()


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server serves one call and
    then closes without warning; the client's next awaited send settles with a
    typed rejection once the disconnect lands."""
    server = await tcp.listen("127.0.0.1", 0)
    closed = asyncio.Event()
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                session.serve()
                published.set()
                await asyncio.sleep(0.05)
                await session.close()
                closed.set()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()  # a disconnect ends the serve task; expected here
        await asyncio.wait_for(published.wait(), timeout=5)
        svc = await session.fetch("svc")
        await session.send(svc, "ping", [])
        await closed.wait()
        rejected = False
        try:
            await session.send(svc, "late", [])
        except (PancakeError, VowBroken):
            rejected = True
        assert rejected, "an outstanding send rejects when the connection drops"
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()


async def _listen_surfaces_bound_port() -> None:
    """`listen` binds a `Server` whose `.port` reads the kernel-chosen ephemeral
    port, and a client can dial it."""
    server = await tcp.listen("127.0.0.1", 0)
    try:
        port = server.port
        assert port != 0, "bound ephemeral port should be readable"

        accepted: list = []
        identity_checked = asyncio.Event()

        async def accept_one() -> None:
            async for session in server:
                accepted.append(session)
                await identity_checked.wait()
                await session.close()
                break

        accept_task = asyncio.ensure_future(accept_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", port))
        expected = encode_peer_locator(
            Locator(
                TRANSPORT_TCP,
                tcp.address_designator("127.0.0.1", port),
                {},
                "boolean-false",
            )
        )
        assert client.partner_identity().locator_record == expected, (
            "the accepted host advertised the listener's complete locator record"
        )
        identity_checked.set()
        # Both keyed handshakes complete; one connection was accepted on the
        # bound port.
        await asyncio.wait_for(accept_task, timeout=5)
        assert len(accepted) == 1, "the dialed connection was accepted"
        await client.close()
    finally:
        await server.close()


async def _rude_probe_cannot_close_the_listener() -> None:
    """A rude TCP probe — connect, say nothing, hang up — is that connection's
    failure, not the listener's. The Server's iterator must skip the failed
    handshake and keep accepting; without the skip, one port scan takes a
    long-lived server down."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:
        port = server.port

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: Symbol("alive"))
                published.set()
                session.serve()
                break  # one real client is the proof

        served = asyncio.ensure_future(serve_one())

        # The probe: a raw socket that opens and immediately hangs up.
        probe_reader, probe_writer = await asyncio.open_connection("127.0.0.1", port)
        probe_writer.close()
        del probe_reader

        session = await tcp_connect(tcp.locator("127.0.0.1", port))
        await asyncio.wait_for(published.wait(), timeout=5)
        svc = await session.fetch("svc")
        reply = await session.send(svc, "ping", [])
        assert reply == Symbol("alive"), reply
        await session.close()
        await asyncio.wait_for(served, timeout=5)
    finally:
        await server.close()


async def _supplied_host_tcp_listener_ownership() -> None:
    """A supplied TCP Host is the exact wrapper adopted by the driver.

    Closing the listener seals admission but does not release the yielded
    session; the final Host close happens only after that session closes.
    """
    supplied = Host()
    server = await tcp.listen("127.0.0.1", 0, host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, "listener did not preserve the supplied Host wrapper"
        assert server.uri.endswith(".tcp"), server.uri
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        accepted = await asyncio.wait_for(accepted_task, timeout=5)
        accepted.publish("svc", lambda verb, args: Symbol("alive"))
        accepted.serve()

        await server.close()
        await asyncio.sleep(0)
        assert not supplied.released, "listener close released a yielded supplied Host"
        svc = await client.fetch("svc")
        assert await client.send(svc, "ping", []) == Symbol("alive")
        await accepted.close()
        await client.close()
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.close()


async def _failed_listener_preserves_supplied_host() -> None:
    """Post-adoption failure keeps the caller's Host and retires listener rows."""
    supplied = Host()
    retry = None
    try:
        try:
            await tcp.listen("0.0.0.0", 0, host=supplied)
            raise AssertionError("wildcard listen without an advertised host must fail")
        except PancakeError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error

        assert not supplied.released, "failed listen released the supplied Host"
        loop = supplied._driver_loop
        assert loop is not None, "failed listen detached the adopted driver loop"
        assert not loop._listeners, loop._listeners
        assert not loop._listener_waiters, loop._listener_waiters
        assert not loop._accepts, loop._accepts

        retry = await tcp.listen("127.0.0.1", 0, host=supplied)
        assert retry.host is supplied
    finally:
        if retry is not None:
            await retry.close()
        if not supplied.released:
            await supplied.close()


async def _supplied_host_iroh_listener_ownership() -> None:
    """The iroh resident uses the same supplied Host and driver barrier."""
    from pancake.iroh import IrohConfig, Reachability, listen

    supplied = Host(seed=b"pancake-supplied-iroh-seed-000000"[:32])
    server = await listen(IrohConfig(Reachability.LOCAL_DISCOVERY), host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, "iroh listener did not preserve the supplied Host wrapper"
        from pancake.iroh import provider as iroh_provider

        runtime = await Runtime.open(provider=iroh_provider(IrohConfig(Reachability.LOCAL_DISCOVERY)))
        client = await runtime.connect(server.locator)
        accepted = await asyncio.wait_for(accepted_task, timeout=10)
        await server.close()
        await asyncio.sleep(0)
        assert not supplied.released, "iroh listener close released a yielded supplied Host"
        await accepted.close()
        await client.close()
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.close()


async def _listener_close_preserves_sibling() -> None:
    """Closing one listener leaves a sibling provider on the same Host usable."""
    supplied = Host()
    tcp_server = await tcp.listen("127.0.0.1", 0, host=supplied)
    keyed_server = await tcp.keyed.listen("127.0.0.1", 0, host=supplied)
    noise_server = await tcp.noise.listen("127.0.0.1", 0, host=supplied)
    client = None
    accepted = None
    try:
        await tcp_server.close()
        assert keyed_server.locator.transport == TRANSPORT_KEYED_TCP
        assert noise_server.locator.transport == TRANSPORT_NOISE_TCP
        assert parse_locator(keyed_server.uri) == keyed_server.locator
        assert parse_locator(noise_server.uri) == noise_server.locator
        client = await tcp_connect(keyed_server.locator)
        accepted = await asyncio.wait_for(keyed_server.__anext__(), timeout=5)
        assert not supplied.released, "closing one listener released the shared Host"
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        await keyed_server.close()
        await noise_server.close()
        if not supplied.released:
            await supplied.close()


async def _host_release_joins_dial_task() -> None:
    """CANCEL_DIAL joins the registered executor before acknowledging it.

    The fake executor is installed at the action seam that creates the task,
    so this proves the real Host registry and done
    callback rather than a second test-only task list.
    """
    import pancake._dial as dial_module

    original = dial_module.run_dial_ticket
    started = asyncio.Event()
    finished = asyncio.Event()

    async def pending_dial(_host, _ticket) -> None:
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            finished.set()

    dial_module.run_dial_ticket = pending_dial
    host = Host()
    try:
        # Drive the same generated action dispatcher production uses. The DIAL
        # arm must return after transferring ownership to Host, not await the
        # network operation inline and serialize every later action behind it.
        from pancake._action import _run_action
        from pancake._host_action_gen import CancelDial, Dial

        await _run_action(host, Dial(ticket=7))
        await asyncio.wait_for(started.wait(), timeout=1)
        await _run_action(host, CancelDial(ticket=7))
        assert finished.is_set(), "CANCEL_DIAL returned before DIAL cleanup finished"
        await host.close()
        assert host._raw is None, "Host close retained native authority after CANCEL_DIAL cleanup"
        assert not host._dial_tasks, "the Host-owned DIAL registry retained a finished task"
    finally:
        dial_module.run_dial_ticket = original
        if host._raw is not None:
            await host.close()


async def _proof_refusal_releases_minted_session() -> None:
    """Failure between native mint and handshake has one teardown owner."""
    import pancake._session as session_module

    class Transport:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS
        close_count = 0

        def close(self) -> None:
            self.close_count += 1

    host = Host()
    host.set_advertised_locator(
        Locator(
            TRANSPORT_TCP,
            tcp.address_designator("127.0.0.1", 1),
            {},
        )
    )
    transport = Transport()
    releases = 0
    original_bind = session_module._host.pancake_host_session_bind_verified_channel_key
    original_release = session_module._host.pancake_host_session_release

    def refuse_proof(*_args) -> int:
        return ERR_INVALID_ARGUMENT

    def count_release(raw) -> int:
        nonlocal releases
        releases += 1
        return original_release(raw)

    session_module._host.pancake_host_session_bind_verified_channel_key = refuse_proof
    session_module._host.pancake_host_session_release = count_release
    try:
        try:
            await session_module.Session.establish_dialed_locator(
                host,
                Locator(TRANSPORT_TCP, "127.0.0.1:2", {}, "boolean-false"),
                transport,
                verified_channel_key="00" * 32,
            )
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("a refused channel proof unexpectedly established")
        assert releases == 1, "proof refusal did not release exactly one native session"
        assert transport.close_count == 1, "proof refusal did not close its transport"
        assert not host._sessions, "proof refusal left a session registered on its Host"

        accepted_transport = Transport()
        try:
            await session_module.Session.establish_accepted(
                host,
                TRANSPORT_TCP,
                "127.0.0.1:2",
                accepted_transport,
                accepted_local_addr="127.0.0.1:2",
                verified_channel_key="00" * 32,
            )
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("a refused accepted-channel proof unexpectedly established")
        assert releases == 2, "accepted proof refusal did not release exactly one session"
        assert accepted_transport.close_count == 1, "accepted proof refusal did not close its transport"
        assert not host._sessions, "accepted proof refusal left a session registered on its Host"
    finally:
        session_module._host.pancake_host_session_bind_verified_channel_key = original_bind
        session_module._host.pancake_host_session_release = original_release
        await host.close()


async def _cancelled_iroh_open_releases_constructed_endpoint() -> None:
    """Cancellation cannot abandon an endpoint still constructing off-thread."""
    from pancake.iroh import IrohConfig, IrohNetlayer, Reachability

    started = threading.Event()
    finish = threading.Event()
    released = threading.Event()
    cleanup_failure = RuntimeError("canceled iroh construction cleanup failed")
    pancake.take_runtime_failures()

    class ControlledNetlayer(IrohNetlayer):
        def __init__(self, _config, _secret_seed=None, *, _construction_token=None) -> None:
            started.set()
            finish.wait()

        async def close(self) -> None:
            released.set()
            raise cleanup_failure

    opening = asyncio.create_task(ControlledNetlayer.open(IrohConfig(Reachability.DIRECT)))
    assert await asyncio.to_thread(started.wait, 1), "iroh constructor did not start"
    opening.cancel()
    finish.set()
    try:
        await opening
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled iroh startup returned an endpoint")
    assert released.is_set(), "cancelled iroh startup abandoned the constructed endpoint"
    diagnostics = pancake.take_runtime_failures()
    assert len(diagnostics) == 1, diagnostics
    assert diagnostics[0].operation == "iroh-release-after-cancel"
    assert diagnostics[0].primary_message == str(cleanup_failure)


async def _iroh_close_joins_after_cancellation() -> None:
    """A canceled close waiter cannot detach the native release task."""
    from pancake.iroh import IrohNetlayer

    started = threading.Event()
    finish = threading.Event()
    calls = 0

    class ControlledNetlayer(IrohNetlayer):
        def __init__(self) -> None:
            self._close_task = None

        def _release_blocking(self) -> None:
            nonlocal calls
            calls += 1
            started.set()
            finish.wait()

    netlayer = ControlledNetlayer()
    close = asyncio.create_task(netlayer.close())
    assert await asyncio.to_thread(started.wait, 1), "close did not start"
    close.cancel()
    await asyncio.sleep(0)
    assert not close.done(), "close waiter detached before native teardown"
    finish.set()
    try:
        await close
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("close cancellation was not preserved")

    await netlayer.close()
    assert calls == 1, "repeated close started a second native release"


async def _session_close_joins_owned_transport_release() -> None:
    """Session.close joins transport cleanup after the core close effect."""
    from pancake._session import Session

    started = asyncio.Event()
    finish = asyncio.Event()

    class HostStub:
        def _assert_owner(self) -> None:
            pass

    class TransportStub:
        closed = False

        def close(self) -> None:
            self.closed = True

        async def wait_closed(self) -> None:
            started.set()
            await finish.wait()

    transport = TransportStub()
    session = Session.__new__(Session)
    session._host = HostStub()
    session._transport = transport
    session._closing = False
    session._released = True
    session._close_future = None
    session._close_task = None
    session._serve_task = None
    session._wire_failure = None
    session._transport_lost = False
    session._transport_close_started = True
    session.close_transport = transport.close
    transport.close()

    closing = asyncio.create_task(session.close())
    await asyncio.wait_for(started.wait(), timeout=1)
    assert transport.closed, "the core close effect did not retire the transport"
    assert not closing.done(), "Session.close returned before transport completion"
    finish.set()
    await closing


async def _session_repeated_close_joins_published_failure() -> None:
    """Released state cannot let a repeated close outrun its shared result."""
    from pancake._session import Session

    class HostStub:
        def _assert_owner(self) -> None:
            pass

    session = Session.__new__(Session)
    session._host = HostStub()
    session._transport = object()
    session._closing = True
    session._released = True
    session._close_future = asyncio.get_running_loop().create_future()
    session._close_task = None
    session._serve_task = None
    session._wire_failure = None
    session._transport_lost = False
    session._transport_close_started = True

    repeated = asyncio.create_task(session.close())
    await asyncio.sleep(0)
    assert not repeated.done(), "released state bypassed the active close barrier"

    session._close_future.set_exception(PancakeError(ERR_INVALID_ARGUMENT, "published close failure"))
    try:
        await repeated
    except PancakeError as error:
        assert error.code == ERR_INVALID_ARGUMENT, error
    else:
        raise AssertionError("repeated close discarded the shared close failure")


async def _session_close_retains_every_terminal_failure() -> None:
    """The exact primary remains raised while later owned-barrier failures
    remain inspectable in deterministic observation order."""
    from pancake._session import Session

    primary = OSError("primary wire failure")
    close_result = RuntimeError("native close result failed")
    wait_closed = LookupError("transport wait_closed failed")
    serve_failure = ValueError("serve task failed")

    class HostStub:
        def _assert_owner(self) -> None:
            pass

    class TransportStub:
        def __init__(self) -> None:
            self.calls = 0

        async def wait_closed(self) -> None:
            self.calls += 1
            if self.calls == 1:
                raise wait_closed
            raise LookupError("duplicate wait_closed observation")

    async def rejected_result() -> None:
        raise close_result

    async def rejected_serve() -> None:
        raise serve_failure

    session = Session.__new__(Session)
    session._host = HostStub()
    session._transport = TransportStub()
    session._released = True
    session._release_pending = False
    session._wire_failure = primary
    session._terminal_failures = []
    session._terminal_failure_count = 0
    session._terminal_joined = False
    session._serve_task = asyncio.create_task(rejected_serve())

    try:
        await session._join_close_barrier(rejected_result())
    except BaseException as observed:
        assert observed is primary, "close replaced its exact first failure"
    else:
        raise AssertionError("close discarded its terminal failure chain")
    expected = (primary, close_result, wait_closed, serve_failure)
    assert session.terminal_failures == expected, session.terminal_failures
    assert session.terminal_failure_count == len(expected)

    try:
        await session._join_close_barrier()
    except BaseException as observed:
        assert observed is primary, "repeated close replaced its exact primary"
    else:
        raise AssertionError("repeated close discarded its terminal failure chain")
    assert session.terminal_failures == expected, (
        "repeated close duplicated or reordered retained failures"
    )


async def _session_wire_failure_is_exact_and_retired() -> None:
    """A session-scoped FLUSH fault reaches every public observer only after
    the byte channel has crossed its retirement barrier."""
    from pancake._session import Session

    class MemoryChannel:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS

        def __init__(self, hold_close: bool = False) -> None:
            self.inbound: asyncio.Queue[bytes | None] = asyncio.Queue()
            self.peer: "MemoryChannel | None" = None
            self.failure: BaseException | None = None
            self.closed = False
            self.close_done = asyncio.Event()
            self.hold_close = hold_close

        async def read(self) -> bytes | None:
            return await self.inbound.get()

        async def write(self, data: bytes) -> None:
            if self.failure is not None:
                raise self.failure
            if self.closed or self.peer is None or self.peer.closed:
                raise BrokenPipeError("memory channel is closed")
            await self.peer.inbound.put(bytes(data))

        def close(self) -> None:
            if self.closed:
                return
            self.closed = True
            self.inbound.put_nowait(None)
            if self.peer is not None:
                self.peer.inbound.put_nowait(None)
            if not self.hold_close:
                self.close_done.set()

        async def wait_closed(self) -> None:
            await self.close_done.wait()

    client_channel = MemoryChannel(hold_close=True)
    server_channel = MemoryChannel()
    client_channel.peer = server_channel
    server_channel.peer = client_channel
    client_host = Host()
    server_host = Host()
    designator = tcp.address_designator("127.0.0.1", 1)
    accepted = Session.establish_accepted(
        server_host,
        TRANSPORT_TCP,
        designator,
        server_channel,
    )
    dialed = Session.establish_dialed_locator(
        client_host,
        Locator(TRANSPORT_TCP, designator, {}, "boolean-false"),
        client_channel,
    )
    server_session, session = await asyncio.gather(accepted, dialed)
    server_session.publish("svc", lambda _verb, _args: Symbol("alive"))
    server_serving = server_session.serve()
    client_serving = session.serve()
    svc = await session.fetch("svc")

    first_failure = OSError("injected exact FLUSH failure")
    client_channel.failure = first_failure
    try:
        await session.tell(svc, "ping", [])
    except BaseException as error:
        assert error is first_failure, "tell lost the exact FLUSH failure"
    else:
        raise AssertionError("tell accepted a failed FLUSH")
    try:
        await client_serving
    except BaseException as error:
        assert error is first_failure, "serve lost the exact FLUSH failure"
    else:
        raise AssertionError("serve resolved after a failed FLUSH")

    closing = asyncio.create_task(session.close())
    await asyncio.sleep(0)
    assert not closing.done(), "close reported failure before transport retirement"
    client_channel.close_done.set()
    try:
        await closing
    except BaseException as error:
        assert error is first_failure, "close lost the exact FLUSH failure"
    else:
        raise AssertionError("close resolved after a failed FLUSH")

    await server_serving
    await asyncio.gather(client_host.close(), server_host.close())


async def _cancelled_session_close_waiter_does_not_stop_driver() -> None:
    """A finite session finish keeps progressing after its first waiter leaves."""
    from pancake._session import Session

    class PendingTransport:
        async def read(self) -> bytes:
            await asyncio.Future()

        async def write(self, _data: bytes) -> None:
            pass

        def close(self) -> None:
            pass

    host = Host()
    session = Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, "pending-session", {}, "boolean-false"),
        PendingTransport(),
    )

    first = asyncio.create_task(
        session.close(pending=PendingWork.FINISH, grace=0.02)
    )
    while session._close_task is None:
        await asyncio.sleep(0)
    first.cancel()
    try:
        await first
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled Session.close waiter did not preserve cancellation")

    async def wait_released() -> None:
        while not session._released:
            await asyncio.sleep(0)

    await asyncio.wait_for(wait_released(), timeout=1)
    try:
        await session.close(pending=PendingWork.FINISH, grace=None)
    except PancakeError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("the shared finite finish discarded its timeout")

    await host.close()


async def _repeated_host_close_observes_recorded_timeout() -> None:
    """A Host close that exhausted its finish grace keeps its outcome: a later
    close raises the recorded timeout instead of silently succeeding."""
    from pancake._session import Session

    class PendingTransport:
        async def read(self) -> bytes:
            await asyncio.Future()

        async def write(self, _data: bytes) -> None:
            pass

        def close(self) -> None:
            pass

    host = Host()
    # The wrapper stays referenced so only Host.close drives the teardown.
    pending_session = Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, "pending-session", {}, "boolean-false"),
        PendingTransport(),
    )

    try:
        await host.close(PendingWork.FINISH, grace=0.02)
    except PancakeError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("a negotiating session let the finite finish settle in time")

    assert host.released, "the timed-out finish close did not reach its terminal release"
    try:
        await host.close()
    except PancakeError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("repeated Host.close discarded the recorded timeout")
    del pending_session


async def _loop_finish_close_reports_finite_grace_timeout() -> None:
    """The same spent-grace outcome through the loop front (ADR-0112): the
    pending work is a Runtime dial whose partner accepted the socket and says
    nothing. After close begins nothing arrives on the wire and no verb runs,
    so the close driver's park over ``pancake_driver_step_wait_ms`` is what
    spans the expiry, and its waking step escalates and reports the timeout."""
    silent = socket.socket()
    try:
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)
        port = silent.getsockname()[1]
        runtime = await Runtime.open(provider=tcp.provider(), handshake_timeout_ms=10_000)
        negotiating = asyncio.create_task(runtime.connect(tcp.locator("127.0.0.1", port)))
        driver_loop = runtime._loop
        assert driver_loop is not None, "a provider Runtime did not open on the loop tier"
        # Let the connect task run far enough to admit its pending open before
        # close seals admission.
        for _ in range(100):
            if driver_loop._pending_dials:
                break
            await asyncio.sleep(0)
        assert driver_loop._pending_dials, "the dial never admitted its pending open"
        try:
            await asyncio.wait_for(runtime.close(PendingWork.FINISH, grace=0.02), 5)
        except PancakeError as error:
            assert error.code == ERR_TIMEOUT, error
        else:
            raise AssertionError("a negotiating dial let the finite finish settle in time")
        try:
            await negotiating
        except (PancakeError, asyncio.CancelledError):
            pass
    finally:
        silent.close()


async def _silent_loop_dial_reaches_native_handshake_deadline() -> None:
    """An ordinary dial has no close driver to wake it. The loop's one
    asyncio progress clock must therefore step when pancake's handshake
    deadline expires, even though the accepted socket produces no fd edge."""
    listener = socket.socket()
    listener.setblocking(False)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    runtime = await Runtime.open(
        provider=tcp.provider(),
        handshake_timeout_ms=50,
    )
    accepted: socket.socket | None = None
    try:
        port = listener.getsockname()[1]
        dial = asyncio.create_task(
            runtime.connect(tcp.locator("127.0.0.1", port))
        )
        accepted, _address = await asyncio.wait_for(
            asyncio.get_running_loop().sock_accept(listener),
            timeout=1,
        )
        try:
            await asyncio.wait_for(dial, timeout=1)
        except PancakeError as error:
            assert error.code == ERR_TIMEOUT, error
        else:
            raise AssertionError("a silent partner opened a session")
    finally:
        if accepted is not None:
            accepted.close()
        listener.close()
        await runtime.close()


async def _host_close_shuts_a_still_open_listener() -> None:
    """``await host.close()`` with a listener still open completes the barrier
    and shuts the listener down itself, ending its accept stream."""
    supplied = Host()
    server = await tcp.listen("127.0.0.1", 0, host=supplied)
    pending_accept = asyncio.ensure_future(server.__anext__())
    try:
        await asyncio.sleep(0)
        assert not pending_accept.done(), "the accept stream ended before Host close"
        await asyncio.wait_for(supplied.close(), timeout=5)
        assert supplied.released, "Host close did not complete over the open listener"
        try:
            await asyncio.wait_for(pending_accept, timeout=1)
        except StopAsyncIteration:
            pass
        else:
            raise AssertionError("Host close did not end the open listener's accept stream")
    finally:
        if not pending_accept.done():
            pending_accept.cancel()
        await server.close()
        if not supplied.released:
            await supplied.close()


async def _structured_args_round_trip() -> None:
    """A ``Set`` argument crosses the application surface as a ``Set`` (never a
    plain list), a capability nested in a Set or Tagged arrives as a sendable
    :class:`Ref`, and a partner break raises the typed :class:`VowBroken`."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    if verb == "boom":
                        raise ValueError("kaboom")
                    assert verb == "probe", verb
                    probe_set = args[0]
                    assert type(probe_set) is Set, f"a Set argument arrives as a Set, got {type(probe_set).__name__}"
                    assert 1 in probe_set, probe_set
                    nested = next((item for item in probe_set if isinstance(item, Ref)), None)
                    assert isinstance(nested, Ref), f"a capability inside a Set lifts to a Ref, got {nested!r}"
                    note = args[1]
                    assert isinstance(note, Tagged), f"a Tagged argument arrives as a Tagged, got {note!r}"
                    assert isinstance(note.value[0], Ref), note.value
                    # The nested capability is sendable: poke back through it.
                    asyncio.ensure_future(session.tell(nested, "poke", []))
                    return Set([Symbol("ok"), 7])

                session.publish("svc", svc)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        poked = asyncio.get_running_loop().create_future()

        def inbox_behavior(verb, args):
            if verb == "poke" and not poked.done():
                poked.set_result(True)

        inbox = session.spawn(inbox_behavior)
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [Set([1, inbox]), Tagged("note", [inbox])])
        assert type(reply) is Set, f"a Set reply survives the round-trip as a Set, got {type(reply).__name__}"
        assert Symbol("ok") in reply and 7 in reply, reply
        await asyncio.wait_for(poked, timeout=5)

        # A partner break is the typed VowBroken, catchable by type.
        try:
            await session.send(svc_ref, "boom", [])
            raise AssertionError("a partner break must raise VowBroken")
        except VowBroken as exc:
            assert "kaboom" in str(exc), exc

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)

    finally:
        await server.close()


async def _enliven_round_trips_then_caches() -> None:
    """Sturdyref enliven (ADR-0012): the requester brings a durable
    ``(peer, swissnum)`` to life as a live :class:`Ref` through the host's
    dedup cache. A repeat enliven of the same swissnum short-circuits with no
    wire traffic (its completion is queued before the minting call returns),
    and the enlivened capability is sendable both times."""
    server_host = Host()

    def greeter(verb, args):
        assert verb == "hello", verb
        return Symbol("alive")

    server_host.publish_giftable("greeter", greeter)
    server = await tcp.listen("127.0.0.1", 0, host=server_host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        locator = tcp.locator("127.0.0.1", server.port)
        session = await tcp_connect(locator)
        session.serve()
        try:
            await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
        except PancakeError as err:
            assert err.code == ERR_INVALID_ARGUMENT, err
        else:
            raise AssertionError("enliven accepted a sturdyref for another peer")
        # The complete sturdyref must name this selected session's peer.
        sturdyref = f"{format_locator_uri(locator)}/s/Z3JlZXRlcg"
        cap = await session.enliven(sturdyref)
        greeting = await session.send(cap, "hello", [])
        assert greeting == Symbol("alive"), f"enlivened cap answers hello, got {greeting!r}"
        # A repeat enliven hits the dedup cache: the same live capability.
        again = await session.enliven(sturdyref)
        greeting2 = await session.send(again, "hello", [])
        assert greeting2 == Symbol("alive"), f"cached enliven answers hello, got {greeting2!r}"
        # Listen (CapTP ``op:listen``): a held capability's resolution comes
        # back through the vow -- a listen on an already-settled capability
        # answers at once.
        settled = await session.listen(cap)
        assert isinstance(settled, Ref), f"listen settles naming the capability, got {settled!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)

        # A sessionless Host selects the generic driver before its DIAL action
        # exists. The driver consumes that original action and exposes the
        # exporter session without a binding-side TCP branch.
        cold_serve = asyncio.ensure_future(serve_one())
        cold = Host()
        cold.register_connector(tcp.connector())
        cold_cap = await cold.enliven(sturdyref)
        cold_exporter = cold.exporter_for(cold_cap)
        assert cold_exporter is not None, "cold enliven retains its exporter session"
        cold_greeting = await cold_exporter.send(cold_cap, "hello", [])
        assert cold_greeting == Symbol("alive"), cold_greeting
        await cold.close()
        await asyncio.wait_for(cold_serve, timeout=5)
    finally:
        await server.close()


async def _gc_releases_dropped_import() -> None:
    """Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
    capability releases its import -- one ``op:gc-exports`` -- when the runtime
    reclaims the last :class:`Ref` to it. Both ends are real connections; a
    byte relay between them watches the wire for the release frame. The client
    drops its only handle, and CPython's refcounting fires the finalizer
    promptly."""
    server = await tcp.listen("127.0.0.1", 0)
    saw_gc = asyncio.Event()
    published = asyncio.Event()

    def observe(chunk: bytes, _to_server: bool) -> None:
        if b"op:gc-export" in chunk:
            saw_gc.set()

    relay_port, relay_close = await _start_relay(server.port, observe=observe)
    try:

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = (await tcp_connect(tcp.locator("127.0.0.1", relay_port))).with_gc()
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        cap = await session.fetch("svc")
        assert cap.id > 0, "the fetched cap has a Host identity"
        # Drop the only handle; refcounting fires the finalizer, which parks the
        # token and hops to the loop. Yield loop turns for it to flush.
        del cap
        for _ in range(200):
            if saw_gc.is_set():
                break
            await asyncio.sleep(0.01)
        assert saw_gc.is_set(), "the wire never carried op:gc-export for the dropped import"
        # The finalizer parked the release and hopped to the loop; observing
        # op:gc-export means it ran, so no parked release is left behind (parity
        # with the TypeScript, Rust, and Racket dogfoods, which assert the same).
        assert session._host.pending_release_count() == 0, "the finalizer's parked release drained after the turn"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        relay_close()
        await server.close()


async def _fetch_failed_is_typed() -> None:
    """A fetch that fulfills with a plain value (not a capability) raises the
    dedicated :class:`FetchFailed` — the foreign-bootstrap shape a non-pancake
    partner can produce. A pancake host always answers a fetch with a
    capability, so a relay doctors the wire: the client's bootstrap-fetch
    deliver is retargeted from export 0 to the export of a published object
    that answers with a plain integer, so the client's fetch answer fulfills
    with 42. The client fetches "plain" legitimately first: that reply's
    marshal is what grants the export (ADR-0074), so the doctored deliver
    that follows is admitted rather than refused as a probe of an ungranted
    position."""
    server = await tcp.listen("127.0.0.1", 0)
    plain_export: list[int] = []
    observed_wire = bytearray()
    export_known = asyncio.Event()
    # Armed only after the legitimate fetch of "plain" has granted the export,
    # so only the second fetch is doctored.
    state = {"retargeted": False, "armed": False, "capturing": False}
    pending = bytearray()

    def observe(chunk: bytes, to_server: bool) -> None:
        if to_server or not state["capturing"] or plain_export:
            return
        observed_wire.extend(chunk)
        match = re.search(rb"desc:import-object(\d+)\+", observed_wire)
        if match is not None:
            plain_export.append(int(match.group(1)))

    def retarget(chunk: bytes) -> bytes:
        if not state["armed"] or not plain_export:
            return chunk
        if state["retargeted"] and not pending:
            return chunk
        needle = b"desc:export0+"
        pending.extend(chunk)
        output = bytearray()
        while pending:
            colon = pending.find(b":")
            if colon < 0:
                break
            prefix = pending[:colon]
            if not prefix.isdigit():
                # Preserve malformed input for the product parser to diagnose.
                output.extend(pending)
                pending.clear()
                break
            frame_end = colon + 1 + int(prefix)
            if len(pending) < frame_end:
                break
            body = bytes(pending[colon + 1 : frame_end])
            del pending[:frame_end]
            if not state["retargeted"] and needle in body:
                body = body.replace(needle, b"desc:export%d+" % plain_export[0], 1)
                state["retargeted"] = True
            output.extend(str(len(body)).encode())
            output.extend(b":")
            output.extend(body)
        return bytes(output)

    relay_port, relay_close = await _start_relay(server.port, rewrite=retarget, observe=observe)
    try:

        async def serve_one() -> None:
            async for session in server:
                # The doctored fetch deliver lands here with verb "fetch";
                # answer with a plain integer, which is exactly what a fetch
                # must not resolve to.
                session.publish("plain", lambda verb, args: 42)
                export_known.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", relay_port))
        session.serve()
        await export_known.wait()
        # The granting fetch: its resolve marshals the "plain" reference,
        # which is what makes the position addressable for the doctored
        # deliver below.
        state["capturing"] = True
        await session.fetch("plain")
        for _ in range(100):
            if plain_export:
                break
            await asyncio.sleep(0)
        assert plain_export, "the granting fetch exposed no import-object descriptor"
        state["capturing"] = False
        state["armed"] = True
        try:
            await session.fetch("not-a-capability")
            raise AssertionError("a non-capability fetch must raise FetchFailed")
        except FetchFailed as exc:
            assert exc.name == "not-a-capability", exc
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        relay_close()
        await server.close()


async def _pipelining_drives_chain() -> None:
    """Promise pipelining (ADR-0007), the questioner's half: ``Session.send``
    returns a handle that is also a ``send`` target, so a create -> assign ->
    complete -> status chain is issued against the *unresolved* ``create`` answer
    and the four delivers travel as one batch. The board's ``create`` spawns a
    fresh task from inside the served turn (the turn-time spawn) and returns
    it; the partner's engine queues the pipelined calls on that pending answer
    and drains them onto the task once ``create`` resolves. A ``status`` of
    ``done`` proves the chain crossed without round-tripping per link."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    assert verb == "create", verb
                    state = {"done": False}

                    def task(task_verb, task_args):
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
        # The four verbs leave together: none awaits create's reply, and assign /
        # complete / status target the create answer directly.
        task = session.send(root_ref, "create", ["benchmark"])
        session.send(task, "assign", ["alice"])
        session.send(task, "complete", [])
        status = await session.send(task, "status", [])
        assert status == "done", f"pipelined status should be done, got {status!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _turn_spawn_survives_originating_port_close() -> None:
    """An actor first published through one Port remains a Host actor. Close
    that Port, call it through a sibling, then use the captured stale Session
    handle to spawn a child inside the sibling's turn. Host ownership selects
    turn-spawn; the dead Session is not consulted for routing."""
    server = await tcp.listen("127.0.0.1", 0)
    ready = asyncio.Event()
    try:

        async def host() -> None:
            accepted = []
            async for session in server:
                session.serve()
                accepted.append(session)
                if len(accepted) == 1:
                    origin = session

                    def root(verb, args):
                        assert verb == "create", verb
                        return origin.spawn(lambda child_verb, child_args: ("alive" if child_verb == "ping" else None))

                    root_ref = origin.spawn(root)
                    continue

                session.publish(
                    "introducer",
                    lambda verb, args: root_ref if verb == "get" else None,
                )
                await accepted[0].close()
                ready.set()
                await session.serve()
                break

        hosted = asyncio.ensure_future(host())
        origin_client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        origin_client.serve()
        sibling = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        sibling.serve()
        await ready.wait()
        introducer = await sibling.fetch("introducer")
        root = await sibling.send(introducer, "get", [])
        assert isinstance(root, Ref), f"introducer returned {root!r}, not a capability"
        child = await sibling.send(root, "create", [])
        assert isinstance(child, Ref), f"create returned {child!r}, not a capability"
        assert await sibling.send(child, "ping", []) == "alive"
        await sibling.close()
        await origin_client.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()


async def _unawaited_break_stays_silent() -> None:
    """Promise pipelining (ADR-0007), the unawaited-anchor contract: a send
    handle is a real ``asyncio.Future``, and an anchor whose far answer
    *breaks* -- even after its bytes flush on a sibling's tail -- never
    surfaces that break, because an unobserved handle materializes no
    exception (the outcome is recorded, not thrown). This is what lets a
    pipelining anchor go unawaited safely."""
    loop = asyncio.get_running_loop()
    seen: list = []
    loop.set_exception_handler(lambda _loop, ctx: seen.append(ctx))
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    if verb == "ping":
                        return "pong"
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
        assert isinstance(anchor, asyncio.Future), "a send handle must be an asyncio.Future"
        # `anchor` is never awaited; awaiting ping flushes the queued batch, so
        # explode's deliver crosses the wire and the host breaks its answer. The
        # break's FAIL completion is recorded with no waiter -- no exception.
        pong = await session.send(root_ref, "ping", [])
        assert pong == "pong", f"expected pong, got {pong!r}"
        del anchor
        await asyncio.sleep(0.05)  # let the break land
        assert not seen, f"unawaited break must stay silent, saw {seen}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _projections_reach_a_field() -> None:
    """Pipelined projections (ADR-0050/ADR-0052): ``RemotePromise.index(i)`` and
    ``.untag(tag)`` access an element / unwrap a tag *at the answer*, before it
    resolves, each returning a new pipelinable ``RemotePromise``. The board's
    ``make`` returns ``["assigned", label, 7]`` tagged "task"; untag unwraps the
    single-value tag to that row, index 1 takes the label -- a two-hop chain that
    rides the still-pending ``make`` answer with no extra round trip. The source
    handle is also awaited afterward to prove a far reply observed *late* (after
    a sibling projection already pumped the loop) still settles from the
    recorded outcome."""
    server = await tcp.listen("127.0.0.1", 0, host=Host(captp_version="next"))
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    assert verb == "make", verb
                    label = str(args[0]) if args else "anon"
                    # A Tagged wrapping a single list value: untag unwraps to it.
                    return Tagged("task", [["assigned", label, 7]])

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port), host=Host(captp_version="next"))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        # Neither projection awaits a prior reply: they ride the unresolved make
        # answer and the whole chain leaves on one flush.
        made = session.send(root_ref, "make", ["alice"])
        label = await made.untag("task").index(1)
        assert label == "alice", f"pipelined untag->index should reach the label, got {label!r}"
        # The source answer settled while the projection pumped the loop; awaiting
        # it now must still resolve (a late observation settles from the store).
        full = await made
        assert isinstance(full, Tagged) and full.tag == "task", (
            f"awaited source should be the tagged task, got {full!r}"
        )
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _forwarding_proxies_over_the_wire() -> None:
    """Object-capability forwarding proxies over the wire (ADR-0064). The server
    fetches the client's published tool — a far reference on the server side —
    wraps it in a caretaker and an attenuator, and hands the proxies back. A
    call through the proxy forwards across the server to the client's tool (the
    far deferred-answer path) and settles the caller's answer; the attenuator
    passes only its allow-listed verb; and a revoke breaks every later call."""
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
    so its own host calls it locally exactly as a partner calls it over the
    wire. A caretaker over a *local* tool answers a local send; a caretaker
    over a *far* tool forwards across the wire and the local send still
    settles; and a revoke breaks the local call too, no second-class behavior
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

        care_local = session.caretaker(session.spawn(local_tool))
        doubled = await session.send(care_local.proxy, "double", [21])
        assert doubled == 42, f"a local proxy answers a local call, got {doubled!r}"

        # A caretaker over a far tool, called locally: the proxy forwards across
        # the wire and the local send still settles on the partner's reply.
        await asyncio.wait_for(published.wait(), timeout=5)
        far = await session.fetch("tool")
        care_far = session.caretaker(far)
        pong = await session.send(care_far.proxy, "ping", [])
        assert pong == "pong", f"a local call to a proxy over a far tool settles, got {pong!r}"

        # Revoke severs the local call exactly as it severs a partner's.
        care_local.revoke()
        severed = None
        try:
            await session.send(care_local.proxy, "double", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), "revoke breaks a local call too"

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        await server.close()


async def _mid_turn_driving_verb_breaks_the_answer() -> None:
    """The callback latch crosses the binding: a behavior that reaches for a
    host-driving verb mid-turn (publish, here) is refused by the C tier, the
    refusal surfaces as the behavior's own raise, and the answer breaks with
    it — the turn neither deadlocks nor corrupts the host. The connection
    stays fully usable afterwards."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    if verb == "reenter":
                        # A driving verb inside the turn: the latch refuses it
                        # and the raised PancakeError's words become the broken
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
    schedules only the completion barrier; native code owns session teardown."""
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

    host.publish_giftable("svc", svc)

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
        await asyncio.sleep(0)
        assert not callback_errors, callback_errors
    finally:
        loop.set_exception_handler(prior_exception_handler)
        await first.close()
        await second.close()
        await server.close()


async def _send_redeeming_surfaces_the_direct_exporter() -> None:
    """A three-party handoff with pancake as all three parties, over loopback:
    the exporter (Bob) publishes a host-wide giftable inbox, the broker holds it
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

        bob.host.publish_giftable("dm", dm)

        async def accept_all(server) -> None:
            async for session in server:
                session.serve()

        accepting.append(asyncio.ensure_future(accept_all(bob)))
        accepting.append(asyncio.ensure_future(accept_all(broker)))

        # The broker dials Bob under its own identity and fetches his giftable
        # inbox; returning that ref into a *different* session is what trips
        # the transparent gifter.
        broker_to_bob = await tcp_connect(tcp.locator("127.0.0.1", bob.port), host=broker.host)
        broker_to_bob.serve()
        bob_dm = await broker_to_bob.fetch("dm")

        # Replace the alias with a decoy before any introduction: the gift
        # must retain the exact inbox the broker holds, not whatever the name
        # resolves to at withdrawal (ADR-0096, on the binding path).
        decoy_delivered: list = []
        bob.host.publish_giftable(
            "dm",
            lambda verb, args: (decoy_delivered.append(args[0]) if verb == "dm" else None),
        )

        broker.host.publish_giftable(
            "introducer",
            lambda verb, args: bob_dm if verb == "introduce" else "no capability here",
        )

        # Keep Carol's Host on the byte-fed tier. The handoff redeem below must
        # open its exporter TCP channel on that same active Host; attempting to
        # transfer it into the driver would fail and split ownership.
        carol_locator = tcp.locator("127.0.0.1", broker.port)
        carol_host = Host()
        from pancake.tcp import connector as tcp_connector

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
# `pancake.onion` is the one netlayer the OCapN draft standardizes. It reaches a
# Tor daemon the deployment runs, so exercising it here means standing one up: two
# loopback servers answering the exact requests pancake sends. The bytes those
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
# actually offers. Nothing is bound there, so a check that reached it would fail
# rather than quietly connect somewhere.
_ABSENT_SOCKS = "/run/pancake-smoke/absent.socks"


def _fake_socks(sock: "socket.socket", wrote: list[bytes]) -> None:
    """Answer one SOCKS5 handshake, then record the first bytes the dialer sent.

    The fake does not proxy. A real Tor splices the circuit onto the service's
    forward target; what the transport owes is that the stream is a transparent byte
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
    descriptor via asyncio — dial as an operation id, session as an OPENED event,
    vow outcomes as COMPLETION events routed through the adopted wrapper
    Host's vow table, and a hangup. The server publishes through its own
    wrapper Host, so the trampoline, the fetch's settle (a real ``Ref``),
    and a missing-name break (``VowBroken``) all cross the loop tier.
    """
    from pancake._loop import DriverLoop

    ready = threading.Event()
    stop = threading.Event()
    server_errors: list[BaseException] = []
    designator_box: list[str] = []

    def serve() -> None:
        try:
            server = DriverLoop.open(wire_buffer_bytes=1024, max_pending_opens=8)
            asyncio.run(tcp.provider().install(server))
            server.wrapper_host().publish_giftable("widget", lambda verb, args: "poked through the loop tier")
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
        session = await asyncio.wait_for(loop.connect_session(pancake.format_peer_uri("tcp", designator)), 10)
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
    from pancake._loop import DriverLoop

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
        # `PORT=<virtual>,<target>` — the target is what follows the comma.
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
    # It has no incoming circuit, so remaining alive is evidence that it reached
    # the blocking accept rather than failing before the native call.
    time.sleep(0.05)
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
        except PancakeError:
            pass
        # A designator that is not a well-formed version 3 address is refused before
        # any socket opens, so this is an argument fault rather than a dial failure.
        try:
            nl.connect("not-an-onion-address")
            raise AssertionError("a malformed designator should be refused")
        except PancakeError:
            pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"python zig-smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
