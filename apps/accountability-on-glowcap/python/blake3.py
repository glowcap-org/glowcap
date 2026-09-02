"""Blake3-256, the digest every SAID in this application is built from.

The standard library does not carry Blake3. The digest has to be the same one
the Zig host computes or no AID either side derives will agree.
"""

BLOCK_LEN = 64
CHUNK_LEN = 1024

CHUNK_START = 1
CHUNK_END = 2
PARENT = 4
ROOT = 8

MASK = 0xFFFFFFFF

# Blake3's initial chaining value is the SHA-256 IV.
IV = (
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19,
)

MSG_PERMUTATION = (2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8)


def _rotr(x: int, n: int) -> int:
    return ((x >> n) | (x << (32 - n))) & MASK


def _mix(s: list[int], a: int, b: int, c: int, d: int, mx: int, my: int) -> None:
    s[a] = (s[a] + s[b] + mx) & MASK
    s[d] = _rotr(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & MASK
    s[b] = _rotr(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b] + my) & MASK
    s[d] = _rotr(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & MASK
    s[b] = _rotr(s[b] ^ s[c], 7)


def _round(s: list[int], m: list[int]) -> None:
    _mix(s, 0, 4, 8, 12, m[0], m[1])
    _mix(s, 1, 5, 9, 13, m[2], m[3])
    _mix(s, 2, 6, 10, 14, m[4], m[5])
    _mix(s, 3, 7, 11, 15, m[6], m[7])
    _mix(s, 0, 5, 10, 15, m[8], m[9])
    _mix(s, 1, 6, 11, 12, m[10], m[11])
    _mix(s, 2, 7, 8, 13, m[12], m[13])
    _mix(s, 3, 4, 9, 14, m[14], m[15])


def _compress(cv: list[int], block: list[int], counter: int, block_len: int, flags: int) -> list[int]:
    """One Blake3 compression: seven rounds over a 64-byte block, permuted between."""
    s = list(cv[:8]) + list(IV[:4]) + [
        counter & MASK,
        (counter >> 32) & MASK,
        block_len,
        flags,
    ]
    m = list(block)
    for r in range(7):
        _round(s, m)
        if r < 6:
            m = [m[i] for i in MSG_PERMUTATION]
    for i in range(8):
        s[i] ^= s[i + 8]
        s[i + 8] ^= cv[i]
    return s


def _block_words(block: bytes) -> list[int]:
    return [int.from_bytes(block[at : at + 4], "little") for at in range(0, BLOCK_LEN, 4)]


def _compress_chunk(chunk: bytes, counter: int, final_flags: int) -> list[int]:
    """Compress one chunk of at most 1024 bytes, returning its final state.

    ``final_flags`` rides the chunk's last block only, which is where ROOT
    belongs: setting it on every block of a multi-block chunk changes the digest.
    """
    cv = list(IV)
    blocks = max(1, -(-len(chunk) // BLOCK_LEN))
    for b in range(blocks):
        start = b * BLOCK_LEN
        block = chunk[start : start + BLOCK_LEN]
        flags = CHUNK_START if b == 0 else 0
        if b == blocks - 1:
            flags |= CHUNK_END | final_flags
        state = _compress(
            cv,
            _block_words(block.ljust(BLOCK_LEN, b"\0")),
            counter,
            len(block),
            flags,
        )
        if b == blocks - 1:
            return state
        cv = state[:8]
    raise AssertionError("unreachable")


def _compress_parent(left: list[int], right: list[int], flags: int) -> list[int]:
    return _compress(list(IV), left[:8] + right[:8], 0, BLOCK_LEN, PARENT | flags)


def _left_len(total: int) -> int:
    """Where a subtree splits: the largest power-of-two run of whole chunks below it."""
    chunks = 1
    while chunks * 2 * CHUNK_LEN < total:
        chunks *= 2
    return chunks * CHUNK_LEN


def _subtree_cv(data: bytes, counter: int) -> list[int]:
    if len(data) <= CHUNK_LEN:
        return _compress_chunk(data, counter, 0)[:8]
    split = _left_len(len(data))
    return _compress_parent(
        _subtree_cv(data[:split], counter),
        _subtree_cv(data[split:], counter + split // CHUNK_LEN),
        0,
    )[:8]


def blake3(data: bytes) -> bytes:
    """Blake3-256 of ``data``: the digest every SAID in this application is built from."""
    if len(data) <= CHUNK_LEN:
        state = _compress_chunk(data, 0, ROOT)
    else:
        split = _left_len(len(data))
        state = _compress_parent(
            _subtree_cv(data[:split], 0),
            _subtree_cv(data[split:], split // CHUNK_LEN),
            ROOT,
        )
    return b"".join(word.to_bytes(4, "little") for word in state[:8])


