"""Internal: the byte-fed embedder pump choreography over the host
(``libpancake_host``, ADR-0072).

Owns the connection byte path the embedder contract leaves to the binding:
read raw bytes off the transport, hand them to the core's stream delimiter
``pancake_host_session_feed_bytes`` (which owns framing), drain the host's
action queue, and write what ``take_outbound`` drains — plus the keyed
handshake, the feed-refusal path (``last_abort``), and the EOF teardown that
``break_far_vows`` classifies as closure. Session methods wrap these through
binding-internal seams (``raw`` / ``host`` / …); CapTP verbs stay
in :mod:`pancake._session`.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import Optional

from . import _constants as _abi
from ._errors import (
    AbortDetail,
    PancakeError,
    _abort_domain_label,
    _check_host,
    _host_last_error,
)
from ._ffi_host import _host
from ._ffi_ocapn import _byte_buf, _LastAbort, _lib, _ManagedFrame
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
    # serve() — otherwise a pipelined fetch would answer before the object it
    # names exists. Abandonment on failure stays on Session._establish.
    await session.host.kick_actions()
    while not session.session_open:
        chunk = await session.transport.read()
        if chunk is None:
            raise PancakeError(_ERR_CLOSED, "connection closed during the OCapN handshake")
        await _feed(session, chunk)


async def _serve_loop(session) -> None:
    try:
        # Frames that rode behind the handshake's tail wait in the session's
        # own tail; an empty feed dispatches them before parking on the wire.
        await _feed(session, b"")
        while True:
            if session.released:
                return
            chunk = await session.transport.read()
            if chunk is None:
                return  # clean EOF
            await _feed(session, chunk)
    except (asyncio.CancelledError, OSError):
        # A read cancelled by our own close is a clean shutdown; any other
        # failure is a real fault the awaiting caller should see.
        if not session.is_closing:
            raise
    finally:
        # The wire is gone: pending far vows can never settle, so break
        # them (classified as closure — `_closing` is set first) and
        # release the conn, freeing the fd. Idempotent with an application
        # `close()`.
        if not session.is_closing:
            session.closing_flag = True
            try:
                msg = b"connection closed"
                buf, ptr = _byte_buf(msg)
                _check_host(_host.pancake_host_session_break_far_vows(
                    session.raw, ptr, len(msg),
                ))
                await session.host.kick_actions()
            except Exception:
                pass  # teardown is best-effort; release still reclaims the rows
            session.close_transport()


async def _feed(session, chunk: bytes) -> None:
    # Feed inbound bytes to the core's stream delimiter: the session's
    # codec splits each complete frame off the front — both codecs, both
    # frame shapes, the frame cap enforced during the scan — and dispatches
    # it, then the actions the dispatch queued drain. The library owns the
    # unconsumed tail — a partial frame straddling two reads stays buffered
    # in the session — so one borrowed call moves the whole chunk (c_char_p
    # points at `chunk`'s own bytes, which the synchronous feed only reads);
    # an empty chunk resumes frames the session held behind its handshake
    # open. A mid-feed close parks its C release; it drains the moment the
    # feed returns.
    if session.released:
        return
    n = len(chunk)
    ptr = ctypes.cast(ctypes.c_char_p(chunk), ctypes.c_void_p) if n else None
    prior = _enter_deliver(session)
    try:
        rc = _host.pancake_host_session_feed_bytes(session.raw, ptr, n)
    finally:
        _exit_deliver(prior)
    session.host.drain_parked_releases()
    if rc != _OK:
        await _raise_feed_refusal(session, rc)
    await session.host.kick_actions()


async def _raise_feed_refusal(session, rc: int) -> None:
    # Capture last_error / last_abort before another verb can clobber them,
    # then run the shared action drain so the projected op:abort (and any
    # CLOSE/FAIL queued with it) leave through the same spine as a steady
    # FLUSH — not a private take_outbound path.
    message = _host_last_error()
    abort = last_abort(session)
    try:
        await session.host.kick_actions()
    except Exception:
        pass  # the transport may already be gone; the local typed error stands
    raise PancakeError(rc, message, abort=abort)


def last_abort(session) -> Optional[AbortDetail]:
    """The typed cause of this CapTP session's most recent local dispatch
    failure, or ``None`` when none has been recorded. The flat per-feed
    error code names the failure family; this names the member. Errors
    raised by a refused feed carry it already as ``err.abort``."""
    if session.released:
        return None
    info = _LastAbort()
    rc = _host.pancake_host_session_last_abort(session.raw, ctypes.byref(info))
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
    )


async def flush_outbound(session) -> None:
    """Drain every encoded outbound frame on this CapTP session and write it
    to the byte-stream transport as a canonical Syrup byte string — how a
    FLUSH action lands. Writes are serialized, so each prefix/body pair stays
    in submission order. Binding-internal."""
    async with session.write_lock:
        while True:
            if session.released:
                return
            mf = _ManagedFrame()
            rc = _host.pancake_host_session_take_outbound(session.raw, ctypes.byref(mf))
            if rc == _WOULD_BLOCK:
                return
            _check_host(rc)
            frame = ctypes.string_at(mf.bytes, mf.len) if mf.bytes else b""
            # The managed frame is the shared core vocabulary, released
            # through the core archive.
            _lib.pancake_managed_frame_release(ctypes.byref(mf))
            await session.transport.write(str(len(frame)).encode("ascii") + b":")
            await session.transport.write(frame)
