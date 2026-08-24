"""Settled CapTP session profile projection."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass

from .. import _constants as _abi
from .._abi_value import _captp_version_name, _codec_name
from .._errors import PancakeError, _check_host
from .._ffi_host import _host


@dataclass(frozen=True)
class SessionProfile:
    """The version, codec, and exact feature set settled for one session."""

    captp_version: str
    codec: str
    features: int


def read_session_profile(ptr: ctypes.c_void_p) -> SessionProfile:
    version = ctypes.c_uint32()
    codec = ctypes.c_uint32()
    features = ctypes.c_uint32()
    _check_host(
        _host.pancake_host_session_profile(
            ptr,
            ctypes.byref(version),
            ctypes.byref(codec),
            ctypes.byref(features),
        )
    )
    if features.value & ~_abi.FEATURE_FULL:
        raise PancakeError(
            _abi.ERR_INTERNAL,
            f"pancake ABI returned unknown session feature mask {features.value}",
        )
    try:
        return SessionProfile(
            captp_version=_captp_version_name(version.value, "session"),
            codec=_codec_name(codec.value, "session"),
            features=features.value,
        )
    except RuntimeError as error:
        raise PancakeError(_abi.ERR_INTERNAL, str(error)) from error


def read_session_transport_name(ptr: ctypes.c_void_p) -> str:
    out = ctypes.c_void_p()
    length = ctypes.c_size_t()
    _check_host(
        _host.pancake_host_session_transport_name(
            ptr,
            ctypes.byref(out),
            ctypes.byref(length),
        )
    )
    try:
        return ctypes.string_at(out, length.value).decode("utf-8")
    except UnicodeDecodeError as error:
        raise PancakeError(
            _abi.ERR_INTERNAL,
            f"pancake ABI returned non-UTF-8 session transport name: {error}",
        ) from error
