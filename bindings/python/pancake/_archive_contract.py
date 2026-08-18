"""Pre-call compatibility check for separately loaded native archives."""

from __future__ import annotations

import ctypes


def require_archive_fingerprint(lib, stem: str, expected: int) -> None:
    symbol = f"pancake_{stem}_archive_fingerprint"
    try:
        read = getattr(lib, symbol)
    except AttributeError as error:
        raise RuntimeError(
            f"{stem}: missing archive fingerprint; rebuild the native libraries from this checkout"
        ) from error
    read.argtypes = []
    read.restype = ctypes.c_uint64
    actual = int(read())
    if actual != expected:
        raise RuntimeError(
            f"{stem}: callable surface does not match this binding "
            f"(expected {expected:016x}, got {actual:016x}); rebuild the native libraries"
        )
