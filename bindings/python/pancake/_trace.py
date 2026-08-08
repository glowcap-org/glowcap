"""The live timeline producer: a veneer over the native tap. The core is the
one owner of the facts -- ``pancake_host_set_trace`` reports every session's
open (with the partner's OCapN locator as designator plus transport, the
Session ID both peers of the session derive, what proved that name, and the codec the
handshake actually negotiated), every message's verb
in both directions, and every close. This veneer only stamps time and
forwards one flat record per fact in the versioned timeline schema; even
endpoint labeling belongs to the consumer (ocapnviz resolves src/dst from
the session-opened it already saw), so nothing here keeps per-session state.

Off by default and zero-cost when off: with no sink installed nothing is
registered with the core, so its emit sites are one null check.

Times are ``sim_t_ns`` per the schema, measured from the sink's install
moment, so a viewer's timeline starts near zero rather than at the epoch.
"""

from __future__ import annotations

import base64 as _b64
import ctypes
import time
from typing import Callable, Optional

from . import _constants as _abi
from ._ffi_host import _TraceCallback, _host
from ._constants import _provenance_from_abi

TraceSink = Callable[[dict], None]

_sink: Optional[TraceSink] = None
# The display label the application chose for its own endpoint, or None. The
# ``a`` endpoint itself is always the host's own key designator, which is what
# a partner names it by, so one peer stays one node in a feed several producers
# share.
_self_label: Optional[str] = None
# What this producer answers when a record asks what it runs. A constant and
# not an option: the host behind this binding is a pancake host, and an
# application naming itself something else would put a claim on the wire that
# nothing here could stand behind. It is stated rather than left implicit
# because this schema is not pancake's alone -- the Goblins conformance peer
# publishes the same records -- so a consumer cannot read an implementation off
# the fact that a record arrived, and a host that says nothing is honestly
# unknown to it. Each of the four bindings states the word itself, because it is
# a claim about the binding tier rather than a fact the core or the C ABI
# carries, so there is no declaration to generate it from. ``zig build
# meta-check`` (``checkTraceViewerVocabulary``) holds all four against each
# other, against the viewer that reads them, and against the Goblins publisher,
# which states a different word and must keep stating it.
_SELF_PROFILE = "pancake"
_t0 = 0.0
# The one native callback object, kept referenced for the process's life so
# ctypes never collects a pointer the core still holds.
_native_cb = None  # type: ignore[assignment]  # ctypes CFUNCTYPE product, not a type
# ctypes callback argtypes reject Python ``None`` on Python 3.13. This is the
# correctly typed null function pointer the C API's nullable callback expects.
_null_native_cb = _TraceCallback()
# Every live Host's raw pointer value, mapped to ``(cookie, designator)`` -- the
# one row per host, looked up by pointer where a caller has one and scanned by
# cookie where a callback has that instead. The cookie is the small integer
# passed as the callback ctx so a record can carry which host it came from: a
# core session id is host-scoped (the Names rule: a bare id needs its namespace
# named), so two hosts in one process would otherwise collide on the same
# session row. The designator is the host's own key designator, reported as the
# session's ``a`` endpoint.
_hosts: dict = {}
_next_cookie = 1


def _designator_of(cookie: int) -> str:
    """The key designator of the host a callback ctx names. A scan over the
    live hosts, which a process holds one or two of."""
    for row_cookie, designator in _hosts.values():
        if row_cookie == cookie:
            return designator
    return ""
# Payload bytes forwarded per message (whole frame under the cap, head +
# true length above it). The TypeScript veneer exposes this as an
# ``enableTrace`` option; make it configurable here when a consumer asks.
_PAYLOAD_CAP = 4096


def _now_ns() -> int:
    return round((time.monotonic() - _t0) * 1_000_000_000)


def _codec_from_abi(codec: int) -> str:
    if codec == _abi.CODEC_CAPNP:
        return "capnp"
    if codec == _abi.CODEC_SYRUP:
        return "syrup"
    return "unknown"


def _captp_version_from_abi(version: int) -> str:
    if version == _abi.CAPTP_NEXT:
        return "pancake-next"
    if version == _abi.CAPTP_V1_0:
        return "1.0"
    return "unknown"


