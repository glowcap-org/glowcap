// A KERI-shaped identity for the demo's foreign callers, the same one
// `zig/identity.zig` builds natively.
//
// The host will not attribute an Episode to an AID unless the caller can show
// that its signing key belongs to that AID, so a caller needs more than a
// keypair: it needs an inception event whose digest *is* its AID, a rotation
// that names the event before it, and the log of both to hand over with the
// request. That is what this module builds.
//
// Ed25519 comes from Web Crypto. Blake3 lives in `blake3.ts` because the
// platform does not carry it.

import { blake3 } from "./blake3.ts";

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
		// of the old key authorized the handover. The SAID is a digest over every status-allow: replacement state identity
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
