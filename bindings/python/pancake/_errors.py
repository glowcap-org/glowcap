"""Internal: the typed error hierarchy and version/diagnostics helpers.

The base :class:`PancakeException`, the C-ABI failure :class:`PancakeError` with
its typed :class:`AbortDetail`, the actor-layer :class:`VowBroken` /
:class:`FetchFailed`, and the ``_check`` guard every wrapper routes a return
code through. Re-exported from the :mod:`pancake` package; import from there.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import ctypes

from . import _constants as _abi
from ._ffi_driver import _host
from ._ffi_ocapn import _lib, _read_last_error

_OK = _abi.OK

def abi_version() -> tuple[int, int, int]:
    """The linked library's ``(major, minor, patch)`` ABI version."""
    major = ctypes.c_uint32()
    minor = ctypes.c_uint32()
    patch = ctypes.c_uint32()
    _lib.pancake_abi_version(ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch))
    return (major.value, minor.value, patch.value)


def last_error() -> Optional[str]:
    """The calling thread's last error message, or ``None`` when there is none."""
    return _read_last_error(_lib.pancake_last_error)


def _abort_domain_label(domain: int) -> str:
    """Map ``PancakeLastAbort.domain`` to the host label the waist defines."""
    if domain == _abi.ABORT_DOMAIN_CODEC:
        return "codec"
    if domain == _abi.ABORT_DOMAIN_SESSION:
        return "session"
    return "foreign"


@dataclass(frozen=True)
class AbortDetail:
    """The typed cause of a peer's most recent local dispatch failure, the
    counterpart of the C ABI's ``PancakeLastAbort``. ``domain`` names the layer
    that refused (``"codec"``, ``"session"``, or ``"foreign"``), ``kind`` the
    projected ``op:abort`` kind when one exists, ``message`` the static
    diagnostic, and ``error_name`` the originating error."""

    domain: str
    kind: Optional[str]
    message: str
    error_name: str


class PancakeException(Exception):
    """The base of every exception this library raises.

    Catch ``pancake.PancakeException`` to handle anything pancake raised,
    whatever the category: a C ABI failure (:class:`PancakeError`), an awaited
    vow that settled broken (:class:`VowBroken`), or a ``fetch`` that answered
    with something other than a capability (:class:`FetchFailed`).
    """


class PancakeError(PancakeException):
    """A failed C ABI call, carrying the negative ``PANCAKE_ERR_*`` code.

    When a per-thread error message is available it is captured at raise time
    (the message is thread-local and may be overwritten by a later call) and
    shown by ``str(err)``. When the failure was a refused inbound frame,
    ``abort`` carries the typed :class:`AbortDetail` naming which layer refused
    and why.
    """

    def __init__(self, code: int, message: Optional[str] = None, abort: Optional[AbortDetail] = None):
        if message:
            super().__init__(f"pancake error {code}: {message}")
        else:
            super().__init__(f"pancake error {code}")
        self.code = code
        self.message = message
        self.abort = abort


def _check(code: int) -> None:
    if code != _OK:
        # Capture the thread-local message now, before any later call clobbers it.
        raise PancakeError(code, last_error())


def _host_last_error() -> Optional[str]:
    """The calling thread's last ``pancake_host_*`` error message, or ``None``
    when there is none. The driver archive keeps its own thread-local slot, so
    a host call's diagnostic is read here and never from the core family's
    :func:`last_error`."""
    return _read_last_error(_host.pancake_host_last_error)


def _host_error(code: int) -> PancakeError:
    """A failed ``pancake_host_*`` call as a typed error, its diagnostic read
    from the driver archive's own slot."""
    return PancakeError(code, _host_last_error() or f"host call failed (code {code})")


def _check_host(code: int) -> None:
    """Like :func:`_check`, for ``pancake_host_*`` calls."""
    if code != _OK:
        raise _host_error(code)


class VowBroken(PancakeError):
    """Raised when an awaited vow settles broken; ``reason`` is the partner's
    break reason.

    A :class:`PancakeError` whose ``code`` is ``ERR_BROKEN``, the same contract
    as the other bindings' break errors, so ``except PancakeError`` with a
    ``code`` check classifies a break exactly like a C ABI failure."""

    def __init__(self, reason: str):
        super().__init__(_abi.ERR_BROKEN, reason)
        self.reason = reason


class FetchFailed(PancakeError):
    """Raised when a ``fetch`` settles, but not with a capability.

    This is the application-level outcome — the partner answered, and the
    answer was not a reference — distinct from a marshalling failure or a
    broken promise. ``name`` is the swiss-number the fetch asked for; ``code``
    is ``ERR_BROKEN``, matching the other bindings."""

    def __init__(self, name: str):
        super().__init__(_abi.ERR_BROKEN, f'fetch("{name}") did not resolve to a capability')
        self.name = name
