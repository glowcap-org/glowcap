/** Blake3-256, the digest every SAID in this application is built from.
 *
 * The platform does not carry Blake3. The digest has to be the same one the
 * Zig host computes or no AID either side derives will agree.
 */

const BLOCK_LEN = 64;
const CHUNK_LEN = 1024;

const CHUNK_START = 1;
const CHUNK_END = 2;
const PARENT = 4;
const ROOT = 8;

// Blake3's initial chaining value is the SHA-256 IV.
const IV = new Uint32Array([
	0x6a09e667,
	0xbb67ae85,
	0x3c6ef372,
	0xa54ff53a,
	0x510e527f,
	0x9b05688c,
	0x1f83d9ab,
	0x5be0cd19,
]);

const MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];

function rotr(x: number, n: number): number {
	return ((x >>> n) | (x << (32 - n))) >>> 0;
}

function mix(
	s: Uint32Array,
	a: number,
	b: number,
	c: number,
	d: number,
	mx: number,
	my: number,
): void {
	s[a] = (s[a] + s[b] + mx) >>> 0;
	s[d] = rotr(s[d] ^ s[a], 16);
	s[c] = (s[c] + s[d]) >>> 0;
	s[b] = rotr(s[b] ^ s[c], 12);
	s[a] = (s[a] + s[b] + my) >>> 0;
	s[d] = rotr(s[d] ^ s[a], 8);
	s[c] = (s[c] + s[d]) >>> 0;
	s[b] = rotr(s[b] ^ s[c], 7);
}

function round(s: Uint32Array, m: Uint32Array): void {
	mix(s, 0, 4, 8, 12, m[0], m[1]);
	mix(s, 1, 5, 9, 13, m[2], m[3]);
	mix(s, 2, 6, 10, 14, m[4], m[5]);
	mix(s, 3, 7, 11, 15, m[6], m[7]);
	mix(s, 0, 5, 10, 15, m[8], m[9]);
	mix(s, 1, 6, 11, 12, m[10], m[11]);
	mix(s, 2, 7, 8, 13, m[12], m[13]);
	mix(s, 3, 4, 9, 14, m[14], m[15]);
}

/** One Blake3 compression: seven rounds over a 64-byte block, permuted between. */
function compress(
	cv: Uint32Array,
	block: Uint32Array,
	counter: number,
	blockLen: number,
	flags: number,
): Uint32Array {
	const s = new Uint32Array(16);
	s.set(cv.subarray(0, 8), 0);
	s.set(IV.subarray(0, 4), 8);
	s[12] = counter >>> 0;
	s[13] = Math.floor(counter / 4294967296) >>> 0;
	s[14] = blockLen;
	s[15] = flags;

	let m = block;
	for (let r = 0; r < 7; r++) {
		round(s, m);
		if (r < 6) {
			const permuted = new Uint32Array(16);
			for (let i = 0; i < 16; i++) permuted[i] = m[MSG_PERMUTATION[i]];
			m = permuted;
		}
	}
	for (let i = 0; i < 8; i++) {
		s[i] ^= s[i + 8];
		s[i + 8] ^= cv[i];
	}
	return s;
}

function blockWords(bytes: Uint8Array): Uint32Array {
	const words = new Uint32Array(16);
	for (let i = 0; i < 16; i++) {
		const at = i * 4;
		words[i] = (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) |
			(bytes[at + 3] << 24)) >>> 0;
	}
	return words;
}

/**
 * Compress one chunk of at most 1024 bytes, returning its final state.
 * `finalFlags` rides the chunk's last block only, which is where ROOT belongs:
 * setting it on every block of a multi-block chunk changes the digest.
 */
function compressChunk(
	chunk: Uint8Array,
	counter: number,
	finalFlags: number,
): Uint32Array {
	let cv: Uint32Array = IV;
	const blocks = Math.max(1, Math.ceil(chunk.length / BLOCK_LEN));
	const padded = new Uint8Array(BLOCK_LEN);
	for (let b = 0;; b++) {
		const start = b * BLOCK_LEN;
		const end = Math.min(start + BLOCK_LEN, chunk.length);
		padded.fill(0);
		padded.set(chunk.subarray(start, end));
		let blockFlags = 0;
		if (b === 0) blockFlags |= CHUNK_START;
		if (b === blocks - 1) blockFlags |= CHUNK_END | finalFlags;
		const state = compress(
			cv,
			blockWords(padded),
			counter,
			end - start,
			blockFlags,
		);
		if (b === blocks - 1) return state;
		cv = state.subarray(0, 8);
	}
}

function compressParent(
	left: Uint32Array,
	right: Uint32Array,
	flags: number,
): Uint32Array {
	const block = new Uint32Array(16);
	block.set(left.subarray(0, 8), 0);
	block.set(right.subarray(0, 8), 8);
	return compress(IV, block, 0, BLOCK_LEN, PARENT | flags);
}

/** Where a subtree splits: the largest power-of-two run of whole chunks below it. */
function leftLen(total: number): number {
	let chunks = 1;
	while (chunks * 2 * CHUNK_LEN < total) chunks *= 2;
	return chunks * CHUNK_LEN;
}

function subtreeCv(input: Uint8Array, counter: number): Uint32Array {
	if (input.length <= CHUNK_LEN) {
		return compressChunk(input, counter, 0).subarray(0, 8);
	}
	const split = leftLen(input.length);
	return compressParent(
		subtreeCv(input.subarray(0, split), counter),
		subtreeCv(input.subarray(split), counter + split / CHUNK_LEN),
		0,
	).subarray(0, 8);
}

/** Blake3-256 of `input`: the digest every SAID in this application is built from. */
export function blake3(input: Uint8Array): Uint8Array {
	const split = leftLen(input.length);
	const state = input.length <= CHUNK_LEN ? compressChunk(input, 0, ROOT) : compressParent(
		subtreeCv(input.subarray(0, split), 0),
		subtreeCv(input.subarray(split), split / CHUNK_LEN),
		ROOT,
	);
	const out = new Uint8Array(32);
	for (let i = 0; i < 8; i++) {
		const w = state[i];
		out[i * 4] = w & 0xff;
		out[i * 4 + 1] = (w >>> 8) & 0xff;
		out[i * 4 + 2] = (w >>> 16) & 0xff;
		out[i * 4 + 3] = (w >>> 24) & 0xff;
	}
	return out;
}
