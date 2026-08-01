// A KERI-shaped identity for the demo's foreign callers, the same one
// `zig/identity.zig` builds natively.
//
// The host will not attribute an Episode to an AID unless the caller can show
// that its signing key belongs to that AID, so a caller needs more than a
// keypair: it needs an inception event whose digest *is* its AID, a rotation
// that names the event before it, and the log of both to hand over with the
// request. That is what this module builds.
//
// Ed25519 comes from Web Crypto. Blake3 is implemented here because the
// platform does not carry it, and the digest has to be the same one the Zig
// host computes or no AID either side derives will agree.

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

export function b64url(bytes: Uint8Array): string {
	let s = "";
	for (const b of bytes) s += String.fromCharCode(b);
	return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A CESR-shaped primitive: a one-character derivation code and 43 base64 chars. */
function coded(code: string, raw: Uint8Array): string {
	return code + b64url(raw);
}

/** The width of a SAID and of a coded verkey, and of the placeholder for either. */
const SAID_LEN = 44;
/** The width of a base64url Ed25519 signature. */
const SIG_LEN = 86;

const encoder = new TextEncoder();

/** One key this identity has held, and the coded verkey it goes by. */
export interface Signer {
	/** The `D`-coded verkey the host reads. */
	readonly verkey: string;
	/** Sign `payload`, returning the raw 64 signature bytes. */
	sign(payload: string): Promise<Uint8Array>;
}

async function signerOf(pair: CryptoKeyPair): Promise<Signer> {
	const raw = new Uint8Array(
		await crypto.subtle.exportKey("raw", pair.publicKey),
	);
	return {
		verkey: coded("D", raw),
		sign: async (payload: string) =>
			new Uint8Array(
				await crypto.subtle.sign(
					"Ed25519",
					pair.privateKey,
					encoder.encode(payload),
				),
			),
	};
}

async function keypair(): Promise<CryptoKeyPair> {
	// `generateKey` is typed `CryptoKeyPair | CryptoKey`; an asymmetric
	// algorithm always yields a pair.
	return await crypto.subtle.generateKey("Ed25519", true, [
		"sign",
		"verify",
	]) as CryptoKeyPair;
}

async function rawVerkey(pair: CryptoKeyPair): Promise<Uint8Array> {
	return new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
}

/**
 * The next-key commitment: a digest over the key that will become current at the
 * next rotation. Committing to it before it is ever exposed is pre-rotation.
 */
function nextKeyDigest(rawNextVerkey: Uint8Array): string {
	return coded("E", blake3(rawNextVerkey));
}

/**
 * The SAID of a key event: the digest of the event's own bytes, with the fields
 * the digest cannot cover filled with placeholder runs. The event carries its own
 * SAID, and a rotation carries a signature computed from that SAID, so both slots
 * are blanked while the digest is taken. The host blanks the same two slots when
 * it re-derives, which is how the two sides arrive at the same bytes.
 */
function saidOf(draft: string): string {
	return coded("E", blake3(encoder.encode(draft)));
}

const BLANK_SAID = "#".repeat(SAID_LEN);
const BLANK_SIG = "#".repeat(SIG_LEN);

function renderInception(said: string, verkey: string, next: string): string {
	return `{"v":"KERIa","t":"icp","d":"${said}","i":"${said}","s":"0",` +
		`"kt":"1","k":["${verkey}"],"nt":"1","n":["${next}"]}`;
}

function renderRotation(
	said: string,
	aid: string,
	sn: number,
	prior: string,
	verkey: string,
	next: string,
	sig: string,
): string {
	return `{"v":"KERIa","t":"rot","d":"${said}","i":"${aid}","s":"${sn}",` +
		`"p":"${prior}","kt":"1","k":["${verkey}"],"nt":"1","n":["${next}"],` +
		`"sig":"${sig}"}`;
}

/**
 * A KERI-anchored identity: an AID, the key that speaks for it now, the key it
 * has committed to next, and the log of how it got here.
 */
export class Identity {
	#next: CryptoKeyPair;
	#events: string[] = [];
	#said: string;
	#sn = 0;
	#retired: Signer | null = null;

	readonly aid: string;
	/** The key the log makes authoritative, the one a host will accept. */
	current: Signer;

	private constructor(
		said: string,
		event: string,
		next: CryptoKeyPair,
		signer: Signer,
	) {
		this.aid = said;
		this.#said = said;
		this.#events.push(event);
		this.#next = next;
		this.current = signer;
	}

	/**
	 * Incept: draw the current key and the pre-rotated next key, and derive the
	 * AID from the inception event that commits to both. The AID is the digest of
	 * that event, which is what makes it self-certifying: no registry says this
	 * key belongs to this identifier, the identifier is built out of it.
	 */
	static async incept(): Promise<Identity> {
		const current = await keypair();
		const next = await keypair();
		const signer = await signerOf(current);
		const nextDigest = nextKeyDigest(await rawVerkey(next));

		const said = saidOf(
			renderInception(BLANK_SAID, signer.verkey, nextDigest),
		);
		const event = renderInception(said, signer.verkey, nextDigest);
		return new Identity(said, event, next, signer);
	}

	/**
	 * Rotate: the committed next key becomes current, a fresh next key is drawn
	 * and committed, and the event recording it is signed by the key it retires.
	 * The retired key stays reachable so a caller can demonstrate that a host
	 * refuses it.
	 */
	async rotate(): Promise<void> {
		const retiring = this.current;
		const newCurrent = this.#next;
		const newNext = await keypair();
		const signer = await signerOf(newCurrent);
		const nextDigest = nextKeyDigest(await rawVerkey(newNext));

		const prior = this.#said;
		this.#sn += 1;

		// Two passes: the first renders the draft, with the SAID and the
		// signature blanked, and hashes it; the second fills both in.
		const said = saidOf(renderRotation(
			BLANK_SAID,
			this.aid,
			this.#sn,
			prior,
			signer.verkey,
			nextDigest,
			BLANK_SIG,
		));
		// The rotation is signed by the key it retires, proving that the holder
		// of the old key authorized the handover. The SAID is a digest over every
		// other field, so signing these three commits to the whole event.
		const sig = b64url(
			await retiring.sign(`${said}|${signer.verkey}|${nextDigest}`),
		);

		this.#events.push(renderRotation(
			said,
			this.aid,
			this.#sn,
			prior,
			signer.verkey,
			nextDigest,
			sig,
		));
		this.#next = newNext;
		this.#said = said;
		this.#retired = retiring;
		this.current = signer;
	}

	/** The key the last rotation retired, or null if this identity never rotated. */
	get retired(): Signer | null {
		return this.#retired;
	}

	/** The key event log as it goes on the wire: one JSON event per line. */
	get kel(): string {
		return this.#events.join("\n") + "\n";
	}
}
