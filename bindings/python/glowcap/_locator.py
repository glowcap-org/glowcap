"""Internal: the OCapN locator URI grammar.

The ``ocapn://<designator>.<transport>[?hints]`` grammar is core OCapN
vocabulary, defined once in ``libglowcap_ocapn``'s ``glowcap_uri_*`` /
``glowcap_locator_*`` surface, so no binding hand-rolls a percent codec.
:func:`parse_locator` copies every borrowed view into Python strings before
releasing the handle. :func:`format_peer_uri` renders through the same grammar.
:func:`encode_peer_locator` builds the verbatim exporter location record a
gifter embeds in a give. Re-exported from the
:mod:`glowcap` package. Import from there.
"""

from __future__ import annotations

from typing import NamedTuple, Optional, Union

import ctypes

from . import _constants as _abi
from ._abi_value import _captp_version_id
from ._errors import _check, GlowcapError
from ._ffi_ocapn import _lib, _LocatorHintView, _LocatorView

_OK = _abi.OK
_ERR_BUFFER_TOO_SMALL = _abi.ERR_BUFFER_TOO_SMALL

def encode_peer_locator(locator: "Locator") -> bytes:
    """Encode a complete typed locator as the canonical signed handoff record."""
    out_loc = ctypes.c_void_p()
    out_len = ctypes.c_size_t()
    with _OwnedLocator.create(locator) as owned:
        _check(_lib.glowcap_locator_record_encode(
            owned.borrow_view(), ctypes.byref(out_loc), ctypes.byref(out_len)
        ))
    try:
        return ctypes.string_at(out_loc, out_len.value)
    finally:
        _lib.glowcap_locator_record_bytes_release(out_loc, out_len.value)


HintValue = Union[str, bytes, bool, int]


class Locator(NamedTuple):
    """A parsed OCapN peer locator.

    Transport modules own locator construction and realization. Apps that need
    a bare designator split use :func:`designator_host_port`.
    """

    transport: str
    designator: str
    hints: "dict[str, HintValue]"
    hint_wire_form: str = "map"


class SturdyRef(NamedTuple):
    """A peer locator paired with its opaque authority-bearing swissnum."""

    locator: Locator
    swissnum: bytes


