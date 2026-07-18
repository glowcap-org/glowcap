// OCapN locator URIs: parse an `ocapn://` URI into a `Locator`, format one, and
// the `tcpLocator` convenience. Delegates the grammar to the core C ABI's
// `pancake_uri_*` / `pancake_locator_*` functions. `mod.ts` re-exports the
// public members.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { L } from "./internal/layout.ts";
import { ab, outPointer, outUsize, readBytes } from "./internal/seam.ts";
import { BUFFER_TOO_SMALL, INVALID_ARGUMENT, OK } from "@pancake/abi";
import { check, PancakeError } from "./errors.ts";

export const HINT_DIRECT_ADDRESSES = "direct-addresses";

/** OCapN transport symbols; mirrors `model.transport.*`. */
export const TRANSPORT_TCP = "tcp";
export const TRANSPORT_KEYED_TCP = "keyed-tcp";
export const TRANSPORT_INPROC = "inproc";
export const TRANSPORT_IROH = "iroh";

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
}

// Read a (pointer, length) view pair the locator accessors fill, decoding the
// borrowed bytes into a JS string. A zero length (or NULL pointer) is "".
function readLocatorView(
	ptrBuf: Uint8Array<ArrayBuffer>,
	lenBuf: Uint8Array<ArrayBuffer>,
): string {
	const len = Number(outUsize(lenBuf));
	if (len === 0) return "";
	const ptr = outPointer(ptrBuf);
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
	const loc = outPointer(outLoc);
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
		const count = Number(outUsize(countBuf));
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
		return {
			transport: readLocatorField(s.pancake_locator_transport, loc),
			designator: readLocatorField(s.pancake_locator_designator, loc),
			swissnum: readLocatorField(s.pancake_locator_swissnum, loc),
			hints,
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
	// Size with a generous buffer; the call reports the exact length, so a
	// too-small buffer is retried at the reported size. The pointer/length
	// arrays are rebuilt per attempt: a `pointerOf` address is only promised
	// across the next outermost call, so a retry must re-stage rather than
	// carry addresses across two calls (the wasm adapter frees stale stagings
	// at call entry).
	let cap = 256;
	for (let attempt = 0; attempt < 2; attempt++) {
		const keyPtrs = pointerArray(keys), keyLens = lengthArray(keys);
		const valPtrs = pointerArray(vals), valLens = lengthArray(vals);
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
		const need = Number(outUsize(outLen));
		if (rc === OK) return new TextDecoder().decode(out.subarray(0, need));
		if (rc === BUFFER_TOO_SMALL && need > cap) {
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
// must outlive the call (they do; they are locals of the caller above). Entry
// width is the target's pointer width, so the arrays go through the active
// layout's accessors like every other pointer-carrying structure.
function pointerArray(
	bufs: Uint8Array<ArrayBuffer>[],
): Uint8Array<ArrayBuffer> {
	const arr = new Uint8Array(L.ptrSize * bufs.length);
	const dv = new DataView(arr.buffer);
	for (let i = 0; i < bufs.length; i++) L.setPtr(dv, i * L.ptrSize, ffi.pointerOf(bufs[i]));
	return arr as Uint8Array<ArrayBuffer>;
}

function lengthArray(bufs: Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
	const arr = new Uint8Array(L.ptrSize * bufs.length);
	const dv = new DataView(arr.buffer);
	for (let i = 0; i < bufs.length; i++) L.setUsize(dv, i * L.ptrSize, bufs[i].length);
	return arr as Uint8Array<ArrayBuffer>;
}

/** Render host:port as a tcp designator; bracket IPv6 for the core grammar. */
export function socketAddrDesignator(hostname: string, port: number): string {
	if (hostname.includes(":") && !(hostname.startsWith("[") && hostname.endsWith("]"))) {
		return `[${hostname}]:${port}`;
	}
	return `${hostname}:${port}`;
}

/** Split a bare designator as `host:port` through the core grammar
 * (`pancake_designator_host_port`). Prefer this over minting a peer URI
 * just to call `parseLocator`. */
export function designatorHostPort(designator: string): { hostname: string; port: number } {
	const data = new TextEncoder().encode(designator);
	const hPtr = new Uint8Array(8), hLen = new Uint8Array(8);
	const portBuf = new Uint8Array(2);
	check(s.pancake_designator_host_port(
		ab(data),
		BigInt(data.length),
		ab(hPtr),
		ab(hLen),
		ab(portBuf),
	));
	return {
		hostname: readLocatorView(hPtr, hLen),
		port: new DataView(portBuf.buffer).getUint16(0, true),
	};
}

/** Build a `tcp` locator from a literal hostname and port: `ocapn://hostname:port.tcp`,
 * rendered through the core grammar. The convenience for the common case, a
 * caller holding a hostname and port passes `connect(tcpLocator(hostname, port))`
 * instead of hand-formatting the URI. `hostname:port` is not a dial of its own; it
 * is a locator like any other. */
export function tcpLocator(hostname: string, port: number): string {
	return formatPeerUri(TRANSPORT_TCP, socketAddrDesignator(hostname, port));
}

/** Build a `keyed-tcp` locator: the designator is the listener's Ed25519 public
 * key in canonical hex, and `hostname`/`port` ride the `direct-addresses` hint
 * (ADR-0075). */
export function keyedTcpLocator(designator: string, hostname: string, port: number): string {
	return formatPeerUri(
		TRANSPORT_KEYED_TCP,
		designator,
		new Map([[HINT_DIRECT_ADDRESSES, socketAddrDesignator(hostname, port)]]),
	);
}

/** Build the verbatim exporter location-record bytes to record on the host
 * when the exporter is reachable only by a dial hint (ADR-0009), for an
 * exporter whose own session record carries no hint. `transport`/`designator`
 * name the exporter; a non-empty `directAddresses` adds the exporter's
 * comma-separated socket addresses as a `direct-addresses` hint, so a
 * cross-process recipient dials it directly with no discovery service (an iroh
 * exporter reachable only by address). An empty `directAddresses` yields a
 * hint-less location identical to the exporter's own signed session record.
 * The bytes are in the handoff codec (Syrup, as a give is); the result feeds
 * `Session.setExporterLocator`. */
export function encodePeerLocator(opts: {
	transport: string;
	designator: string;
	directAddresses?: string;
}): Uint8Array {
	const utf8 = new TextEncoder();
	const transport = utf8.encode(opts.transport);
	const designator = utf8.encode(opts.designator);
	const addrs = utf8.encode(opts.directAddresses ?? "");
	const outLoc = new Uint8Array(8), outLen = new Uint8Array(8);
	check(s.pancake_encode_peer_locator(
		ab(transport),
		BigInt(transport.length),
		ab(designator),
		BigInt(designator.length),
		ab(addrs),
		BigInt(addrs.length),
		ab(outLoc),
		ab(outLen),
	));
	const ptr = outPointer(outLoc);
	const len = outUsize(outLen);
	try {
		return readBytes(ptr, len);
	} finally {
		s.pancake_peer_locator_bytes_release(ptr, len);
	}
}
