"""The managed-runtime harness the scenarios run inside, and the driver's
transactional surface: connector install, cancelled dials, completion
failure categories, and Runtime.open preserving caller-owned Hosts."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar

import glowcap._loop as _loop_module
from glowcap._lifecycle import _close_options
from glowcap._errors import _retain_cleanup_failure, _retain_terminal_failure
from glowcap._server import _rollback_listener_construction

from glowcap import (
    tcp,
    Locator,
    Host,
    GlowcapError,
    PendingWork,
    Runtime,
)
from glowcap._transport import Connector, Provider
from glowcap._constants import (
    ERR_CLOSED,
    ERR_INVALID_ARGUMENT,
    ERR_INTERNAL,
    ERR_IO,
    TRANSPORT_KEYED_TCP,
    TRANSPORT_NOISE_TCP,
    TRANSPORT_TCP,
)



_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)

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
        except GlowcapError:
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
    import glowcap._dial as dial_module

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

    original_pending = dial_module._host.glowcap_host_pending_dial
    original_failed = dial_module._host.glowcap_host_dial_failed
    original_clone = dial_module._OwnedLocator.__dict__["clone_view"]
    original_dial = dial_module.dial_exporter
    dial_module._host.glowcap_host_pending_dial = pending_dial
    dial_module._host.glowcap_host_dial_failed = dial_failed
    setattr(
        dial_module._OwnedLocator,
        "clone_view",
        classmethod(lambda _cls, _view: OwnedLocatorStub()),
    )
    dial_module.dial_exporter = blocked_dial
    try:
        task = asyncio.create_task(dial_module.run_dial_ticket(HostStub(), 7, 0))
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
        dial_module._host.glowcap_host_pending_dial = original_pending
        dial_module._host.glowcap_host_dial_failed = original_failed
        setattr(dial_module._OwnedLocator, "clone_view", original_clone)
        dial_module.dial_exporter = original_dial


async def _driver_completion_preserves_failure_category() -> None:
    from glowcap import _constants
    from glowcap._host_action_gen import Fail
    from glowcap._loop import DriverLoop, LoopEvent

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
    except GlowcapError as error:
        assert error.code == _constants.ERR_CLOSED, error
    else:
        raise AssertionError("failed driver completion resolved successfully")


async def _runtime_open_is_transactional() -> None:
    """Failed Runtime setup releases only resources it already owns."""

    original_take_host = _loop_module._driver.glowcap_driver_take_host
    original_host_release = _loop_module._host.glowcap_host_release
    release_calls = 0

    def refuse_take_host(_host, _options, _out) -> int:
        return ERR_INVALID_ARGUMENT

    def release_then_report_failure(raw) -> int:
        nonlocal release_calls
        release_calls += 1
        assert original_host_release(raw) == 0
        return ERR_IO

    _loop_module._driver.glowcap_driver_take_host = refuse_take_host
    _loop_module._host.glowcap_host_release = release_then_report_failure
    try:
        try:
            _loop_module.DriverLoop.open()
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
            assert error.secondary_count == 1, error.secondary
            assert len(error.secondary) == 1, error.secondary
            assert isinstance(error.secondary[0], GlowcapError), error.secondary
            assert error.secondary[0].code == ERR_IO, error.secondary
        else:
            raise AssertionError("failed driver adoption opened a loop")
        assert release_calls == 1, release_calls
    finally:
        _loop_module._driver.glowcap_driver_take_host = original_take_host
        _loop_module._host.glowcap_host_release = original_host_release

    async with Host() as managed_host:
        assert not managed_host.released
    assert managed_host.released, "Host async context did not cross its close barrier"

    async def never(_host, _locator, _timeout):
        raise AssertionError("the failed connector must never be dialed")

    connector = Connector(("runtime-test",), never)

    retryable = await Runtime.open(connector=connector)
    try:
        await retryable.close(grace=1)
    except GlowcapError as error:
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
        except GlowcapError as error:
            assert error.code == ERR_CLOSED, error
        else:
            raise AssertionError("closed Runtime admitted another operation")

    grace_host = Host()
    try:
        maximum = _close_options(PendingWork.FINISH, 0xFFFF_FFFF / 1_000)
        assert maximum.grace_ms == 0xFFFF_FFFF
        try:
            await grace_host.close(PendingWork.FINISH, grace=10**10_000)
        except GlowcapError as error:
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
    setup_failure = GlowcapError(
        ERR_INVALID_ARGUMENT, "synthetic connector install failure"
    )
    cleanup_failure = RuntimeError("synthetic failed-open cleanup failure")

    retained_primary = GlowcapError(ERR_INVALID_ARGUMENT, "synthetic primary")
    retained_cleanup = GlowcapError(ERR_IO, "synthetic cleanup")
    assert _retain_cleanup_failure(retained_primary, retained_cleanup) is retained_primary
    assert retained_primary.secondary == (retained_cleanup,)
    assert retained_primary.secondary_count == 1

    rollback_primary = GlowcapError(ERR_INVALID_ARGUMENT, "listener setup failed")
    listener_cleanup = GlowcapError(ERR_IO, "listener cleanup failed")
    loop_cleanup = GlowcapError(ERR_INTERNAL, "loop cleanup failed")
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
    assert _retain_terminal_failure(retained_occurrences, occurrence_count, retained_occurrences[0]) == 65
    overflow = RuntimeError("unretained overflow")
    occurrence_count = _retain_terminal_failure(retained_occurrences, occurrence_count, overflow)
    occurrence_count = _retain_terminal_failure(retained_occurrences, occurrence_count, overflow)
    assert occurrence_count == 67
    assert len(retained_occurrences) == 64
    saturated = (1 << 32) - 1
    assert _retain_terminal_failure(retained_occurrences, saturated, overflow) == saturated

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
        except GlowcapError as error:
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
        except GlowcapError as error:
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
        raise GlowcapError(ERR_INVALID_ARGUMENT, "synthetic provider install failure")

    created_provider_loop = None

    async def fail_created_provider(loop) -> None:
        nonlocal created_provider_loop
        created_provider_loop = loop
        raise GlowcapError(ERR_INVALID_ARGUMENT, "synthetic provider install failure")

    created_runtime = Runtime.open(provider=Provider(fail_created_provider))
    try:
        await created_runtime
    except GlowcapError as error:
        assert error.code == ERR_INVALID_ARGUMENT, error
    else:
        raise AssertionError("failed provider installation opened a Runtime")
    assert created_provider_loop is not None
    assert created_provider_loop._released, "failed provider setup returned before its created loop released"
    for _ in range(2):
        try:
            await created_runtime.close()
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("failed Runtime close forgot its opening failure")

    install_started = asyncio.Event()
    finish_install = asyncio.Event()
    slow_loop = None

    async def slow_install(loop) -> None:
        nonlocal slow_loop
        slow_loop = loop
        install_started.set()
        await finish_install.wait()
        await tcp.provider().install(loop)

    closing_runtime = Runtime.open(provider=Provider(slow_install))
    opening = asyncio.create_task(closing_runtime._ensure_open())
    await install_started.wait()
    closing = asyncio.create_task(closing_runtime.close())
    await asyncio.sleep(0)
    closing.cancel()
    finish_install.set()
    try:
        await closing
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled Runtime close hid its cancellation")
    await asyncio.gather(opening, return_exceptions=True)
    assert closing_runtime._closed, "cancelled close left its Runtime live"
    assert slow_loop is not None and slow_loop._released, "cancelled close leaked its installed loop"

    supplied = Host()
    runtime = Runtime.open(
        adopt_host=supplied,
        provider=Provider(fail_provider),
    )
    try:
        try:
            await runtime
        except GlowcapError as error:
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

    from glowcap._loop import DriverLoop

    installer_called = False

    async def fail_existing_install(_loop) -> None:
        nonlocal installer_called
        installer_called = True
        raise GlowcapError(ERR_INVALID_ARGUMENT, "synthetic existing-loop install failure")

    existing_host = Host()
    existing_loop = DriverLoop.take_host(existing_host)
    runtime = Runtime.open(
        adopt_host=existing_host,
        provider=Provider(fail_existing_install),
    )
    try:
        try:
            await runtime
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("failed existing-loop provider installation opened a Runtime")
        assert installer_called, "Runtime bypassed provider installation for an existing driver loop"
        assert not existing_host.released, "failed open released a caller-owned driver loop"
    finally:
        existing_loop.close()