class _OwnedLocator:
    """One OCapN-owned locator handle and its borrowed view."""

    def __init__(self, handle: ctypes.c_void_p) -> None:
        if not handle:
            raise GlowcapError(_abi.ERR_INVALID_ARGUMENT, "OCapN returned a null locator handle")
        self.handle = handle

    @classmethod
    def create(cls, locator: Locator) -> "_OwnedLocator":
        wire_form = {
            "map": _abi.HINTS_MAP,
            "boolean-false": _abi.HINTS_BOOLEAN_FALSE,
        }.get(locator.hint_wire_form)
        if wire_form is None:
            raise ValueError("unknown locator hint wire form")
        transport = locator.transport.encode("utf-8")
        designator = locator.designator.encode("utf-8")
        raw = ctypes.c_void_p()
        _check(_lib.glowcap_locator_new(
            transport, len(transport), designator, len(designator), wire_form,
            ctypes.byref(raw),
        ))
        owned = cls(raw)
        try:
            for name, value in locator.hints.items():
                name_bytes = name.encode("utf-8")
                prefix = (owned.handle, name_bytes, len(name_bytes))
                if isinstance(value, str):
                    data = value.encode("utf-8")
                    rc = _lib.glowcap_locator_add_string(*prefix, data, len(data))
                elif isinstance(value, bytes):
                    rc = _lib.glowcap_locator_add_bytes(*prefix, value, len(value))
                elif isinstance(value, bool):
                    rc = _lib.glowcap_locator_add_boolean(*prefix, int(value))
                elif isinstance(value, int):
                    if value < -(1 << 63) or value >= (1 << 63):
                        raise OverflowError("locator integer hint does not fit int64")
                    rc = _lib.glowcap_locator_add_integer(*prefix, value)
                else:
                    raise TypeError(f"unsupported locator hint value for {name!r}")
                _check(rc)
            return owned
        except BaseException:
            owned.release()
            raise

    @classmethod
    def adopt(cls, handle: ctypes.c_void_p) -> "_OwnedLocator":
        return cls(handle)

    @classmethod
    def clone_view(cls, view: ctypes.c_void_p) -> "_OwnedLocator":
        raw = ctypes.c_void_p()
        _check(_lib.glowcap_locator_clone(
            ctypes.cast(view, ctypes.POINTER(_LocatorView)), ctypes.byref(raw)
        ))
        return cls(raw)

    def borrow_view(self) -> "ctypes._Pointer[_LocatorView]":
        raw = ctypes.c_void_p()
        _check(_lib.glowcap_locator_borrow_view(self.handle, ctypes.byref(raw)))
        return ctypes.cast(raw, ctypes.POINTER(_LocatorView))

    def release(self) -> None:
        if self.handle:
            _lib.glowcap_locator_release(self.handle)
            self.handle = ctypes.c_void_p()

    def __enter__(self) -> "_OwnedLocator":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.release()

    def value(self) -> Locator:
        def field(accessor) -> str:
            ptr = ctypes.c_void_p()
            length = ctypes.c_size_t()
            _check(accessor(self.handle, ctypes.byref(ptr), ctypes.byref(length)))
            return _read_view(ptr, length)

        count = ctypes.c_size_t()
        _check(_lib.glowcap_locator_hint_count(self.handle, ctypes.byref(count)))
        hints: "dict[str, HintValue]" = {}
        for index in range(count.value):
            hint = _LocatorHintView()
            _check(_lib.glowcap_locator_hint_at(self.handle, index, ctypes.byref(hint)))
            name = ctypes.string_at(hint.name, hint.name_len).decode("utf-8")
            if hint.kind == _abi.HINT_STRING:
                value: HintValue = ctypes.string_at(hint.bytes, hint.bytes_len).decode("utf-8")
            elif hint.kind == _abi.HINT_BYTES:
                value = ctypes.string_at(hint.bytes, hint.bytes_len)
            elif hint.kind == _abi.HINT_BOOLEAN and hint.boolean_value <= 1:
                value = bool(hint.boolean_value)
            elif hint.kind == _abi.HINT_INTEGER:
                value = int(hint.integer_value)
            else:
                raise GlowcapError(_abi.ERR_INVALID_ARGUMENT, "OCapN returned an invalid locator hint")
            hints[name] = value
        raw_wire_form = ctypes.c_uint32()
        _check(_lib.glowcap_locator_hint_wire_form(self.handle, ctypes.byref(raw_wire_form)))
        wire_form = {
            _abi.HINTS_MAP: "map",
            _abi.HINTS_BOOLEAN_FALSE: "boolean-false",
        }.get(raw_wire_form.value)
        if wire_form is None:
            raise GlowcapError(_abi.ERR_INVALID_ARGUMENT, "OCapN returned an invalid hint wire form")
        return Locator(
            field(_lib.glowcap_locator_transport),
            field(_lib.glowcap_locator_designator),
            hints,
            wire_form,
        )


class _OwnedSturdyRef:
    """One OCapN-owned sturdyref handle."""

    def __init__(self, handle: ctypes.c_void_p) -> None:
        if not handle:
            raise GlowcapError(_abi.ERR_INVALID_ARGUMENT, "OCapN returned a null sturdyref handle")
        self.handle = handle

    def release(self) -> None:
        if self.handle:
            _lib.glowcap_sturdyref_release(self.handle)
            self.handle = ctypes.c_void_p()

    def __enter__(self) -> "_OwnedSturdyRef":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.release()

    def value(self) -> SturdyRef:
        view = ctypes.c_void_p()
        _check(_lib.glowcap_sturdyref_borrow_locator(self.handle, ctypes.byref(view)))
        with _OwnedLocator.clone_view(view) as locator:
            locator_value = locator.value()

        ptr = ctypes.c_void_p()
        length = ctypes.c_size_t()
        _check(_lib.glowcap_sturdyref_swissnum(
            self.handle, ctypes.byref(ptr), ctypes.byref(length)
        ))
        swissnum = b"" if length.value == 0 else ctypes.string_at(ptr, length.value)
        return SturdyRef(locator_value, swissnum)


def _read_view(ptr: ctypes.c_void_p, length: ctypes.c_size_t) -> str:
    # Decode a borrowed (pointer, length) view a locator accessor filled. A zero
    # length (or NULL pointer) is the empty string.
    n = length.value
    if n == 0 or not ptr.value:
        return ""
    return ctypes.string_at(ptr.value, n).decode("utf-8")


def parse_locator(uri: str) -> Locator:
    """Parse an ``ocapn://`` peer URI through the core grammar."""
    raw = uri.encode("utf-8")
    out = ctypes.c_void_p()
    _check(_lib.glowcap_uri_parse_peer(raw, len(raw), ctypes.byref(out)))
    with _OwnedLocator.adopt(out) as owned:
        return owned.value()


