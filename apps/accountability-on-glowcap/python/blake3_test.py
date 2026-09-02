#!/usr/bin/env python3
"""The Python caller's hand-rolled Blake3, held to known answers.

The Python accountability caller derives its AID from this digest, and the Zig
host re-derives the same AID to attribute the call, so the two must agree byte
for byte. The cross-language demo proves that by construction but is not on the
ordinary gate, and this is the Python half of the vector test the Deno side
already carries: the empty-input and length-1025 vectors match Blake3's
published values, generated from the same Zig `std.crypto` the host uses.

Validated against a defect: a one-swap change to the message permutation fails
every vector below, so these exercise the compression, not just output length.
"""

from blake3 import blake3

VECTORS = [
    (b"", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
    (b"abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"),
    (b"glowcap accountability", "35f1679c96d6d0585fe90c6b596bddece15bf7fc195941509a046c41d2e4e27b"),
]


def main() -> None:
    for data, expected in VECTORS:
        got = blake3(data).hex()
        assert got == expected, f"blake3({data!r}): expected {expected}, got {got}"

    # One byte past a 1024-byte chunk exercises the parent-node path a short
    # input never reaches. Blake3's own test pattern (byte i is i mod 251) and
    # its published length-1025 vector.
    span = bytes(i % 251 for i in range(1025))
    got = blake3(span).hex()
    expected = "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"
    assert got == expected, f"blake3(1025-byte span): expected {expected}, got {got}"

    print("blake3.py: 4 vectors ok")


if __name__ == "__main__":
    main()
