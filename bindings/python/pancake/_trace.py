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
import threading
import time
import weakref
from typing import Callable, NamedTuple, Optional

from . import _constants as _abi
from ._ffi_host import _TraceCallback, _host
from ._constants import _provenance_from_abi

TraceSink = Callable[[dict], None]

_sink: Optional[TraceSink] = None
# The display label the application chose for its own endpoint, or None. The
# ``a`` endpoint itself is always the host's own key designator, the name a
# partner knows it by, so one peer stays one node in a feed several producers
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
# source-check`` (``checkTraceViewerVocabulary``) holds all four against each
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
# Every live Host is held weakly beside its cookie and designator. Native trace
# installation always goes through the Host owner, never a raw pointer retained
# in this process-global registry: that keeps installation on the Host's thread
# and makes a stale registry row incapable of calling freed storage. The cookie
# is the callback ctx because a core session id is Host-scoped.
class _TraceHost(NamedTuple):
    owner: weakref.ReferenceType
    cookie: int
    designator: str


_hosts: dict[int, _TraceHost] = {}
_hosts_lock = threading.RLock()
_next_cookie = 1


def _designator_of(cookie: int) -> str:
    """The key designator of the host a callback ctx names. A scan over the
    live hosts, which a process holds one or two of."""
    with _hosts_lock:
        dead = []
        for key, row in _hosts.items():
            if row.owner() is None:
                dead.append(key)
                continue
            if row.cookie == cookie:
                return row.designator
        for key in dead:
            _hosts.pop(key, None)
    return ""


def _owner_of(cookie: int):
    with _hosts_lock:
        for row in _hosts.values():
            if row.cookie == cookie:
                return row.owner()
    return None
# Payload bytes forwarded per message (whole frame under the cap, head +
# true length above it). The binding-policy mirror owns the shared default.
_PAYLOAD_CAP = _abi.BINDING_TRACE_PAYLOAD_CAP_BYTES


def _now_ns() -> int:
    return round((time.monotonic() - _t0) * 1_000_000_000)


def _codec_from_abi(codec: int) -> str:
    if codec == _abi.CODEC_CAPNP:
        return "capnp"
    if codec == _abi.CODEC_SYRUP:
        return "syrup"
    raise ValueError(f"pancake ABI returned unknown trace codec {codec}")


def _captp_version_from_abi(version: int) -> str:
    if version == _abi.CAPTP_NEXT:
        return "pancake-next"
    if version == _abi.CAPTP_V1_0:
        return "1.0"
    raise ValueError(f"pancake ABI returned unknown trace CapTP version {version}")


def _emit(sink: TraceSink, record: dict, owner) -> None:
    """Keep observer failure outside protocol control flow.

    This is especially load-bearing for the ctypes callback: no Python
    exception may cross a native callback frame. An annotation uses the same
    observer-only contract even though it originates on the application side.
    """
    try:
        sink(record)
    except BaseException as error:
        # The Host owns projection and the bounded surviving fallback. No
        # Python exception crosses the C callback frame or alters CapTP.
        owner._record_callerless_failure("trace.sink", error)


def _on_native_event(ctx: int, event_ptr) -> None:
    sink = _sink
    if sink is None:
        return
    ev = event_ptr.contents
    cookie = ctx or 0
    owner = _owner_of(cookie)
    if owner is None:
        return
    try:
        _decode_native_event(sink, owner, cookie, ev)
    except BaseException as error:
        # This is a callerless binding/ABI projection failure, distinct from a
        # sink that rejected a valid event. Nothing may unwind through ctypes.
        owner._record_callerless_failure("trace.decode", error)


def _decode_native_event(sink: TraceSink, owner, cookie: int, ev) -> None:
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
        _emit(sink, record, owner)
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
        _emit(sink, record, owner)
        return
    if ev.kind == _abi.TRACE_SESSION_CLOSE:
        _emit(sink, {
            "v": 1,
            "sim_t_ns": _now_ns(),
            "kind": "ocapn.session-closed",
            "session": session,
        }, owner)
        return
    raise ValueError(f"pancake ABI returned unknown trace event kind {ev.kind}")


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
    the name a partner knows it by and the only one two producers can agree
    on."""
    global _sink, _self_label, _t0
    with _hosts_lock:
        _sink = sink
        _self_label = self_label
        _t0 = time.monotonic()
        owners = _live_hosts_locked()
    for owner in owners:
        _refresh_host(owner)

    def uninstall() -> None:
        global _sink
        with _hosts_lock:
            if _sink is not sink:
                return
            _sink = None
            owners = _live_hosts_locked()
        for owner in owners:
            _refresh_host(owner)

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
    owner = session._host
    owner._assert_owner()
    with _hosts_lock:
        row = _hosts.get(id(owner))
        if row is None or session._ptr is None:
            return
        cookie = row.cookie
    out = ctypes.c_uint64(0)
    code = _host.pancake_host_session_trace_id(session._ptr, ctypes.byref(out))
    if code != 0:
        return
    _emit(sink, {
        "v": 1,
        "sim_t_ns": _now_ns(),
        "kind": "ocapn.session-meta",
        "session": f"live-h{cookie}-s{out.value}",
        "meta": {"label": label},
    }, owner)


def _live_hosts_locked() -> list:
    owners = []
    dead = []
    for key, row in _hosts.items():
        owner = row.owner()
        if owner is None:
            dead.append(key)
        else:
            owners.append(owner)
    for key in dead:
        _hosts.pop(key, None)
    return owners


def _current_install(owner):
    """Read the latest configuration for ``owner`` at execution time.

    Scheduled installs deliberately do not capture a sink generation: an older
    owner-loop callback that runs after uninstall reads the new disabled state
    and therefore cannot restore stale configuration.
    """
    with _hosts_lock:
        row = _hosts.get(id(owner))
        if row is None or row.owner() is not owner:
            return None
        callback = _callback() if _sink is not None else _null_native_cb
        return callback, row.cookie if _sink is not None else None


def _refresh_host(owner) -> None:
    """Apply the latest trace state on a Host's owner thread when possible."""
    def install() -> None:
        current = _current_install(owner)
        raw = owner.raw_or_none
        if current is None or raw is None:
            return
        callback, cookie = current
        _host.pancake_host_set_trace(raw, callback, cookie)

    owner._run_trace_install(install)


def _attach_host(owner, designator: str = "") -> None:
    """Binding-internal: weakly register a Host and reconcile its native tap."""
    global _next_cookie
    with _hosts_lock:
        cookie = _next_cookie
        _next_cookie += 1
        _hosts[id(owner)] = _TraceHost(weakref.ref(owner), cookie, designator)
    _refresh_host(owner)


def _detach_host(owner) -> None:
    """Binding-internal: a releasing Host leaves the weak registry."""
    with _hosts_lock:
        row = _hosts.get(id(owner))
        if row is not None and row.owner() is owner:
            _hosts.pop(id(owner), None)
