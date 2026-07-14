"""Internal: the OCapN locator URI grammar.

The ``ocapn://<designator>.<transport>[?hints]`` grammar is core OCapN
vocabulary, defined once in ``libpancake_ocapn``'s ``pancake_uri_*`` /
``pancake_locator_*`` surface, so no binding hand-rolls a percent codec.
:func:`parse_locator` copies every borrowed view into Python strings before
releasing the handle; :func:`format_peer_uri` renders through the same grammar.
:func:`encode_peer_locator` builds the verbatim exporter location record a
gifter embeds in a give, and :data:`REDEEMED_TOKEN_BASE` names the reserved
far-id range redeemed-handoff tokens draw from. Re-exported from the
:mod:`pancake` package; import from there.
"""

from __future__ import annotations

from typing import NamedTuple, Optional

import ctypes

from . import _constants as _abi
from ._errors import PancakeError, _check
from ._ffi_ocapn import _lib

_OK = _abi.OK
_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_ERR_BUFFER_TOO_SMALL = _abi.ERR_BUFFER_TOO_SMALL

# A redeemed-handoff token is a far id from a reserved high range, disjoint from
# any wire import, so it can never alias one (PANCAKE_REDEEMED_TOKEN_BASE).
REDEEMED_TOKEN_BASE = _abi.REDEEMED_TOKEN_BASE


def encode_peer_locator(transport: str, designator: str, direct_addresses: str = "") -> bytes:
    """Build the verbatim exporter location-record bytes a gifter embeds in a give
    when the exporter is reachable only by a dial hint (ADR-0009), the
    construct-it-yourself counterpart of the partner's signed session record, for
    an exporter whose own record carries no hint. ``transport``/``designator`` name
    the exporter; a non-empty ``direct_addresses`` (comma-separated socket
    addresses) adds a ``direct-addresses`` hint so a cross-process recipient dials
    it directly with no discovery service (an iroh exporter reachable only by
    address). The result feeds :meth:`Session.set_exporter_locator`. An empty
    ``direct_addresses`` yields a hint-less location identical to the exporter's
    own signed record, so a TCP or discovery-reachable exporter needs no
    override."""
    out_loc = ctypes.c_void_p()
    out_len = ctypes.c_size_t()
    t_b = ctypes.create_string_buffer(transport.encode(), len(transport.encode()))
    d_b = ctypes.create_string_buffer(designator.encode(), len(designator.encode()))
    a_b = ctypes.create_string_buffer(direct_addresses.encode(), len(direct_addresses.encode()))
    _check(_lib.pancake_encode_peer_locator(
        ctypes.cast(t_b, ctypes.c_void_p), len(transport.encode()),
        ctypes.cast(d_b, ctypes.c_void_p), len(designator.encode()),
        ctypes.cast(a_b, ctypes.c_void_p), len(direct_addresses.encode()),
        ctypes.byref(out_loc), ctypes.byref(out_len),
    ))
    try:
        return ctypes.string_at(out_loc, out_len.value)
    finally:
        _lib.pancake_peer_locator_bytes_release(out_loc, out_len.value)


class Locator(NamedTuple):
    """A parsed OCapN locator: the fields a ``pancake_uri_parse_*`` yields.
    ``swissnum`` is empty for a peer URI, the swiss bytes for a sturdyref.
    ``host``/``port`` carry the designator's ``host:port`` split when the core
    grammar (``pancake_locator_host_port``) accepts it, ``None`` otherwise; a
    socket dialer consumes the split instead of re-deriving it."""

    transport: str
    designator: str
    swissnum: str
    hints: "dict[str, str]"
    host: "Optional[str]" = None
    port: "Optional[int]" = None


def _read_view(ptr: ctypes.c_void_p, length: ctypes.c_size_t) -> str:
    # Decode a borrowed (pointer, length) view a locator accessor filled. A zero
    # length (or NULL pointer) is the empty string.
    n = length.value
    if n == 0 or not ptr.value:
        return ""
    return ctypes.string_at(ptr.value, n).decode("utf-8")


def parse_locator(uri: str, *, sturdyref: bool = False) -> Locator:
    """Parse an ``ocapn://`` URI into its structured locator fields through the
    core grammar. ``sturdyref`` selects the ``/s/<swiss>`` form; the default reads
    a peer URI. Raises :class:`PancakeError` for a malformed URI."""
    raw = uri.encode("utf-8")
    out = ctypes.c_void_p()
    parse = _lib.pancake_uri_parse_sturdyref if sturdyref else _lib.pancake_uri_parse_peer
    _check(parse(raw, len(raw), ctypes.byref(out)))
    try:
        def field(accessor) -> str:
            p = ctypes.c_void_p()
            n = ctypes.c_size_t()
            _check(accessor(out, ctypes.byref(p), ctypes.byref(n)))
            return _read_view(p, n)

        count = ctypes.c_size_t()
        _check(_lib.pancake_locator_hint_count(out, ctypes.byref(count)))
        hints: "dict[str, str]" = {}
        for i in range(count.value):
            kp = ctypes.c_void_p()
            kn = ctypes.c_size_t()
            vp = ctypes.c_void_p()
            vn = ctypes.c_size_t()
            _check(_lib.pancake_locator_hint_at(out, i, ctypes.byref(kp), ctypes.byref(kn), ctypes.byref(vp), ctypes.byref(vn)))
            hints[_read_view(kp, kn)] = _read_view(vp, vn)
        # The host:port split is the core grammar's verdict, computed while the
        # handle is alive: OK carries the split, INVALID_ARGUMENT means the
        # designator is not host:port (an iroh node id, say), which is a fact,
        # not a fault.
        hp = ctypes.c_void_p()
        hn = ctypes.c_size_t()
        hport = ctypes.c_uint16()
        rc = _lib.pancake_locator_host_port(out, ctypes.byref(hp), ctypes.byref(hn), ctypes.byref(hport))
        host: "Optional[str]" = None
        port: "Optional[int]" = None
        if rc == _OK:
            host = _read_view(hp, hn)
            port = hport.value
        elif rc != _ERR_INVALID_ARGUMENT:
            _check(rc)
        return Locator(
            field(_lib.pancake_locator_transport),
            field(_lib.pancake_locator_designator),
            field(_lib.pancake_locator_swissnum),
            hints,
            host,
            port,
        )
    finally:
        _lib.pancake_locator_release(out)


