"""Shared C-ABI vocabulary for the three pancake cdylibs.

This mirrors ``crates/ffi/pancake-ffi-abi/include/pancake_abi.h`` — the
struct + error-code surface every libpancake cdylib shares.

Three cdylibs make up the family (per ADR-0050 / ADR-0051):

* ``PANCAKE_LIB`` → ``libpancake_ffi_runtime`` — the protocol core.
* ``PANCAKE_NET_TCP_LIB`` → ``libpancake_ffi_net_tcp`` — cleartext + TLS TCP.
* ``PANCAKE_NET_IROH_LIB`` → ``libpancake_ffi_net_iroh`` — QUIC-over-iroh.

The ``pancake-ffi-abi`` panic seam (with its per-thread last-error slot) is
**statically linked into each cdylib**, so every library has its own
``pancake_last_error`` symbol. We therefore bind ``pancake_last_error`` /
``pancake_clear_last_error`` once per loaded library — a net-tcp failure
stashes its diagnostic in the net-tcp slot, not the runtime slot.

Layout assumptions: LP64, 64-bit pointers. Tested pancake architectures are
x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin. Windows / ILP32
would need the struct paddings revisited.
"""

from __future__ import annotations

import ctypes
import os
import sys

# ─── C ABI return codes (pancake_abi.h) ──────────────────────────────────

PANCAKE_OK = 0
PANCAKE_ERR_NULL_POINTER = -1
PANCAKE_ERR_INVALID_HANDLE = -2
PANCAKE_ERR_PEER_CLOSED = -3
PANCAKE_ERR_SESSION = -4
PANCAKE_ERR_CODEC = -5
PANCAKE_ERR_INTERNAL = -6
PANCAKE_ERR_INVALID_UTF8 = -7
PANCAKE_ERR_INVALID_CODEC = -8
PANCAKE_ERR_HANDSHAKE_INCOMPLETE = -9
PANCAKE_ERR_PANIC = -100

# Netlayer endpoint return codes.
PANCAKE_ENDPOINT_ERR_IO = -20
PANCAKE_ENDPOINT_ERR_MALFORMED = -21
PANCAKE_ENDPOINT_ERR_CLOSED = -22
PANCAKE_ENDPOINT_ERR_WOULD_BLOCK = -23


class PancakeFrame(ctypes.Structure):
    """Bare ``(bytes, len)`` wire-frame view for **lending** caller-owned
    bytes that the callee finishes with inside the call.

    Used only for the inbound feed (``pancake_peer_feed_inbound``): the
    host populates ``bytes`` / ``len`` and the runtime decodes + dispatches
    the frame synchronously before returning. The runtime never owns the
    bytes — there is no copy and nothing to free; the host retains
    ownership and may release / reuse its buffer once the call returns.

    Bytes the host must hold *past* a call (outbound frames the runtime
    produced, inbound frames a netlayer produced) travel as a
    :class:`PancakeManagedFrame` instead.
    """

    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
    ]


class PancakeManagedFrame(ctypes.Structure):
    """A wire frame whose backing memory carries its own release callback
    (the Arrow C Data Interface / DLPack pattern).

    The **single** shape every pancake cdylib uses to hand the host bytes
    it must hold past the producing call: outbound frames
    (``pancake_peer_take_outbound``) and netlayer read frames
    (``pancake_endpoint_*_read_frame``). It is self-describing — the
    embedded ``release`` callback + opaque ``private_data`` capture the
    producing cdylib's allocator — so the host frees it identically no
    matter which cdylib produced it, via the single
    ``pancake_managed_frame_release``. Never ``libc.free``.
    """


_ManagedFrameReleaseFn = ctypes.CFUNCTYPE(None, ctypes.POINTER(PancakeManagedFrame))

PancakeManagedFrame._fields_ = [
    ("bytes", ctypes.c_void_p),
    ("len", ctypes.c_size_t),
    ("release", _ManagedFrameReleaseFn),
    ("private_data", ctypes.c_void_p),
]


# Environment-variable names for the three cdylibs.
ENV_RUNTIME = "PANCAKE_LIB"
ENV_NET_TCP = "PANCAKE_NET_TCP_LIB"
ENV_NET_IROH = "PANCAKE_NET_IROH_LIB"


def _default_extension() -> str:
    if sys.platform == "darwin":
        return ".dylib"
    if sys.platform.startswith("win"):
        return ".dll"
    return ".so"


def load_library(env_var: str, crate_hint: str) -> ctypes.CDLL:
    """Load a pancake cdylib named by ``env_var``.

    Raises a clear, actionable error when the variable is unset — building
    a cdylib is ``cargo build -p <crate_hint> --release`` and the path is
    ``target/release/lib<...>``.
    """

    path = os.environ.get(env_var)
    if not path:
        raise RuntimeError(
            f"{env_var} environment variable not set; build the cdylib via "
            f"`cargo build -p {crate_hint} --release` and "
            f"`export {env_var}=/abs/path/to/lib{crate_hint.replace('-', '_')}"
            f"{_default_extension()}`"
        )
    if not os.path.exists(path):
        raise RuntimeError(f"{env_var}={path!r} does not exist on disk")
    return ctypes.CDLL(path)


def bind_last_error(lib: ctypes.CDLL):
    """Bind the per-library ``pancake_last_error`` / ``pancake_clear_last_error``.

    Returns ``(last_error, clear_last_error)`` callables. ``last_error``
    returns the current thread's stashed diagnostic as ``str`` (or ``None``).
    The returned pointer is only valid until the next ``pancake_*`` call that
    sets a new error, so we copy the bytes out immediately.
    """

    raw_last = lib.pancake_last_error
    raw_last.argtypes = []
    raw_last.restype = ctypes.c_char_p

    raw_clear = lib.pancake_clear_last_error
    raw_clear.argtypes = []
    raw_clear.restype = None

    def last_error():
        ptr = raw_last()
        if not ptr:
            return None
        return ptr.decode("utf-8", "replace")

    def clear_last_error():
        raw_clear()

    return last_error, clear_last_error
