#!/usr/bin/env python3
"""Prove a Zig local cache can atomically publish response files.

This runs before the cache can be trusted. Python keeps the probe independent
of Zig compilation while ctypes exposes the Linux operations that shell cannot:
O_TMPFILE, linkat(AT_EMPTY_PATH), and renameat2(RENAME_NOREPLACE).
"""

import ctypes
import errno
import os
import sys


AT_FDCWD = -100
AT_SYMLINK_FOLLOW = 0x400
AT_EMPTY_PATH = 0x1000
RENAME_NOREPLACE = 1
O_TMPFILE_FALLBACK_ERRNOS = {errno.EISDIR, errno.ENOENT, errno.EOPNOTSUPP}
PROBE_BYTES = b"glowcap Zig cache filesystem probe\n"


def libc_call(name: str, argument_types: list[type], *args: object) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, name)
    function.argtypes = argument_types
    function.restype = ctypes.c_int
    while function(*args) != 0:
        error_number = ctypes.get_errno()
        if error_number == errno.EINTR:
            continue
        raise OSError(error_number, f"{name}: {os.strerror(error_number)}")
    return


def publish_unnamed(tmp_fd: int, dir_fd: int, destination: bytes) -> None:
    argument_types = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    try:
        libc_call(
            "linkat",
            argument_types,
            tmp_fd,
            b"",
            dir_fd,
            destination,
            AT_EMPTY_PATH,
        )
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise
        # Zig makes this same fallback when an otherwise usable kernel or
        # sandbox declines AT_EMPTY_PATH.
        libc_call(
            "linkat",
            argument_types,
            AT_FDCWD,
            os.fsencode(f"/proc/self/fd/{tmp_fd}"),
            dir_fd,
            destination,
            AT_SYMLINK_FOLLOW,
        )


def publish_named(dir_fd: int, temporary: bytes, destination: bytes) -> None:
    tmp_fd = os.open(
        temporary,
        os.O_CREAT | os.O_EXCL | os.O_RDWR,
        0o600,
        dir_fd=dir_fd,
    )
    try:
        os.write(tmp_fd, PROBE_BYTES)
    finally:
        os.close(tmp_fd)
    libc_call(
        "renameat2",
        [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint],
        dir_fd,
        temporary,
        dir_fd,
        destination,
        RENAME_NOREPLACE,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: zig-cache-filesystem.py <cache-directory>", file=sys.stderr)
        return 2

    cache_dir = sys.argv[1]
    nonce = os.urandom(8).hex()
    destination = f".zig-atomic-publish-{nonce}".encode()
    temporary = f".zig-atomic-publish-{nonce}.tmp".encode()
    dir_fd = -1
    tmp_fd = -1
    published = False
    try:
        dir_fd = os.open(cache_dir, os.O_RDONLY | os.O_DIRECTORY)
        try:
            tmp_fd = os.open(cache_dir, os.O_RDWR | os.O_TMPFILE, 0o600)
        except OSError as error:
            if error.errno not in O_TMPFILE_FALLBACK_ERRNOS:
                raise
            # Zig takes this branch when the filesystem declines O_TMPFILE.
            # Its named temporary is published with renameat2(NOREPLACE).
            publish_named(dir_fd, temporary, destination)
        else:
            os.write(tmp_fd, PROBE_BYTES)
            # When O_TMPFILE succeeds, Zig does not fall back after this point.
            # A filesystem that accepts the open and rejects AT_EMPTY_PATH is
            # therefore unusable as its local cache.
            publish_unnamed(tmp_fd, dir_fd, destination)
        published = True
    except (AttributeError, OSError) as error:
        print(
            f"zig-cache-filesystem: {cache_dir} cannot publish Zig response files: {error}",
            file=sys.stderr,
        )
        return 1
    finally:
        if published:
            os.unlink(destination, dir_fd=dir_fd)
        elif dir_fd >= 0:
            for path in (temporary, destination):
                try:
                    os.unlink(path, dir_fd=dir_fd)
                except FileNotFoundError:
                    pass
        if tmp_fd >= 0:
            os.close(tmp_fd)
        if dir_fd >= 0:
            os.close(dir_fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
