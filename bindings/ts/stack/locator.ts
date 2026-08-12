// OCapN locator URIs: parse an `ocapn://` URI into a `Locator`, format one, and
// the `tcpLocator` convenience. Delegates the grammar to the core C ABI's
// `pancake_uri_*` / `pancake_locator_*` functions. `mod.ts` re-exports the
// public members.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { L } from "./internal/layout.ts";
import { ab, outPointer, outUsize, readBytes } from "./internal/seam.ts";
import {
	BUFFER_TOO_SMALL,
	HINT_BOOLEAN,
	HINT_BYTES,
	HINT_DIRECT_ADDRESSES,
	HINT_INTEGER,
	HINT_STRING,
	HINTS_BOOLEAN_FALSE,
	HINTS_MAP,
	INVALID_ARGUMENT,
	OK,
	TRANSPORT_INPROC,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
} from "@pancake/abi";
import { check, PancakeError } from "./errors.ts";

export {
	HINT_DIRECT_ADDRESSES,
	TRANSPORT_INPROC,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
};

//
// The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
// vocabulary, defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*`
// surface (so no binding hand-rolls a percent codec). These helpers wrap that
// FFI: parse copies every borrowed view into JS strings before releasing the
// handle, and format renders through the same grammar.

export type HintValue = string | Uint8Array<ArrayBuffer> | boolean | bigint;
export type HintWireForm = "map" | "boolean-false";

/** A complete OCapN locator. URI parsing yields string-valued hints; the
 * driver/provider seam preserves every typed hint arm. */
export interface Locator {
	transport: string;
	designator: string;
	hints: Map<string, HintValue>;
	hintWireForm: HintWireForm;
}

/** A peer locator paired with its opaque authority-bearing swissnum. */
export interface SturdyRef {
	locator: Locator;
	swissnum: Uint8Array<ArrayBuffer>;
}

/** Internal owner for the opaque locator handle exported by
 * `libpancake_ocapn`. Driver and provider calls borrow only its POD view. */
export class OwnedLocator {
	#raw: Ptr;

	private constructor(raw: Ptr) {
		if (raw === NULL) {
			throw new PancakeError(INVALID_ARGUMENT, "OCapN returned a null locator handle");
		}
		this.#raw = raw;
	}

	static create(locator: Locator): OwnedLocator {
		const transport = new TextEncoder().encode(locator.transport);
		const designator = new TextEncoder().encode(locator.designator);
		const out = new Uint8Array(L.ptrSize);
		check(s.pancake_locator_new(
			ab(transport),
			BigInt(transport.length),
			ab(designator),
			BigInt(designator.length),
			locator.hintWireForm === "map" ? HINTS_MAP : HINTS_BOOLEAN_FALSE,
			ab(out),
		));
		const owned = new OwnedLocator(outPointer(out));
		try {
			for (const [name, value] of locator.hints) {
				const nameBytes = new TextEncoder().encode(name);
				let rc: number;
				if (typeof value === "string") {
					const bytes = new TextEncoder().encode(value);
					rc = s.pancake_locator_add_string(
						owned.#raw,
						ab(nameBytes),
						BigInt(nameBytes.length),
						ab(bytes),
						BigInt(bytes.length),
					);
				} else if (value instanceof Uint8Array) {
					rc = s.pancake_locator_add_bytes(
						owned.#raw,
						ab(nameBytes),
						BigInt(nameBytes.length),
						ab(value),
						BigInt(value.length),
					);
				} else if (typeof value === "boolean") {
					rc = s.pancake_locator_add_boolean(
						owned.#raw,
						ab(nameBytes),
						BigInt(nameBytes.length),
						value ? 1 : 0,
					);
				} else {
					rc = s.pancake_locator_add_integer(
						owned.#raw,
						ab(nameBytes),
						BigInt(nameBytes.length),
						value,
					);
				}
				check(rc);
			}
			return owned;
		} catch (error) {
			owned.release();
			throw error;
		}
	}

	static adopt(raw: Ptr): OwnedLocator {
		return new OwnedLocator(raw);
	}

	static cloneView(view: Uint8Array<ArrayBuffer>): OwnedLocator {
		const out = new Uint8Array(L.ptrSize);
		check(s.pancake_locator_clone(ab(view), ab(out)));
		return new OwnedLocator(outPointer(out));
	}

