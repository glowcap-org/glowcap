"""Loading and pre-call compatibility check for the separately built FFI archives."""

from __future__ import annotations

import ctypes
from collections.abc import Callable, Mapping
from typing import Any

from ._lib_resolve import _lib_path


def require_archive_fingerprint(resolve: Callable[[], Any], stem: str, expected: int) -> None:
    """Resolve and compare one archive fingerprint before ordinary use."""
    try:
        read = resolve()
    except AttributeError as error:
        raise RuntimeError(
            f"{stem}: missing archive fingerprint; rebuild the FFI libraries from this checkout"
        ) from error
    read.argtypes = []
    read.restype = ctypes.c_uint64
    actual = int(read())
    if actual != expected:
        raise RuntimeError(
            f"{stem}: callable surface does not match this binding "
            f"(expected {expected:016x}, got {actual:016x}); rebuild the FFI libraries"
        )


class _Lib:
    """A bound handle to one archive: the package reads ``_lib.glowcap_*``
    without holding a raw ``CDLL``. Keeps the loaded ``CDLL`` alive so it is
    never collected while a bound function is still callable."""

    def __init__(self, *handles: ctypes.CDLL) -> None:
        self._handles = handles


def _bind(facade: _Lib, lib: ctypes.CDLL, sigs: Mapping[str, tuple[Any, Any]]) -> None:
    """Attach each signature in ``sigs`` to ``facade`` as a bound ctypes
    function read off ``lib``."""
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
        setattr(facade, name, fn)


def load_archive(
    stem: str,
    fingerprint_symbol: Callable[[ctypes.CDLL], Any],
    fingerprint: int,
    signatures: Mapping[str, tuple[Any, Any]],
) -> Any:
    """Open one archive, hold its fingerprint to ``fingerprint``, and bind
    ``signatures`` on a handle that keeps the library alive. ``stem`` is the
    library stem (``glowcap_net_transport_tcp``), which also names the archive
    in a mismatch (``tcp``). ``fingerprint_symbol`` reads the archive's
    ``glowcap_<name>_archive_fingerprint`` export off the loaded library, as
    code rather than a string so the runtime-proof scan sees the call site. An
    absent library raises ``OSError`` from the load, which an optional
    archive's caller turns into its own build hint."""
    lib = ctypes.CDLL(str(_lib_path(stem)))
    label = stem.removeprefix("glowcap_").removeprefix("net_transport_")
    require_archive_fingerprint(lambda: fingerprint_symbol(lib), label, fingerprint)
    facade = _Lib(lib)
    _bind(facade, lib, signatures)
    return facade