def format_peer_uri(transport: str, designator: str, hints: "Optional[dict[str, str]]" = None) -> str:
    """Format a peer locator as an ``ocapn://<designator>.<transport>[?hints]``
    URI through the core grammar."""
    items = list((hints or {}).items())
    t = transport.encode("utf-8")
    d = designator.encode("utf-8")
    keys = [k.encode("utf-8") for k, _ in items]
    vals = [v.encode("utf-8") for _, v in items]
    n = len(items)
    if n:
        key_arr = (ctypes.c_char_p * n)(*keys)
        val_arr = (ctypes.c_char_p * n)(*vals)
        key_lens = (ctypes.c_size_t * n)(*[len(k) for k in keys])
        val_lens = (ctypes.c_size_t * n)(*[len(v) for v in vals])
        key_ptr = ctypes.cast(key_arr, ctypes.c_void_p)
        val_ptr = ctypes.cast(val_arr, ctypes.c_void_p)
        key_len_ptr = ctypes.cast(key_lens, ctypes.c_void_p)
        val_len_ptr = ctypes.cast(val_lens, ctypes.c_void_p)
    else:
        key_ptr = val_ptr = key_len_ptr = val_len_ptr = None

    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t()
        rc = _lib.pancake_uri_format_peer(
            t, len(t), d, len(d),
            key_ptr, key_len_ptr, val_ptr, val_len_ptr, n,
            buf, cap, ctypes.byref(out_len),
        )
        need = out_len.value
        if rc == _OK:
            return buf.raw[:need].decode("utf-8")
        if rc == _ERR_BUFFER_TOO_SMALL and need > cap:
            cap = need
            continue
        _check(rc)



def socket_addr_designator(host_or_peer, port: int | None = None) -> str:
    """Render host:port as a tcp designator. IPv6 hosts need brackets so the
    core last-colon split stays unambiguous. Accepts ``(host, port)`` from a
    socket peername/getsockname, or ``(host, port)`` as two arguments."""
    if port is None:
        host, port = host_or_peer[0], int(host_or_peer[1])
    else:
        host = host_or_peer
    if ":" in host and not (host.startswith("[") and host.endswith("]")):
        return f"[{host}]:{port}"
    return f"{host}:{port}"


def host_port_from_direct_hint(hint: str) -> "tuple[str, int]":
    """Split a ``direct-addresses`` hint into host and port (first address when
    comma-separated)."""
    first = hint.split(",", 1)[0].strip()
    if not first:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "keyed-tcp requires a non-empty direct-addresses hint")
    try:
        return designator_host_port(first)
    except PancakeError:
        raise PancakeError(_ERR_INVALID_ARGUMENT, f"direct-addresses hint is not host:port: {first}")


def designator_host_port(designator: str) -> "tuple[str, int]":
    """Split a bare designator as ``host:port`` through the core grammar
    (``pancake_designator_host_port``). Prefer this over minting a peer URI
    just to call :func:`parse_locator`."""
    data = designator.encode()
    buf = ctypes.create_string_buffer(data, len(data) or 1)
    hp = ctypes.c_void_p()
    hn = ctypes.c_size_t()
    hport = ctypes.c_uint16()
    _check(_lib.pancake_designator_host_port(
        ctypes.cast(buf, ctypes.c_void_p), len(data),
        ctypes.byref(hp), ctypes.byref(hn), ctypes.byref(hport),
    ))
    host = (ctypes.string_at(hp, hn.value).decode("utf-8") if hp.value and hn.value else "")
    return host, int(hport.value)

def tcp_locator(host: str, port: int) -> str:
    """Build a ``tcp`` locator from a literal host and port:
    ``ocapn://host:port.tcp``, rendered through the core grammar. The convenience
    for the common case, a caller holding a host and port passes
    ``connect(tcp_locator(host, port))`` instead of hand-formatting the URI.
    ``host:port`` is not a dial of its own; it is a locator like any other."""
    return format_peer_uri(_abi.TRANSPORT_TCP, socket_addr_designator(host, port))


def keyed_tcp_locator(designator: str, host: str, port: int) -> str:
    """Build a ``keyed-tcp`` locator: the designator is the listener's Ed25519
    public key in canonical hex, and ``host``/``port`` ride the
    ``direct-addresses`` hint (ADR-0075). A partner dials with :func:`connect`
    and re-dials after a restart with only the hint updated."""
    return format_peer_uri(
        _abi.TRANSPORT_KEYED_TCP,
        designator,
        {_abi.HINT_DIRECT_ADDRESSES: socket_addr_designator(host, port)},
    )