	borrowView(): Ptr {
		if (this.#raw === NULL) {
			throw new PancakeError(INVALID_ARGUMENT, "locator handle is released");
		}
		const out = new Uint8Array(L.ptrSize);
		check(s.pancake_locator_borrow_view(this.#raw, ab(out)));
		return outPointer(out);
	}

	release(): void {
		if (this.#raw === NULL) return;
		s.pancake_locator_release(this.#raw);
		this.#raw = NULL;
	}

	value(): Locator {
		if (this.#raw === NULL) {
			throw new PancakeError(INVALID_ARGUMENT, "locator handle is released");
		}
		const countOut = new Uint8Array(L.ptrSize);
		check(s.pancake_locator_hint_count(this.#raw, ab(countOut)));
		const hints = new Map<string, HintValue>();
		for (let index = 0; index < Number(outUsize(countOut)); index++) {
			const bytes = new Uint8Array(L.LOCATOR_HINT_VIEW_SIZE);
			check(s.pancake_locator_hint_at(this.#raw, BigInt(index), ab(bytes)));
			const hint = new DataView(bytes.buffer);
			const name = new TextDecoder().decode(readBytes(
				L.getPtr(hint, L.LOCATOR_HINT_VIEW_NAME_OFF),
				L.getUsize(hint, L.LOCATOR_HINT_VIEW_NAME_LEN_OFF),
			));
			const kind = hint.getUint32(L.LOCATOR_HINT_VIEW_KIND_OFF, true);
			let value: HintValue;
			if (kind === HINT_STRING) {
				value = new TextDecoder().decode(readBytes(
					L.getPtr(hint, L.LOCATOR_HINT_VIEW_BYTES_OFF),
					L.getUsize(hint, L.LOCATOR_HINT_VIEW_BYTES_LEN_OFF),
				));
			} else if (kind === HINT_BYTES) {
				value = new Uint8Array(readBytes(
					L.getPtr(hint, L.LOCATOR_HINT_VIEW_BYTES_OFF),
					L.getUsize(hint, L.LOCATOR_HINT_VIEW_BYTES_LEN_OFF),
				));
			} else if (kind === HINT_BOOLEAN) {
				const raw = hint.getUint8(L.LOCATOR_HINT_VIEW_BOOLEAN_VALUE_OFF);
				if (raw > 1) {
					throw new PancakeError(
						INVALID_ARGUMENT,
						"OCapN returned an invalid boolean hint",
					);
				}
				value = raw !== 0;
			} else if (kind === HINT_INTEGER) {
				value = hint.getBigInt64(L.LOCATOR_HINT_VIEW_INTEGER_VALUE_OFF, true);
			} else {
				throw new PancakeError(
					INVALID_ARGUMENT,
					`OCapN returned locator hint kind ${kind}, outside the typed hint ABI`,
				);
			}
			hints.set(name, value);
		}

		const wireOut = new Uint8Array(4);
		check(s.pancake_locator_hint_wire_form(this.#raw, ab(wireOut)));
		const wire = new DataView(wireOut.buffer).getUint32(0, true);
		if (wire !== HINTS_MAP && wire !== HINTS_BOOLEAN_FALSE) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"OCapN returned an unknown locator hint wire form",
			);
		}

		return {
			transport: readLocatorField(s.pancake_locator_transport, this.#raw),
			designator: readLocatorField(s.pancake_locator_designator, this.#raw),
			hints,
			hintWireForm: wire === HINTS_MAP ? "map" : "boolean-false",
		};
	}
}

export function withOwnedLocator<T>(locator: Locator, use: (owned: OwnedLocator) => T): T {
	const owned = OwnedLocator.create(locator);
	try {
		return use(owned);
	} finally {
		owned.release();
	}
}

export function stringHint(locator: Locator, name: string): string | undefined {
	const value = locator.hints.get(name);
	return typeof value === "string" ? value : undefined;
}

/** Render a typed peer locator only when every hint has a lossless URI
 * spelling. URI syntax cannot represent bytes, booleans, or integers. */
export function formatLocatorUri(locator: Locator): string {
	const hints = new Map<string, string>();
	for (const [name, value] of locator.hints) {
		if (typeof value !== "string") {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`locator hint ${JSON.stringify(name)} has no lossless URI spelling`,
			);
		}
		hints.set(name, value);
	}
	return formatPeerUri(locator.transport, locator.designator, hints);
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

/** Parse an `ocapn://` peer URI through the core grammar. */
export function parseLocator(uri: string): Locator {
	const uriBytes = new TextEncoder().encode(uri);
	const outLoc = new Uint8Array(8);
	check(s.pancake_uri_parse_peer(
		ab(uriBytes),
		BigInt(uriBytes.length),
		ab(outLoc),
	));
	const owned = OwnedLocator.adopt(outPointer(outLoc));
	try {
		return owned.value();
	} finally {
		owned.release();
	}
}

/** Parse an `ocapn://.../s/<swiss>` sturdyref without losing authority. */
export function parseSturdyRef(uri: string): SturdyRef {
	const uriBytes = new TextEncoder().encode(uri);
	const out = new Uint8Array(L.ptrSize);
	check(s.pancake_uri_parse_sturdyref(
		ab(uriBytes),
		BigInt(uriBytes.length),
		ab(out),
	));
	const raw = outPointer(out);
	try {
		const viewOut = new Uint8Array(L.ptrSize);
		check(s.pancake_sturdyref_borrow_locator(raw, ab(viewOut)));
		const view = outPointer(viewOut);
		if (view === NULL) {
			throw new PancakeError(INVALID_ARGUMENT, "OCapN returned a null sturdyref locator");
		}
		const ownedLocator = OwnedLocator.cloneView(
			new Uint8Array(ffi.readMemory(view, L.LOCATOR_VIEW_SIZE)),
		);
		let locator: Locator;
		try {
			locator = ownedLocator.value();
		} finally {
			ownedLocator.release();
		}

		const ptrOut = new Uint8Array(L.ptrSize);
		const lenOut = new Uint8Array(L.ptrSize);
		check(s.pancake_sturdyref_swissnum(raw, ab(ptrOut), ab(lenOut)));
		return {
			locator,
			// `readBytes` owns an ArrayBuffer-backed copy; state that fact at the
			// public sturdyref boundary for Deno's strict typed-array generic.
			swissnum: readBytes(outPointer(ptrOut), outUsize(lenOut)) as Uint8Array<ArrayBuffer>,
		};
	} finally {
		s.pancake_sturdyref_release(raw);
	}
}

/** Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
 * through the core grammar. */
export function formatPeerUri(
	transport: string,
	designator: string,
	hints: Map<string, string> = new Map(),
): string {
	return formatUri(transport, designator, null, hints, "formatPeerUri");
}

/** Format a peer locator plus opaque swissnum as a sturdyref through the same
 * core grammar that parses it. Taking the peer URI keeps transport-specific
 * locator construction at its owning helper (`keyedTcpLocator`, etc.); this
 * function adds authority without interpreting or splicing URI syntax. */
export function formatSturdyRef(
	locatorUri: string,
	swissnum: string | Uint8Array,
): string {
	const locator = parseLocator(locatorUri);
	const hints = new Map<string, string>();
	for (const [name, value] of locator.hints) {
		if (typeof value !== "string") {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`formatSturdyRef: hint "${name}" is not string-valued`,
			);
		}
		hints.set(name, value);
	}
	const bytes = typeof swissnum === "string"
		? new TextEncoder().encode(swissnum)
		: new Uint8Array(swissnum);
	return formatUri(
		locator.transport,
		locator.designator,
		bytes,
		hints,
		"formatSturdyRef",
	);
}

function formatUri(
	transport: string,
	designator: string,
	swissnum: Uint8Array<ArrayBuffer> | null,
	hints: Map<string, string>,
	operation: string,
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
		const rc = swissnum === null
			? s.pancake_uri_format_peer(
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
			)
			: s.pancake_uri_format_sturdyref(
				ab(t),
				BigInt(t.length),
				ab(d),
				BigInt(d.length),
				ab(swissnum),
				BigInt(swissnum.length),
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
		`${operation}: could not size buffer for ${transport}/${designator}`,
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

/** Build a `noise-tcp` locator from the listener's durable key and bound
 * address. The key is the designator; the socket is a direct-addresses hint. */
export function noiseTcpLocator(designator: string, hostname: string, port: number): string {
	return formatPeerUri(
		TRANSPORT_NOISE_TCP,
		designator,
		new Map([[HINT_DIRECT_ADDRESSES, socketAddrDesignator(hostname, port)]]),
	);
}

/** Encode a complete typed locator as the canonical signed handoff record. */
export function encodePeerLocator(locator: Locator): Uint8Array {
	const outLoc = new Uint8Array(8), outLen = new Uint8Array(8);
	withOwnedLocator(
		locator,
		(owned) =>
			check(s.pancake_locator_record_encode(owned.borrowView(), ab(outLoc), ab(outLen))),
	);
	const ptr = outPointer(outLoc);
	const len = outUsize(outLen);
	try {
		return readBytes(ptr, len);
	} finally {
		s.pancake_locator_record_bytes_release(ptr, len);
	}
}
