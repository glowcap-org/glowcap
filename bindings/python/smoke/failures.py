"""Native failure observability: stale archives refuse before use, release
refusals stay owned, async close and settlement failures reach their Host
seam, finalizer and allocator-callback exceptions stay nonfatal."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar
import gc

import ctypes
import pancake
import pancake._driver.finalizer as _driver_finalizer
import pancake._host as _host_module
from pancake._action import _answer_gift_id
from pancake._archive_contract import require_archive_fingerprint
from pancake._gc import HostGc
from pancake._errors import _retain_cleanup_failure
from pancake._failure import _RuntimeFailureQueue
from pancake._ffi_driver import _DriverFailure
from pancake._driver_failure import _decode as _decode_driver_failure
from pancake._constants import (
    CARRIER_DETAIL_ENGINE_CODE,
    CARRIER_DETAIL_PEER_ALERT,
    CARRIER_PHASE_SECURE_HANDSHAKE,
)

from pancake import (
    Context,
    FailureLayer,
    Host,
    PancakeError,
    Runtime,
)
from pancake._native import NativeHandle
from pancake._ws import _WebSocketTransport
from pancake._constants import (
    DEFAULT_FAILURE_PAYLOAD_CAP,
    ERR_INVALID_ARGUMENT,
    ERR_INTERNAL,
    ERR_IO,
    ERR_NULL_POINTER,
)


_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar(
    "scenario_runtimes", default=None
)


def _gift_id_completion_preserves_native_refusal() -> None:
    entropy_failure = RuntimeError("entropy unavailable")
    failed = 0

    def mark_failed() -> None:
        nonlocal failed
        failed += 1

    def refuse_entropy() -> bytes:
        raise entropy_failure

    def unexpected_provide(_gift_id: bytes) -> None:
        raise AssertionError("entropy failure reached provide")

    _answer_gift_id(
        refuse_entropy,
        unexpected_provide,
        mark_failed,
    )
    assert failed == 1, failed

    refusal = RuntimeError("ticket refused")

    def refuse_provide(_gift_id: bytes) -> None:
        raise refusal

    try:
        _answer_gift_id(lambda: bytes(32), refuse_provide, mark_failed)
    except RuntimeError as observed:
        assert observed is refusal
    else:
        raise AssertionError("provide refusal disappeared")
    assert failed == 1, "provide refusal was misreported as entropy failure"


def _stale_archive_is_refused_before_use() -> None:
    class _ReadFingerprint:
        def __init__(self, value: int) -> None:
            self.value = value
            self.argtypes = None
            self.restype = None

        def __call__(self) -> int:
            return self.value

    class _Archive:
        pancake_test_archive_fingerprint = _ReadFingerprint(0x5678)

    try:
        require_archive_fingerprint(_Archive(), "test", 0x1234)
    except RuntimeError as error:
        assert "callable surface does not match" in str(error), error
        assert "rebuild the native libraries" in str(error), error
    else:
        raise AssertionError("stale native archive was admitted")


def _driver_failure_preserves_carrier_detail() -> None:
    primary = ctypes.create_string_buffer(b"ProviderConfigurationConflict")
    secondary = ctypes.create_string_buffer(b"PackageReleaseFailed")
    raw = _DriverFailure()
    raw.primary_result = ERR_INVALID_ARGUMENT
    raw.primary_name = ctypes.addressof(primary)
    raw.primary_name_len = len(primary.value)
    raw.secondary_result = ERR_IO
    raw.secondary_count = 3
    raw.secondary_name = ctypes.addressof(secondary)
    raw.secondary_name_len = len(secondary.value)
    raw.carrier_phase = CARRIER_PHASE_SECURE_HANDSHAKE
    raw.carrier_detail_flags = CARRIER_DETAIL_PEER_ALERT | CARRIER_DETAIL_ENGINE_CODE
    raw.carrier_verification_flags = 0x21
    raw.carrier_peer_alert = 42
    raw.carrier_engine_code = -0x2700
    outcome = _decode_driver_failure(raw.primary_result, raw, "install")
    assert outcome.error is not None
    assert outcome.error.secondary_count == 3
    carrier = outcome.error.carrier_failure
    assert carrier is not None
    assert carrier.phase.value == "secure_handshake"
    assert carrier.verification_flags == 0x21
    assert carrier.peer_alert == 42
    assert carrier.engine_code == -0x2700


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
    connector_primary = PancakeError(ERR_INTERNAL, "connector establishment failed")
    await _rollback_failed_transport(connector_primary, transport)
    assert transport.closed, "connector rollback did not start transport close"
    assert connector_primary.secondary == (rollback_failure,)
    assert connector_primary.secondary_count == 1
    assert host.terminal_failures == (
        failure,
        consequence,
        drain_failure,
    ), host.terminal_failures

    provider_failure = RuntimeError("provider rollback failed")
    provider_primary = PancakeError(ERR_INTERNAL, "provider install failed")

    def fail_provider_rollback() -> None:
        raise provider_failure

    _rollback_failed_provider(provider_primary, fail_provider_rollback)
    assert provider_primary.secondary == (provider_failure,)
    assert provider_primary.secondary_count == 1
    assert host.terminal_failures == (
        failure,
        consequence,
        drain_failure,
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
    assert len(truncated.operation.encode()) <= DEFAULT_FAILURE_PAYLOAD_CAP, truncated
    assert truncated.truncated_fields & 1, truncated

    unicode_queue = _RuntimeFailureQueue(1)
    unicode_queue.record(FailureLayer.BINDING, "☃" * 600, RuntimeError("unretained"))
    unicode_truncated = unicode_queue.claim()[0]
    assert len(unicode_truncated.operation.encode()) <= DEFAULT_FAILURE_PAYLOAD_CAP, unicode_truncated
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

    malformed_queue = _RuntimeFailureQueue(1)

    class MalformedError(RuntimeError):
        secondary_count = 3
        secondary = ()

    malformed = MalformedError("foreign exception with contradictory metadata")
    malformed_queue.record(FailureLayer.APPLICATION_OBSERVER, "observer", malformed)
    normalized = malformed_queue.claim()[0]
    assert normalized.secondary_count == 0, normalized
    assert normalized.secondary_result == 0, normalized
    assert normalized.secondary_name == "", normalized

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

    refused_state = _driver_finalizer._DriverFinalizerState(123, FinalizerContext())
    original_release = _driver_finalizer._driver.pancake_driver_release
    attempts = 0
    refused_name = ctypes.create_string_buffer(b"RefusedDriverRelease")
    cleanup_name = ctypes.create_string_buffer(b"ReleaseRollbackFailed")

    def refuse_once(_handle, out) -> int:
        nonlocal attempts
        attempts += 1
        if attempts != 1:
            return 0
        failure = ctypes.cast(out, ctypes.POINTER(_DriverFailure)).contents
        failure.primary_result = ERR_INVALID_ARGUMENT
        failure.primary_name = ctypes.addressof(refused_name)
        failure.primary_name_len = len(refused_name.value)
        failure.secondary_result = ERR_IO
        failure.secondary_count = 2
        failure.secondary_name = ctypes.addressof(cleanup_name)
        failure.secondary_name_len = len(cleanup_name.value)
        return ERR_INVALID_ARGUMENT

    _driver_finalizer._driver.pancake_driver_release = refuse_once
    try:
        _driver_finalizer._release_driver_finalizer_state(refused_state)
        assert refused_state.handle is not None, (
            "refused final release lost its native lease"
        )
        assert len(reports) == 1, reports
        assert reports[0]["operation"] == "driver-loop.finalize.release", reports
        assert reports[0]["primary_result"] == ERR_INVALID_ARGUMENT, reports
        assert reports[0]["primary_name"] == "RefusedDriverRelease", reports
        assert reports[0]["secondary_name"] == "ReleaseRollbackFailed", reports
        assert reports[0]["secondary_count"] == 2, reports
        # A public Host construction is an ordinary safe runtime boundary; it
        # drains the claimed driver-finalizer batch without a private retry.
        boundary = Host()
        asyncio.run(boundary.close())
        assert refused_state.handle is None, (
            "successful retry retained the native lease"
        )
        assert len(reports) == 1, "release retry duplicated its diagnostic"
    finally:
        _driver_finalizer._driver.pancake_driver_release = original_release
        with _driver_finalizer._deferred_driver_finalizers_lock:
            if refused_state in _driver_finalizer._deferred_driver_finalizers:
                _driver_finalizer._deferred_driver_finalizers.remove(refused_state)

    consumed_state = _driver_finalizer._DriverFinalizerState(456, FinalizerContext())
    consumed_name = ctypes.create_string_buffer(b"ConsumedDriverRelease")

    def consumed_failure(_handle, out) -> int:
        failure = ctypes.cast(out, ctypes.POINTER(_DriverFailure)).contents
        failure.primary_result = ERR_IO
        failure.primary_name = ctypes.addressof(consumed_name)
        failure.primary_name_len = len(consumed_name.value)
        return ERR_IO

    _driver_finalizer._driver.pancake_driver_release = consumed_failure
    try:
        _driver_finalizer._release_driver_finalizer_state(consumed_state)
        assert consumed_state.handle is None, (
            "consumed release failure retained a dangling lease"
        )
        assert len(reports) == 2, reports
        assert reports[1]["primary_result"] == ERR_IO, reports
        with _driver_finalizer._deferred_driver_finalizers_lock:
            assert consumed_state not in _driver_finalizer._deferred_driver_finalizers
    finally:
        _driver_finalizer._driver.pancake_driver_release = original_release

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
