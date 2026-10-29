"""Internal: the typed error hierarchy and version/diagnostics helpers.

The public base :class:`GlowcapError` with its typed :class:`AbortDetail`, the
actor-layer :class:`VowBroken` / :class:`FetchFailed`, and the ``_check`` guard
every wrapper routes a return code through. Re-exported from the
:mod:`glowcap` package. Import from there.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Optional

import ctypes

from . import _constants as _abi
from ._ffi_host import _host
from ._ffi_ocapn import _lib, _read_last_error

if TYPE_CHECKING:
    from ._carrier_failure import CarrierFailure

_OK = _abi.OK


def abi_version() -> tuple[int, int, int]:
    """The linked library's ``(major, minor, patch)`` ABI version."""
    major = ctypes.c_uint32()
    minor = ctypes.c_uint32()
    patch = ctypes.c_uint32()
    _lib.glowcap_abi_version(
        ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch)
    )
    return (major.value, minor.value, patch.value)


def last_error() -> Optional[str]:
    """The calling thread's last error message, or ``None`` when there is none."""
    return _read_last_error(_lib.glowcap_last_error)


def _abort_domain_label(domain: int) -> str:
    """Map ``GlowcapLastAbort.domain`` to the host label the waist defines."""
    if domain == _abi.ABORT_DOMAIN_CODEC:
        return "codec"
    if domain == _abi.ABORT_DOMAIN_SESSION:
        return "session"
    if domain == _abi.ABORT_DOMAIN_FOREIGN:
        return "foreign"
    raise GlowcapError(
        _abi.ERR_INTERNAL,
        f"glowcap ABI returned unknown abort domain {domain}",
    )


@dataclass(frozen=True)
class AbortDetail:
    """The typed cause of a peer's most recent local dispatch failure, the
    counterpart of the C ABI's ``GlowcapLastAbort``. ``domain`` names the layer
    that refused (``"codec"``, ``"session"``, or ``"foreign"``), ``kind`` the
    projected ``op:abort`` kind when one exists, ``message`` the static
    diagnostic, ``error_name`` the originating error, and
    ``abort_delivery_error_name`` a failure publishing the terminal abort,
    and ``secondary_error_name`` / ``secondary_error_count`` the bounded
    cleanup or consequence failures that followed the originating error."""

    domain: str
    kind: Optional[str]
    message: str
    error_name: str
    abort_delivery_error_name: Optional[str]
    secondary_error_name: Optional[str]
    secondary_error_count: int


class GlowcapError(Exception):
    """Base of every exception glowcap raises, carrying a negative
    ``GLOWCAP_ERR_*`` code.

    For a failed FFI call, the per-thread error message is captured at raise
    time (the message is thread-local and may be overwritten by a later call)
    and shown by ``str(err)``. When the failure was a refused inbound frame,
    ``abort`` carries the typed :class:`AbortDetail` naming which layer refused
    and why.
    """

    def __init__(
        self,
        code: int,
        message: Optional[str] = None,
        abort: Optional[AbortDetail] = None,
    ):
        if message:
            super().__init__(f"glowcap error {code}: {message}")
        else:
            super().__init__(f"glowcap error {code}")
        self.code = code
        self.message = message
        self.abort = abort
        self.carrier_failure: Optional[CarrierFailure] = None
        self.secondary: tuple[BaseException, ...] = ()
        self.secondary_count = 0


_FAILURE_CHAIN_CAP = _abi.BINDING_SECONDARY_FAILURE_CAP


def _retain_cleanup_failure(
    primary: BaseException, cleanup: BaseException
) -> BaseException:
    """Retain a later FFI cleanup failure without replacing its cause."""
    try:
        total = getattr(primary, "secondary_count", 0)
        retained = getattr(primary, "secondary", ())
        if type(total) is not int or total < 0:
            total = 0
        if not isinstance(retained, tuple):
            retained = ()
        setattr(primary, "secondary_count", min((1 << 32) - 1, total + 1))
        if len(retained) < _FAILURE_CHAIN_CAP:
            setattr(primary, "secondary", retained + (cleanup,))
    except BaseException:
        # Slot-only application exceptions may refuse package metadata. Python's
        # standard exception note remains a truthful, if less structured,
        # fallback while the original object stays authoritative.
        try:
            BaseException.add_note(
                primary, f"additional glowcap cleanup failure: {cleanup}"
            )
        except BaseException:
            pass  # attachment cannot replace the authoritative primary
    return primary


def _retain_terminal_failure(
    retained: list[BaseException], total: int, error: BaseException
) -> int:
    """Retain bounded exact failures and return the saturated observation count.

    Re-projecting a retained exception object is idempotent. Overflow objects
    are not retained, so their repeated observations can count more than once.
    Operation labels cannot deduplicate distinct failures of the same operation.
    """
    if any(previous is error for previous in retained):
        return total
    total = min((1 << 32) - 1, total + 1)
    if len(retained) < _FAILURE_CHAIN_CAP:
        retained.append(error)
    return total


def _check(code: int) -> None:
    if code != _OK:
        # Capture the thread-local message now, before any later call clobbers it.
        raise GlowcapError(code, last_error())


def _host_last_error() -> Optional[str]:
    """The calling thread's last ``glowcap_host_*`` error message, or ``None``
    when there is none. The driver archive keeps its own thread-local slot, so
    a host call's diagnostic is read here and never from the core family's
    :func:`last_error`."""
    return _read_last_error(_host.glowcap_host_last_error)


def _host_error(code: int) -> GlowcapError:
    """A failed ``glowcap_host_*`` call as a typed error, its diagnostic read
    from the driver archive's own slot."""
    return GlowcapError(code, _host_last_error() or f"host call failed (code {code})")


def _check_host(code: int) -> None:
    """Like :func:`_check`, for ``glowcap_host_*`` calls."""
    if code != _OK:
        raise _host_error(code)


class VowBroken(GlowcapError):
    """Raised when an awaited vow settles broken. ``reason`` is the partner's
    break reason.

    A :class:`GlowcapError` whose ``code`` is ``ERR_BROKEN``, the same contract
    as the other bindings' break errors, so ``except GlowcapError`` with a
    ``code`` check classifies a break exactly like a C ABI failure."""

    def __init__(self, reason: str):
        super().__init__(_abi.ERR_BROKEN, reason)
        self.reason = reason


def _vow_failure(code: int, reason: str) -> GlowcapError:
    """Project a core-issued vow failure code into the typed hierarchy."""
    return VowBroken(reason) if code == _abi.ERR_BROKEN else GlowcapError(code, reason)


class FetchFailed(GlowcapError):
    """Raised when a ``fetch`` settles, but not with a capability.

    This is the application-level outcome, the partner answered, and the
    answer was not a reference, distinct from a marshalling failure or a
    broken promise. ``name`` is the swiss-number the fetch asked for. ``code``
    is ``ERR_BROKEN``, matching the other bindings."""

    def __init__(self, name: str):
        super().__init__(
            _abi.ERR_BROKEN, f'fetch("{name}") did not resolve to a capability'
        )
        self.name = name
