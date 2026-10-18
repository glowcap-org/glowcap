#!/usr/bin/env python3
"""Hold a shared C ABI archive resident after its embedder closes it.

The archive pins itself when the loader maps it
(src/c_abi/shared/archive_pin.zig), so an embedder that closes every FFI
library at teardown never unmaps code a detached std.Io.Threaded worker is
still leaving. This loads the archive, closes it, and asks the loader whether
it is still mapped.
"""

import ctypes
import sys

RTLD_LAZY = 0x1
RTLD_NOLOAD = 0x10 if sys.platform == "darwin" else 0x4


def resident_after_close(path):
    loader = ctypes.CDLL(None)
    loader.dlopen.restype = ctypes.c_void_p
    loader.dlopen.argtypes = [ctypes.c_char_p, ctypes.c_int]
    loader.dlclose.argtypes = [ctypes.c_void_p]
    loader.dlclose(ctypes.CDLL(path)._handle)
    return loader.dlopen(path.encode(), RTLD_LAZY | RTLD_NOLOAD) is not None


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: archive_resident.py LIBRARY")
    path = sys.argv[1]
    try:
        resident = resident_after_close(path)
    except OSError as error:
        sys.exit(f"archive_resident.py: cannot load {path}: {error}")
    if not resident:
        sys.exit(f"archive_resident.py: {path} was unmapped by dlclose; its archive pin entry is missing")


if __name__ == "__main__":
    main()
