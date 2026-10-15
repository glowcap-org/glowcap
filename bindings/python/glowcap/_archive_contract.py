"""Pre-call compatibility check for separately loaded FFI archives."""

from __future__ import annotations

import ctypes
from collections.abc import Callable
from typing import Any


def require_archive_fingerprint(
    resolve: Callable[[], Any], stem: str, expected: int
) -> None:
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
