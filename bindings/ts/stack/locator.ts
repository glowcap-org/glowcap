// OCapN locator URIs: parse an `ocapn://` URI into a `Locator`, format one, and
// the `tcpLocator` convenience. Delegates the grammar to the core C ABI's
// `pancake_uri_*` / `pancake_locator_*` functions. `mod.ts` re-exports the
// public members.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import { INVALID_ARGUMENT, OK } from "./internal/abi.ts";
import { check, PancakeError } from "./errors.ts";

//
// The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
// vocabulary, defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*`
// surface (so no binding hand-rolls a percent codec). These helpers wrap that
// FFI: parse copies every borrowed view into JS strings before releasing the
// handle, and format renders through the same grammar.

/** A parsed OCapN locator: the structured fields a `pancake_uri_parse_*` yields. */
export interface Locator {
	transport: string;
	designator: string;
	/** Empty for a peer URI; the swiss bytes for a sturdyref. */
	swissnum: string;
	hints: Map<string, string>;
	/** The designator's `host:port` split when the core grammar
	 * (`pancake_locator_host_port`) accepts it, `null` otherwise; a socket
	 * dialer consumes the split instead of re-deriving it. */
	hostPort: { host: string; port: number } | null;
}

// Read a (pointer, length) view pair the locator accessors fill, decoding the
// borrowed bytes into a JS string. A zero length (or NULL pointer) is "".
function readLocatorView(
	ptrBuf: Uint8Array<ArrayBuffer>,
	lenBuf: Uint8Array<ArrayBuffer>,
): string {
	const len = Number(new DataView(lenBuf.buffer).getBigUint64(0, true));
	if (len === 0) return "";
	const ptr = new DataView(ptrBuf.buffer).getBigUint64(0, true);
	if (ptr === NULL) return "";
	return new TextDecoder().decode(new Uint8Array(ffi.readMemory(ptr, len)));
}

function readLocatorField(
	fn: (
		loc: Ptr,
		p: Uint8Array<ArrayBuffer>,
		l: Uint8Array<ArrayBuffer>,
	) => number,
	loc: Ptr,
): string {
	const ptrBuf = new Uint8Array(8), lenBuf = new Uint8Array(8);
	check(fn(loc, ab(ptrBuf), ab(lenBuf)));
	return readLocatorView(ptrBuf, lenBuf);
}

/** Parse an `ocapn://` URI into its structured locator fields. `sturdyref`
 * selects the `/s/<swiss>` grammar; the default reads a peer URI (empty
 * swissnum). Throws `PancakeError` for a malformed URI. */
export function parseLocator(uri: string, sturdyref = false): Locator {
	const uriBytes = new TextEncoder().encode(uri);
	const outLoc = new Uint8Array(8);
	const rc = sturdyref
		? s.pancake_uri_parse_sturdyref(
			ab(uriBytes),
			BigInt(uriBytes.length),
			ab(outLoc),
		)
		: s.pancake_uri_parse_peer(
			ab(uriBytes),
			BigInt(uriBytes.length),
			ab(outLoc),
		);
	check(rc);
	const loc = new DataView(outLoc.buffer).getBigUint64(0, true);
	if (loc === NULL) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`uri parse returned no locator: ${uri}`,
		);
	}
	try {
		const hints = new Map<string, string>();
		const countBuf = new Uint8Array(8);
		check(s.pancake_locator_hint_count(loc, ab(countBuf)));
		const count = Number(new DataView(countBuf.buffer).getBigUint64(0, true));
		for (let i = 0; i < count; i++) {
			const kPtr = new Uint8Array(8),
				kLen = new Uint8Array(8),
				vPtr = new Uint8Array(8),
				vLen = new Uint8Array(8);
			check(
				s.pancake_locator_hint_at(
					loc,
					BigInt(i),
					ab(kPtr),
					ab(kLen),
					ab(vPtr),
					ab(vLen),
				),
			);
			hints.set(readLocatorView(kPtr, kLen), readLocatorView(vPtr, vLen));
		}
		// The host:port split is the core grammar's verdict, read while the
		// handle is alive: OK carries the split, INVALID_ARGUMENT means the
		// designator is not host:port (an iroh node id, say), which is a fact,
		// not a fault.
		const hPtr = new Uint8Array(8), hLen = new Uint8Array(8);
		const portBuf = new Uint8Array(2);
		const hpRc = s.pancake_locator_host_port(
			loc,
			ab(hPtr),
			ab(hLen),
			ab(portBuf),
		);
		let hostPort: { host: string; port: number } | null = null;
		if (hpRc === OK) {
			hostPort = {
				host: readLocatorView(hPtr, hLen),
				port: new DataView(portBuf.buffer).getUint16(0, true),
			};
		} else if (hpRc !== INVALID_ARGUMENT) {
			check(hpRc);
		}
		return {
			transport: readLocatorField(s.pancake_locator_transport, loc),
			designator: readLocatorField(s.pancake_locator_designator, loc),
			swissnum: readLocatorField(s.pancake_locator_swissnum, loc),
			hints,
			hostPort,
		};
	} finally {
		s.pancake_locator_release(loc);
	}
}

/** Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
 * through the core grammar. */
export function formatPeerUri(
	transport: string,
	designator: string,
	hints: Map<string, string> = new Map(),
): string {
	const enc = new TextEncoder();
	const t = enc.encode(transport), d = enc.encode(designator);
	const keys: Uint8Array<ArrayBuffer>[] = [],
		vals: Uint8Array<ArrayBuffer>[] = [];
	for (const [k, v] of hints) {
		keys.push(enc.encode(k));
		vals.push(enc.encode(v));
	}
	const keyPtrs = pointerArray(keys), keyLens = lengthArray(keys);
	const valPtrs = pointerArray(vals), valLens = lengthArray(vals);

	// Size with a generous buffer; the call reports the exact length, so a
	// too-small buffer is retried at the reported size.
	let cap = 256;
	for (let attempt = 0; attempt < 2; attempt++) {
		const out = new Uint8Array(cap), outLen = new Uint8Array(8);
		const rc = s.pancake_uri_format_peer(
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			keyPtrs,
			keyLens,
			valPtrs,
			valLens,
			BigInt(keys.length),
			ab(out),
			BigInt(cap),
			ab(outLen),
		);
		const need = Number(new DataView(outLen.buffer).getBigUint64(0, true));
		if (rc === OK) return new TextDecoder().decode(out.subarray(0, need));
		if (rc === INVALID_ARGUMENT && need > cap) {
			cap = need;
			continue;
		}
		check(rc);
	}
	throw new PancakeError(
		INVALID_ARGUMENT,
		`formatPeerUri: could not size buffer for ${transport}/${designator}`,
	);
}

// Build a `const uint8_t **` array of pointers into the given byte buffers, and
// the parallel `const size_t *` length array, for the format FFI. The buffers
// must outlive the call (they do; they are locals of the caller above).
function pointerArray(
	bufs: Uint8Array<ArrayBuffer>[],
): Uint8Array<ArrayBuffer> {
	const arr = new BigUint64Array(bufs.length);
	for (let i = 0; i < bufs.length; i++) arr[i] = ffi.pointerOf(bufs[i]);
	return new Uint8Array(arr.buffer) as Uint8Array<ArrayBuffer>;
}

function lengthArray(bufs: Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
	const arr = new BigUint64Array(bufs.length);
	for (let i = 0; i < bufs.length; i++) arr[i] = BigInt(bufs[i].length);
	return new Uint8Array(arr.buffer) as Uint8Array<ArrayBuffer>;
}

/** Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
 * rendered through the core grammar. The convenience for the common case, a
 * caller holding a host and port passes `connect(tcpLocator(host, port))`
 * instead of hand-formatting the URI. `host:port` is not a dial of its own; it
 * is a locator like any other. */
export function tcpLocator(host: string, port: number): string {
	return formatPeerUri("tcp", `${host}:${port}`);
}
