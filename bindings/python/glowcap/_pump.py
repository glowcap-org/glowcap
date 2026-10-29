"""Internal: the byte-fed embedder pump choreography over the host
(``libglowcap_host``, ADR-0022).

Owns the connection byte path the embedder contract leaves to the binding:
read raw bytes off the transport, hand them to the core's stream delimiter
``glowcap_host_session_feed_bytes`` (which owns framing), drain the host's
action queue, and write what ``take_outbound`` drains: plus the keyed
handshake, the feed-refusal path (``last_abort``), and the EOF teardown that
``transport_closed`` reports to the core. Session methods wrap these through
binding-internal seams (``raw`` / ``host`` / …). CapTP verbs stay
in :mod:`glowcap._session`.

Reading and writing are separate tasks: the session's writer
(:mod:`glowcap._session.writer`) performs every write. The core bounds each
session's outbound queue and refuses input past its high-water mark, so the
reader needs no second bound of its own.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import Optional

from . import _constants as _abi
from ._errors import (
    AbortDetail,
    GlowcapError,
    _abort_domain_label,
    _check_host,
    _host_last_error,
)
from ._ffi_host import _host
from ._ffi_ocapn import _byte_buf, _copy_managed_frame, _LastAbort
from ._trampoline import _enter_deliver, _exit_deliver

_OK = _abi.OK
_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED


async def _run_handshake(session) -> None:
    # Drive a freshly opened connection's keyed handshake to an open session.
    # The signed op:start-session was encoded by the open; its FLUSH is on the
    # action queue, so the drain puts it on the wire first. The core stops
    # consuming at the frame that opens the session, so a fast partner's
    # application frames coalesced behind start-session stay buffered until
    # the Host-owned resume step: otherwise a pipelined fetch would answer
    # before the object it names exists. Abandonment on failure stays on
    # Session._establish.
    await session.host.kick_actions()
    while not session.session_open:
        chunk = await session.transport.read()
        if chunk is None:
            raise GlowcapError(_ERR_CLOSED, "connection closed during the OCapN handshake")
        await _feed(session, chunk)


async def _serve_loop(session) -> None:
    failure: BaseException | None = None
    try:
        await _resume_feed(session)
        while True:
            if session.released or session.close_delivered:
                break
            chunk = await session.transport.read()
            if chunk is None:
                # Leave the read loop, then report transport closure and
                # retire the wrapper below. Returning here would resolve
                # serve() while the Host still indexed a dead session.
                session.mark_transport_lost()
                break  # clean EOF
            if session.close_delivered:
                break
            await _feed(session, chunk)
    except (asyncio.CancelledError, OSError) as error:
        # A read cancelled by our own close, or one that fails after the core
        # ended the session, is a clean shutdown; any other failure is a real
        # fault the awaiting caller should see.
        if session.close_delivered:
            session.mark_transport_lost()
        elif not session.is_closing:
            session.mark_transport_lost()
            session.record_wire_failure(error)
            failure = error
    except BaseException as error:
        if not session.is_closing and not session.close_delivered:
            session.mark_transport_lost()
            session.record_wire_failure(error)
            failure = error

    # Preserve a feed/read failure as primary. On a clean EOF, failure to tell
    # the core that the wire disappeared is itself the serve failure; it must
    # not look like a successful end of stream. An application-driven close
    # already has its own result path, so its redundant report remains cleanup.
    # A delivered CLOSE already retired the session, and its writer owns the
    # transport close, so serve() returns once that writer has released it.
    if session.close_delivered:
        await session.writer_exited()
    elif not session.released:
        was_closing = session.is_closing
        session.closing_flag = True
        try:
            msg = b"connection closed"
            buf, ptr = _byte_buf(msg)
            _check_host(_host.glowcap_host_session_transport_closed(
                session.raw, ptr, len(msg),
            ))
            # The physical loss retires close-relevant session state; wake
            # any parked close driver.
            session.host.signal_close_activity()
            await session.host.kick_actions()
        except BaseException as error:
            if failure is None and not was_closing:
                session.record_wire_failure(error)
                failure = error
        try:
            session.close_transport()
        except BaseException as error:
            if failure is None and not was_closing:
                session.record_wire_failure(error)
                failure = error

    if failure is not None:
        raise failure
    session.raise_wire_failure()


async def _feed(session, chunk: bytes) -> None:
    # Feed inbound bytes to the core's stream delimiter: the session's
    # codec splits each complete frame off the front, both codecs, both
    # frame shapes, the frame cap enforced during the scan, and dispatches
    # it, then the actions the dispatch queued drain. The library owns the
    # unconsumed tail, a partial frame straddling two reads stays buffered
    # in the session, so one borrowed call moves the whole chunk (c_char_p
    # points at `chunk`'s own bytes, which the synchronous feed only reads).
    # The serve loop resumes any handshake-held tail through _resume_feed. A
    # mid-feed close parks its C release; it drains the moment the feed returns.
    n = len(chunk)
    ptr = ctypes.cast(ctypes.c_char_p(chunk), ctypes.c_void_p) if n else None
    while True:
        if session.released:
            return
        prior = _enter_deliver(session)
        try:
            rc = _host.glowcap_host_session_feed_bytes(session.raw, ptr, n)
        finally:
            _exit_deliver(prior)
        session.host.drain_parked_releases()
        # The feed dispatched frames and may have advanced close-relevant
        # state even when it queued no action; wake any parked close driver.
        session.host.signal_close_activity()
        if rc == _OK:
            break
        if rc == _WOULD_BLOCK:
            await _await_outbound_room(session)
            continue
        await _raise_feed_refusal(session, rc)
    await session.host.kick_actions()


async def _resume_feed(session) -> None:
    # Resume frames the Host held behind the handshake open. Stream sessions
    # may dispatch a retained tail; packet-framed sessions have no hidden tail.
    while True:
        if session.released:
            return
        prior = _enter_deliver(session)
        try:
            rc = _host.glowcap_host_session_resume_feed(session.raw)
        finally:
            _exit_deliver(prior)
        session.host.drain_parked_releases()
        session.host.signal_close_activity()
        if rc == _OK:
            break
        if rc == _WOULD_BLOCK:
            await _await_outbound_room(session)
            continue
        await _raise_feed_refusal(session, rc)
    await session.host.kick_actions()


async def _await_outbound_room(session) -> None:
    # The core refused input until its outbound queue drains below the
    # high-water mark. Drain queued work into frames, then wait for the writer
    # to take them before the caller feeds again.
    await session.host.kick_actions()
    await session.written(session.request_flush())


async def _raise_feed_refusal(session, rc: int) -> None:
    # Capture last_error / last_abort before another verb can clobber them,
    # then run the shared action drain so the projected op:abort (and any
    # CLOSE/FAIL queued with it) leave through the same spine as a steady
    # FLUSH: not a private take_outbound path. The serve loop reports the
    # transport closed next, so the abort must be written first.
    message = _host_last_error()
    abort = last_abort(session)
    drain_failure: BaseException | None = None
    try:
        await session.host.kick_actions()
        await session.written(session.request_flush())
    except BaseException as error:
        drain_failure = error
    refusal = GlowcapError(rc, message, abort=abort)
    if drain_failure is not None:
        raise refusal from drain_failure
    raise refusal


def last_abort(session) -> Optional[AbortDetail]:
    """The typed cause of this CapTP session's most recent local dispatch
    failure, or ``None`` when none has been recorded. The flat per-feed
    error code names the failure family. This names the member. Errors
    raised by a refused feed carry it already as ``err.abort``."""
    if session.released:
        return None
    info = _LastAbort()
    rc = _host.glowcap_host_session_last_abort(session.raw, ctypes.byref(info))
    if rc == _WOULD_BLOCK:
        return None
    _check_host(rc)

    def text(ptr, length) -> str:
        return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""

    return AbortDetail(
        domain=_abort_domain_label(info.domain),
        kind=text(info.kind_name, info.kind_name_len) if info.has_kind else None,
        message=text(info.message, info.message_len),
        error_name=text(info.error_name, info.error_name_len),
        abort_delivery_error_name=(
            text(info.abort_delivery_error_name, info.abort_delivery_error_name_len)
            if info.abort_delivery_error_name_len
            else None
        ),
        secondary_error_name=(
            text(info.secondary_error_name, info.secondary_error_name_len)
            if info.secondary_error_name_len
            else None
        ),
        secondary_error_count=info.secondary_error_count,
    )


async def flush_outbound(session) -> bool:
    """Drain transport-ready prefix/payload vectors and write them in order,
    returning whether any frame left the core. Only the session's writer calls
    this, so one drain runs at a time.

    The host owns whether a prefix is present: clear sessions return canonical
    outer framing, while sealed sessions return wire-ready payloads with an
    empty prefix. Binding-internal.
    """
    scratch = session.outbound_scratch
    wrote = False
    try:
        while True:
            if session.released:
                return wrote
            rc = _host.glowcap_host_session_take_outbound(
                session.raw,
                ctypes.byref(scratch.frame),
                scratch.prefix,
                len(scratch.prefix),
                ctypes.byref(scratch.prefix_len),
            )
            if rc == _WOULD_BLOCK:
                return wrote
            _check_host(rc)
            frame = _copy_managed_frame(scratch.frame)
            wrote = True
            if scratch.prefix_len.value:
                await session.transport.write(
                    bytes(scratch.prefix[:scratch.prefix_len.value])
                )
            await session.transport.write(frame)
    except BaseException as error:
        # `take_outbound` transferred the frame and a failed/cancelled
        # write may have put only a prefix on the stream. The session is
        # no longer retryable; release it so every far vow settles closed. status-allow: lifecycle transition
        session.record_outbound_failure(error)
        session.close_transport()
        raise
