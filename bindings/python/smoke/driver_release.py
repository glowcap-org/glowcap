"""Live driver release ownership and recurring safe-boundary retries."""

from __future__ import annotations

import asyncio
import ctypes

import glowcap
import glowcap._driver.finalizer as _driver_finalizer
import glowcap._loop as _loop_module
from glowcap import Host, GlowcapError
from glowcap._constants import ERR_INTERNAL, ERR_INVALID_ARGUMENT, ERR_IO
from glowcap._ffi_driver import _DriverFailure
from glowcap._loop import DriverLoop


def _write_failure(out, code: int, name) -> int:
    failure = ctypes.cast(out, ctypes.POINTER(_DriverFailure)).contents
    failure.primary_result = code
    failure.primary_name = ctypes.addressof(name)
    failure.primary_name_len = len(name.value)
    return code


async def _refused_live_release_retries_at_public_boundary() -> None:
    host = Host()
    loop = DriverLoop.take_host(host)
    original_release = _loop_module._driver.glowcap_driver_release
    refusal_name = ctypes.create_string_buffer(b"RefusedLiveDriverRelease")
    attempts = 0

    def refuse_once(_handle, out) -> int:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return _write_failure(out, ERR_INVALID_ARGUMENT, refusal_name)
        return original_release(_handle, out)

    _loop_module._driver.glowcap_driver_release = refuse_once
    try:
        try:
            await host.close()
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error
        else:
            raise AssertionError("driver release refusal disappeared from Host.close")
        assert not loop._released, "refusal retired a still-live driver"
        assert not host.released, "refusal retired the adopted Host wrapper"
        assert _driver_finalizer._pending_driver_finalizer_retry_count() == 1
        assert attempts == 1

        # Host construction is a public outside-turn boundary. It claims one
        # finite retry batch; the successful retry completes the original Host
        # wrapper without waiting for either wrapper to become garbage.
        boundary = Host()
        await boundary.close()
        assert attempts == 2
        assert loop._released
        assert host.released
        assert _driver_finalizer._pending_driver_finalizer_retry_count() == 0
        assert [failure.code for failure in loop.terminal_failures] == [
            ERR_INVALID_ARGUMENT
        ]

        another = Host()
        await another.close()
        assert attempts == 2, "completed release remained in the retry queue"
    finally:
        _loop_module._driver.glowcap_driver_release = original_release


async def _deferred_consuming_failure_retires_once_and_stays_ordered() -> None:
    glowcap.take_runtime_failures()
    host = Host()
    loop = DriverLoop.take_host(host)
    original_release = _loop_module._driver.glowcap_driver_release
    refusal_name = ctypes.create_string_buffer(b"RefusedLiveDriverRelease")
    consumed_name = ctypes.create_string_buffer(b"ConsumedLiveDriverRelease")
    attempts = 0

    def refuse_then_consume(_handle, out) -> int:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return _write_failure(out, ERR_INVALID_ARGUMENT, refusal_name)
        assert original_release(_handle, out) == 0
        return _write_failure(out, ERR_IO, consumed_name)

    _loop_module._driver.glowcap_driver_release = refuse_then_consume
    try:
        loop._fail_background(RuntimeError("live driver failed"))
        boundary = Host()
        await boundary.close()
        assert attempts == 2
        assert loop._released and host.released
        assert [failure.code for failure in loop.terminal_failures] == [
            ERR_INTERNAL,
            ERR_INVALID_ARGUMENT,
            ERR_IO,
        ]
        assert _driver_finalizer._pending_driver_finalizer_retry_count() == 0
        assert not glowcap.take_runtime_failures(), (
            "live terminal ownership leaked into process finalizer diagnostics"
        )

        another = Host()
        await another.close()
        assert attempts == 2, "consumed release retried a dangling driver"
    finally:
        _loop_module._driver.glowcap_driver_release = original_release


def run() -> None:
    asyncio.run(_refused_live_release_retries_at_public_boundary())
    asyncio.run(_deferred_consuming_failure_retires_once_and_stays_ordered())