def parse_sturdyref(uri: str, captp_version: str) -> SturdyRef:
    """Parse an ``ocapn://.../s/<swiss>`` sturdyref under its CapTP profile
    without losing authority."""
    raw = uri.encode("utf-8")
    out = ctypes.c_void_p()
    _check(_lib.glowcap_uri_parse_sturdyref(
        _captp_version_id(captp_version), raw, len(raw), ctypes.byref(out)
    ))
    with _OwnedSturdyRef(out) as owned:
        return owned.value()


def format_peer_uri(transport: str, designator: str, hints: "Optional[dict[str, str]]" = None) -> str:
    """Format a peer locator as an ``ocapn://<designator>.<transport>[?hints]``
    URI through the core grammar."""
    return _format_uri(transport, designator, None, hints)


def format_sturdyref(locator: Locator, swissnum: bytes, captp_version: str) -> str:
    """Add opaque swiss authority to a typed locator and render a sturdyref
    under the selected CapTP profile."""
    hints: dict[str, str] = {}
    for name, value in locator.hints.items():
        if not isinstance(value, str):
            raise TypeError(f"locator hint {name!r} has no lossless URI spelling")
        hints[name] = value
    return _format_uri(locator.transport, locator.designator, swissnum, hints, captp_version)


def _format_uri(
    transport: str,
    designator: str,
    swissnum: "Optional[bytes]",
    hints: "Optional[dict[str, str]]" = None,
    captp_version: "Optional[str]" = None,
) -> str:
    items = list((hints or {}).items())
    t = transport.encode("utf-8")
    d = designator.encode("utf-8")
    keys = [k.encode("utf-8") for k, _ in items]
    vals = [v.encode("utf-8") for _, v in items]
    n = len(items)
    # Null pointers when there are no hints: the C side reads the four arrays
    # only when the count is non-zero.
    key_ptr: ctypes.c_void_p | None
    val_ptr: ctypes.c_void_p | None
    key_len_ptr: ctypes.c_void_p | None
    val_len_ptr: ctypes.c_void_p | None
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

    def call_format(buf, cap: int, out_len) -> int:
        if swissnum is None:
            return _lib.glowcap_uri_format_peer(
                t, len(t), d, len(d),
                key_ptr, key_len_ptr, val_ptr, val_len_ptr, n,
                buf, cap, ctypes.byref(out_len),
            )
        assert captp_version is not None
        return _lib.glowcap_uri_format_sturdyref(
            _captp_version_id(captp_version),
            t, len(t), d, len(d), swissnum, len(swissnum),
            key_ptr, key_len_ptr, val_ptr, val_len_ptr, n,
            buf, cap, ctypes.byref(out_len),
        )

    out_len = ctypes.c_size_t()
    rc = call_format(None, 0, out_len)
    if rc != _ERR_BUFFER_TOO_SMALL:
        _check(rc)
        if out_len.value == 0:
            return ""
    cap = out_len.value
    while True:
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t()
        rc = call_format(buf, cap, out_len)
        need = out_len.value
        if rc == _OK:
            return buf.raw[:need].decode("utf-8")
        if rc == _ERR_BUFFER_TOO_SMALL and need > cap:
            cap = need
            continue
        _check(rc)


def format_locator_uri(locator: Locator) -> str:
    """Render a typed peer locator when every hint has a URI string spelling."""
    hints: dict[str, str] = {}
    for name, value in locator.hints.items():
        if not isinstance(value, str):
            raise TypeError(f"locator hint {name!r} has no lossless URI spelling")
        hints[name] = value
    return format_peer_uri(locator.transport, locator.designator, hints)



def designator_host_port(designator: str) -> "tuple[str, int]":
    """Split a bare designator as ``host:port`` through the core grammar
    (``glowcap_designator_host_port``). Prefer this over minting a peer URI
    just to call :func:`parse_locator`."""
    data = designator.encode()
    buf = ctypes.create_string_buffer(data, len(data) or 1)
    hp = ctypes.c_void_p()
    hn = ctypes.c_size_t()
    hport = ctypes.c_uint16()
    _check(_lib.glowcap_designator_host_port(
        ctypes.cast(buf, ctypes.c_void_p), len(data),
        ctypes.byref(hp), ctypes.byref(hn), ctypes.byref(hport),
    ))
    host = (ctypes.string_at(hp, hn.value).decode("utf-8") if hp.value and hn.value else "")
    return host, int(hport.value)