def _on_native_event(ctx: int, event_ptr) -> None:
    sink = _sink
    if sink is None:
        return
    ev = event_ptr.contents
    cookie = ctx or 0
    session = f"live-h{cookie}-s{ev.session}"
    if ev.kind == _abi.TRACE_SESSION_OPEN:
        designator = (
            ctypes.string_at(ev.designator, ev.designator_len).decode(
                "utf-8", "replace",
            )
            if ev.designator and ev.designator_len
            else "peer"
        )
        record = {
            "v": 1,
            "sim_t_ns": _now_ns(),
            "kind": "ocapn.session-opened",
            "session": session,
            "a": _designator_of(cookie),
            "a_profile": _SELF_PROFILE,
            "b": designator,
            "codec": _codec_from_abi(ev.codec),
            "captp_version": _captp_version_from_abi(ev.captp_version),
            "provenance": _provenance_from_abi(ev.provenance).spoken,
        }
        if ev.transport and ev.transport_len:
            record["transport"] = ctypes.string_at(
                ev.transport, ev.transport_len,
            ).decode("utf-8", "replace")
        if _self_label is not None:
            record["a_label"] = _self_label
        if ev.session_id and ev.session_id_len:
            record["session_id"] = ctypes.string_at(
                ev.session_id, ev.session_id_len,
            ).decode("utf-8", "replace")
        sink(record)
        return
    if ev.kind == _abi.TRACE_MESSAGE:
        record = {
            "v": 1,
            "sim_t_ns": _now_ns(),
            "kind": "ocapn.message-decoded",
            "session": session,
            "outbound": bool(ev.outbound),
            # A tag over the frame's bytes, naming this one message across the
            # two peers that carried it: both ends hold the same bytes, so both
            # derive the same tag and a consumer watching a session from both
            # ends draws one message rather than two.
            "digest": bytes(ev.digest).hex(),
        }
        if ev.verb and ev.verb_len:
            record["op"] = ctypes.string_at(ev.verb, ev.verb_len).decode(
                "utf-8", "replace",
            )
        # The frame is borrowed for this call, so the payload copy happens
        # here or never: whole frame under the cap, head + true length
        # above it.
        total_len = ev.frame_total_len or ev.frame_len
        if ev.frame and ev.frame_len:
            record["len"] = total_len
            if total_len <= _PAYLOAD_CAP and ev.frame_len >= total_len:
                record["bytes_b64"] = _b64.b64encode(
                    ctypes.string_at(ev.frame, total_len),
                ).decode("ascii")
            else:
                record["summary"] = {
                    "len": total_len,
                    "head_b64": _b64.b64encode(
                        ctypes.string_at(ev.frame, min(ev.frame_len, _PAYLOAD_CAP)),
                    ).decode("ascii"),
                }
        elif total_len:
            record["len"] = total_len
        sink(record)
        return
    if ev.kind == _abi.TRACE_SESSION_CLOSE:
        sink({
            "v": 1,
            "sim_t_ns": _now_ns(),
            "kind": "ocapn.session-closed",
            "session": session,
        })


def _callback():
    global _native_cb
    if _native_cb is None:
        _native_cb = _TraceCallback(_on_native_event)
    return _native_cb


def enable_trace(
    sink: TraceSink, *, self_label: Optional[str] = None,
) -> Callable[[], None]:
    """Install the sink (replacing any prior one), start the clock, and
    register the native tap on every live Host (a Host minted later registers
    itself). Returns an uninstall that also clears the native tap.

    ``self_label``, when given, is what the producing application would like
    its own endpoint CALLED -- a display name beside the identity, never
    instead of it: the ``a`` endpoint stays the host's own key designator,
    which is what a partner names it by and so the only name two producers can
    agree on."""
    global _sink, _self_label, _t0
    _sink = sink
    _self_label = self_label
    _t0 = time.monotonic()
    for raw, (cookie, _designator) in _hosts.items():
        _host.pancake_host_set_trace(raw, _callback(), cookie)

    def uninstall() -> None:
        global _sink
        if _sink is not sink:
            return
        _sink = None
        for raw in _hosts:
            _host.pancake_host_set_trace(raw, _null_native_cb, None)

    return uninstall


def annotate_session(session, *, label: str) -> None:
    """Annotate a session with application metadata -- the SET half of the
    three-layer annotation design (set where meaning lives, pass through
    dumb, use at the edge): the application that knows what a session MEANS
    (a chat server that knows which member it carries) states it here, and
    the record rides the same stream as the protocol facts, named for the
    same session row the tap names. An annotation is a claim, never
    identity. No sink installed, or a host the trace never attached:
    silently nothing, like every other trace emit."""
    sink = _sink
    if sink is None:
        return
    host_raw = session._host.raw_or_none
    if host_raw is None:
        return
    host_value = host_raw.value if hasattr(host_raw, "value") else host_raw
    row = _hosts.get(host_value)
    if row is None or session._ptr is None:
        return
    cookie = row[0]
    out = ctypes.c_uint64(0)
    code = _host.pancake_host_session_trace_id(session._ptr, ctypes.byref(out))
    if code != 0:
        return
    sink({
        "v": 1,
        "sim_t_ns": _now_ns(),
        "kind": "ocapn.session-meta",
        "session": f"live-h{cookie}-s{out.value}",
        "meta": {"label": label},
    })


def _attach_host(raw, designator: str = "") -> None:
    """Binding-internal: a Host reports its raw pointer and its own key
    designator at construction so an installed trace covers it, and a trace
    installed later finds it. Keyed by the pointer's integer value
    (``c_void_p`` objects are unhashable, and ctypes accepts the integer
    wherever the pointer parameter goes)."""
    global _next_cookie
    value = raw.value if hasattr(raw, "value") else raw
    cookie = _next_cookie
    _next_cookie += 1
    _hosts[value] = (cookie, designator)
    if _sink is not None:
        _host.pancake_host_set_trace(value, _callback(), cookie)


def _detach_host(raw) -> None:
    """Binding-internal: a released Host leaves the registry. The core
    dropped its own sink row with the host, so no native call is needed."""
    _hosts.pop(raw.value if hasattr(raw, "value") else raw, None)
