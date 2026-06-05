"""Python (ctypes) dogfood of the Zig libpancake C ABI.

The Python sibling of ``bindings/rust``'s ``rust_consumes_zig_peer_c_abi``:
load the shared library, create a peer, feed a borrowed ``op:abort`` frame,
and assert the surfaced event is an Abort. This exercises the slice of the
binding that consumes the Zig C ABI as it exists today; the richer
netlayer/handshake surface under ``pancake/`` is pending the C ABI's growth
(see ../README.md).
"""

from __future__ import annotations

import ctypes
import pathlib
import sys

PANCAKE_OK = 0
PANCAKE_FRAME_SHAPE_BYTE = 0
PANCAKE_EVENT_ABORT = 7

LIB_PATH = pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "lib" / "libpancake.so"


class PancakeFrame(ctypes.Structure):
    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
        ("shape", ctypes.c_uint32),
    ]


class PancakeManagedFrame(ctypes.Structure):
    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
        ("shape", ctypes.c_uint32),
        ("release", ctypes.c_void_p),
        ("private_data", ctypes.c_void_p),
    ]


class PancakeEvent(ctypes.Structure):
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("frame", PancakeManagedFrame),
    ]


def main() -> int:
    lib = ctypes.CDLL(str(LIB_PATH))
    lib.pancake_peer_new.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.pancake_peer_new.restype = ctypes.c_int32
    lib.pancake_peer_feed_borrowed.argtypes = [ctypes.c_void_p, ctypes.POINTER(PancakeFrame)]
    lib.pancake_peer_feed_borrowed.restype = ctypes.c_int32
    lib.pancake_peer_poll_event.argtypes = [ctypes.c_void_p, ctypes.POINTER(PancakeEvent)]
    lib.pancake_peer_poll_event.restype = ctypes.c_int32
    lib.pancake_event_release.argtypes = [ctypes.POINTER(PancakeEvent)]
    lib.pancake_peer_release.argtypes = [ctypes.c_void_p]

    peer = ctypes.c_void_p()
    if lib.pancake_peer_new(ctypes.byref(peer)) != PANCAKE_OK or not peer:
        print("python zig-smoke FAILED: peer_new", file=sys.stderr)
        return 1

    payload = b'<8\'op:abort3"bye>'
    buf = ctypes.create_string_buffer(payload, len(payload))
    frame = PancakeFrame(
        bytes=ctypes.cast(buf, ctypes.c_void_p),
        len=len(payload),
        shape=PANCAKE_FRAME_SHAPE_BYTE,
    )
    if lib.pancake_peer_feed_borrowed(peer, ctypes.byref(frame)) != PANCAKE_OK:
        print("python zig-smoke FAILED: feed_borrowed(op:abort)", file=sys.stderr)
        return 1

    event = PancakeEvent()
    if lib.pancake_peer_poll_event(peer, ctypes.byref(event)) != PANCAKE_OK:
        print("python zig-smoke FAILED: poll_event", file=sys.stderr)
        return 1
    if event.kind != PANCAKE_EVENT_ABORT:
        print(f"python zig-smoke FAILED: event kind {event.kind} != ABORT", file=sys.stderr)
        return 1

    lib.pancake_event_release(ctypes.byref(event))
    lib.pancake_peer_release(peer)
    print("python zig-smoke OK: consumed Zig libpancake C ABI (op:abort)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
