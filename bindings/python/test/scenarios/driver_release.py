"""Live driver release ownership, recurring safe-boundary retries, and
released session handles."""

from __future__ import annotations

import asyncio
import ctypes

import glowcap
import glowcap._driver.finalizer as _driver_finalizer
import glowcap._loop as _loop_module
from glowcap import GlowcapError, Host, Runtime, tcp
from glowcap._constants import ERR_CLOSED, ERR_INTERNAL, ERR_INVALID_ARGUMENT, ERR_IO
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
        assert [failure.code for failure in loop.terminal_failures] == [ERR_INVALID_ARGUMENT]

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
        assert [failure.code for failure in loop.terminal_failures] == [ERR_INTERNAL, ERR_INVALID_ARGUMENT, ERR_IO]
        assert _driver_finalizer._pending_driver_finalizer_retry_count() == 0
        assert not glowcap.take_runtime_failures(), "live terminal ownership leaked into process finalizer diagnostics"

        another = Host()
        await another.close()
        assert attempts == 2, "consumed release retried a dangling driver"
    finally:
        _loop_module._driver.glowcap_driver_release = original_release


async def _released_session_handle_never_reenters_the_loop() -> None:
    """A listener accepts a session whose dialer refused the handshake, so the
    session is already closed when the application takes it. Taking it
    releases its handle. Serving it afterwards, and closing the loop, must
    not touch that handle again: the loop once wrapped the freed pointer in a
    second Session that stayed registered, and the loop's close then read the
    partner abort through it."""
    honest = await tcp.keyed.listen("127.0.0.1", 0, seed=bytes([0x72]) * 32)
    designator = honest.designator
    await honest.close()
    squatter = await tcp.keyed.listen("127.0.0.1", 0, seed=bytes([0x73]) * 32)
    try:
        async with Runtime.open(providers=[tcp.provider()]) as runtime:
            try:
                await asyncio.wait_for(
                    runtime.connect(tcp.keyed.locator(designator, "127.0.0.1", squatter.port)), timeout=10
                )
            except GlowcapError:
                pass
            else:
                raise AssertionError("a dial to the wrong key was accepted")
        accepted = await asyncio.wait_for(squatter.__anext__(), timeout=10)
        try:
            await asyncio.wait_for(accepted.closed(), timeout=10)
        except GlowcapError:
            pass  # tolerant: the refused dialer drops its socket, failing the session
        assert accepted.released, "a closed accepted session kept its handle"
        key = accepted._key
        loop = squatter._driver_loop
        try:
            await asyncio.wait_for(accepted.serve(), timeout=10)
        except GlowcapError as error:
            assert error.code != ERR_INVALID_ARGUMENT, error
        assert squatter.host.get_session(key) is None, "serve wrapped a released handle in a second Session"
        try:
            loop.adopt_session(key)
        except GlowcapError as error:
            assert error.code == ERR_CLOSED, error
        else:
            raise AssertionError("the loop adopted a released session handle")
        assert accepted.partner_abort() is None, "the dialer refused before sending an abort"
    finally:
        await asyncio.wait_for(squatter.close(), timeout=10)


async def _raw_release_of_a_wrapped_handle_retires_its_session() -> None:
    """``session_release`` by raw handle on a handle a Session wraps releases
    it through that Session, so the wrapper retires with its handle and a
    second release is refused before any FFI call reads the pointer."""
    listener = await tcp.keyed.listen("127.0.0.1", 0, seed=bytes([0x74]) * 32)
    try:
        async with Runtime.open(providers=[tcp.provider()]) as runtime:
            dialed = await asyncio.wait_for(
                runtime.connect(tcp.keyed.locator(listener.designator, "127.0.0.1", listener.port)), timeout=10
            )
            accepted = await asyncio.wait_for(listener.__anext__(), timeout=10)
            key = accepted._key
            loop = listener._driver_loop
            loop.session_release(key)
            assert accepted.released, "a raw release left its Session holding the handle"
            assert listener.host.get_session(key) is None, "a raw release left its Session registered"
            try:
                loop.session_release(key)
            except GlowcapError as error:
                assert error.code == ERR_CLOSED, error
            else:
                raise AssertionError("a second raw release reached the driver")
            await dialed.close()
    finally:
        await asyncio.wait_for(listener.close(), timeout=10)


def run() -> None:
    asyncio.run(_refused_live_release_retries_at_public_boundary())
    asyncio.run(_deferred_consuming_failure_retires_once_and_stays_ordered())
    asyncio.run(_released_session_handle_never_reenters_the_loop())
    asyncio.run(_raw_release_of_a_wrapped_handle_retires_its_session())
