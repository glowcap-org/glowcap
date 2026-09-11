#!/usr/bin/env python3
"""Bound an ELF C ABI library's per-thread storage before installation."""

import struct
import sys

# Libraries compose inside host-created threads. Nine archives at this ceiling
# reserve at most 144 KiB, leaving room for calls on a 2 MiB worker stack.
# Zig's default alternate signal stack alone is 256 KiB per archive.
MAX_TLS_BYTES = 16 * 1024


def tls_size(path):
    with open(path, "rb") as artifact:
        header = artifact.read(64)
        if header[:4] != b"\x7fELF" or header[4] not in (1, 2) or header[5] not in (1, 2):
            raise ValueError("expected a 32-bit or 64-bit ELF artifact")
        endian = "<" if header[5] == 1 else ">"
        wide = header[4] == 2
        word = "Q" if wide else "I"
        offset = struct.unpack_from(endian + word, header, 32 if wide else 28)[0]
        stride, count = struct.unpack_from(endian + "HH", header, 54 if wide else 42)
        if count == 0xffff:
            raise ValueError("extended program-header counts are unsupported")
        total = 0
        for index in range(count):
            artifact.seek(offset + index * stride)
            program = artifact.read(stride)
            if struct.unpack_from(endian + "I", program)[0] == 7:  # PT_TLS
                total += struct.unpack_from(endian + word, program, 40 if wide else 20)[0]
        return total


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: abi_tls.py LIBRARY")
    path = sys.argv[1]
    try:
        size = tls_size(path)
    except (OSError, ValueError, IndexError, struct.error) as error:
        sys.exit(f"abi-tls: {path}: {error}")
    if size > MAX_TLS_BYTES:
        sys.exit(
            f"abi-tls: {path}: {size} bytes of per-thread storage exceeds "
            f"{MAX_TLS_BYTES}; C ABI roots must select c_abi_shared.library_options "
            "and leave alternate signal stacks to the embedder"
        )


if __name__ == "__main__":
    main()
