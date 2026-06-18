// Idiomatic JavaScript/TypeScript API for pancake — the core OCapN/CapTP peer
// you drive, over the `libpancake_ocapn` archive (ADR-0059). One module runs on
// Deno, Bun, and (experimentally) Node; the runtime-specific FFI and sockets are
// isolated behind `./internal/ffi/runtime.ts`.
//
// This is the base module: it loads only the core archive, so a program that
// drives a peer in memory or rides the runtime's own networking needs nothing
// else. A transport that links its own pancake archive lives in its own module
// beside this one — `./transport/tcp.ts`, `./transport/inproc.ts`, and the
// optional `@pancake/iroh` package — and builds on the
// types exported here, exactly as a C consumer links `libpancake_ocapn` plus the
// transport archives it wants. The raw FFI lives in the internal
// `./internal/ffi/core.ts` module; this module is just the public surface over
// it. What you use is a `Peer` class (disposable via `using`),
// discriminated-union value types, and typed `Event` objects out of `poll`. The
// default `Peer` negotiates an authenticated session; raw direct-frame fixtures
// use `Peer.rawOpen`. Integers are `bigint`, floats are `number`.
//
//   using peer = Peer.rawOpen();
//   peer.registerImport(5n);
//   peer.sendDeliver(far(5n), [42n, new Uint8Array([1, 2])], 9n);
//   peer.step();
//   const frame = peer.takeOutbound();

import {
	ABORT_DOMAIN_CODEC,
	ABORT_DOMAIN_SESSION,
	ARG_BIG_INTEGER,
	ARG_BOOLEAN,
	ARG_BYTES,
	ARG_FLOAT64,
	ARG_INTEGER,
	ARG_KEYWORD,
	ARG_LIST,
	ARG_REFERENCE,
	ARG_SET,
	ARG_SIZE,
	ARG_STRING,
	ARG_SYMBOL,
	ARG_TAGGED,
	ARG_VOID,
	BROKEN,
	CAPTP_VERSION_PRE_SPEC,
	CAPTP_VERSION_V1_0,
	CODEC_CAPNP,
	CODEC_SYRUP,
	ENLIVEN_CACHED,
	ENLIVEN_OUTCOME_BROKEN,
	ENLIVEN_OUTCOME_FULFILLED,
	EVENT_DELIVER,
	EVENT_RESOLVE,
	FRAME_SHAPE_BYTE,
	HINTS_EMPTY_FALSE,
	HINTS_EMPTY_MAP,
	INVALID_ARGUMENT,
	OK,
	REF_BROKEN,
	REF_FAR,
	REF_NEAR,
	REF_PROMISE,
	REF_SIZE,
	REF_STURDY,
	REF_SUB_OBJECT,
	REF_SUB_PROMISE,
	RESOLUTION_BREAK,
	RESOLUTION_FULFILL,
	RESOLUTION_HANDOFF,
	UNSUPPORTED_VALUE,
	WOULD_BLOCK,
} from "./internal/constants.ts";
import { coreS as s } from "./internal/ffi/core.ts";
import {
	ffi,
	type NativeCallback,
	net,
	type NetConn,
	type NetListener,
	NULL,
	type Ptr,
} from "./internal/ffi/runtime.ts";

type Profile = "v1.0" | "pre-spec";

function profileId(profile: Profile): number {
	return profile === "pre-spec" ? CAPTP_VERSION_PRE_SPEC : CAPTP_VERSION_V1_0;
}

export type Codec = "syrup" | "capnp";

export function codecId(codec: Codec): number {
	return codec === "capnp" ? CODEC_CAPNP : CODEC_SYRUP;
}

// ── ABI version and per-thread last error ───────────────────────────────────

/** The linked library's ABI version as `[major, minor, patch]`. */
export function abiVersion(): [number, number, number] {
	const major = new Uint8Array(4),
		minor = new Uint8Array(4),
		patch = new Uint8Array(4);
	s.pancake_abi_version(major, minor, patch);
	return [
		new DataView(major.buffer).getUint32(0, true),
		new DataView(minor.buffer).getUint32(0, true),
		new DataView(patch.buffer).getUint32(0, true),
	];
}

/** The calling thread's last error message, or null when there is none. */
export function lastError(): string | null {
	const len = Number(s.pancake_last_error(null, 0n));
	if (len === 0) return null;
	// The C side reserves one byte for a NUL and copies at most cap-1 message
	// bytes, so allocate len + 1 to receive all len of them.
	const buf = new Uint8Array(len + 1);
	const written = Number(s.pancake_last_error(buf, BigInt(buf.length)));
	return new TextDecoder().decode(
		buf.subarray(0, Math.min(written, buf.length)),
	);
}

/** Clear the calling thread's last error. */
export function clearLastError(): void {
	s.pancake_clear_last_error();
}

/** The typed cause of a peer's most recent local dispatch failure — the
 * counterpart of the C ABI's `PancakeLastAbort`. `domain` names the layer that
 * refused, `kind` the projected `op:abort` kind when one exists, `message` the
 * static diagnostic, and `errorName` the originating error. */
export interface AbortDetail {
	domain: "codec" | "session" | "foreign";
	kind: string | null;
	message: string;
	errorName: string;
}

export class PancakeError extends Error {
	/** The thread-local diagnostic captured when this error was raised, if any. */
	readonly detail: string | null;
	/** The typed abort cause, attached when a peer refused an inbound frame. */
	abort: AbortDetail | null = null;
	constructor(public code: number, detail?: string) {
		// For a code an FFI call returned, capture the thread-local message now.
		// A client-side validation throw passes an explicit `detail` instead, so it
		// never scrapes an unrelated thread-local left by some earlier call.
		const d = detail ?? lastError();
		super(d ? `pancake error ${code}: ${d}` : `pancake error ${code}`);
		this.detail = d;
		this.name = "PancakeError";
	}
}

/** A promise the partner broke — the typed rejection an awaited `send` (or any
 * settled vow) produces. `reason` is the partner's break message. */
export class VowBroken extends PancakeError {
	constructor(public readonly reason: string) {
		super(BROKEN, reason);
		this.name = "VowBroken";
	}
}

/** A `fetch` that settled, but not with a capability — the application-level
 * outcome (the partner answered, and the answer was not a reference), distinct
 * from a marshalling failure or a broken promise. `capabilityName` is the
 * swiss-number the fetch asked for. */
export class FetchFailed extends PancakeError {
	constructor(public readonly capabilityName: string) {
		super(BROKEN, `fetch("${capabilityName}") did not resolve to a capability`);
		this.name = "FetchFailed";
	}
}

function check(code: number): void {
	if (code !== OK) throw new PancakeError(code);
}

// Our buffers are always ArrayBuffer-backed; this bridges Deno's FFI/pointer
// BufferSource typing, which rejects the `Uint8Array<ArrayBufferLike>` generic.
// Exported as part of the core's binding-internal seam: the transport modules
// marshal frames through the same helpers (see also `readBytes`, `outPointer`,
// `releaseManagedFrame`).
export function ab(b: Uint8Array): Uint8Array<ArrayBuffer> {
	return b as Uint8Array<ArrayBuffer>;
}

// ── Value vocabulary ─────────────────────────────────────────────────────────

export type Reference =
	| { kind: "near"; id: bigint; promise?: boolean }
	| { kind: "far"; id: bigint; promise?: boolean }
	| { kind: "promise"; answer: bigint }
	| { kind: "sturdy" }
	| { kind: "broken" };

export const near = (id: bigint, promise = false): Reference => ({
	kind: "near",
	id,
	promise,
});
export const far = (id: bigint, promise = false): Reference => ({
	kind: "far",
	id,
	promise,
});
export const promise = (answer: bigint): Reference => ({
	kind: "promise",
	answer,
});

/** Tag a string so it marshals as an OCapN symbol rather than a string. */
export class Sym {
	constructor(public readonly value: string) {}
}
export const sym = (value: string): Sym => new Sym(value);

/** A string that marshals as an OCapN keyword. */
export class Kw {
	constructor(public readonly value: string) {}
}
export const kw = (value: string): Kw => new Kw(value);

/** A set of values (an OCapN set; elements may be non-primitive). */
export class PSet {
	constructor(public readonly items: Argument[]) {}
}
export const set = (items: Argument[]): PSet => new PSet(items);

/** An OCapN tagged record: a tag over a value list. */
export class Tagged {
	constructor(public readonly tag: string, public readonly value: Argument[]) {}
}
export const tagged = (tag: string, value: Argument[]): Tagged => new Tagged(tag, value);

// An argument is a native value or a wrapper:
//   bigint (integer), number (float64), boolean, Uint8Array (bytes), string,
//   Sym (symbol), Kw (keyword), null (void), Reference, Argument[] (list),
//   PSet (set), or Tagged.
export type Argument =
	| bigint
	| number
	| boolean
	| Uint8Array
	| string
	| Sym
	| Kw
	| null
	| Reference
	| Argument[]
	| PSet
	| Tagged;

/** A `desc:handoff-give` an answer resolved to (ADR-0009/ADR-0056): the
 * recipient must redeem it against the named exporter rather than read an
 * immediate value. `give` is the verbatim signed envelope to relay unaltered to
 * the exporter (feed it to `Peer.sendWithdrawGift`); `exporterLocator` is the
 * exporter's dialable `ocapn://` URI, or `""` when the give's location is not a
 * flat locator; `recipientKey` is the 32-byte Ed25519 key the give is addressed
 * to. The high-level `Connection` redeems this transparently; a power user
 * driving a bare `Peer` does the dial + `sendWithdrawGift` itself. */
export interface HandoffGive {
	give: Uint8Array;
	exporterLocator: string;
	recipientKey: Uint8Array;
}

export type Resolution =
	| { fulfill: Argument }
	| { break: string }
	| { handoff: HandoffGive };

export type Event =
	| {
		kind: "deliver";
		target: Reference;
		args: Argument[];
		answer: bigint | null;
	}
	| { kind: "resolve"; answer: bigint; resolution: Resolution }
	| { kind: "other"; eventKind: number; frame: Uint8Array };

function isReference(v: unknown): v is Reference {
	return typeof v === "object" && v !== null && "kind" in v &&
		["near", "far", "promise", "sturdy", "broken"].includes(
			(v as Reference).kind,
		);
}

// ── Marshalling (encode) ─────────────────────────────────────────────────────

function writeReference(dv: DataView, off: number, ref: Reference): void {
	let kind = REF_BROKEN, sub = 0, id = 0n;
	switch (ref.kind) {
		case "near":
			kind = REF_NEAR;
			sub = ref.promise ? REF_SUB_PROMISE : REF_SUB_OBJECT;
			id = ref.id;
			break;
		case "far":
			kind = REF_FAR;
			sub = ref.promise ? REF_SUB_PROMISE : REF_SUB_OBJECT;
			id = ref.id;
			break;
		case "promise":
			kind = REF_PROMISE;
			id = ref.answer;
			break;
		default:
			throw new PancakeError(
				UNSUPPORTED_VALUE,
				"sturdy/broken ref not carried on send",
			);
	}
	dv.setUint32(off, kind, true);
	dv.setUint32(off + 4, sub, true);
	dv.setBigUint64(off + 8, id, true);
}

function refStruct(ref: Reference): Uint8Array {
	const buf = new Uint8Array(REF_SIZE);
	writeReference(new DataView(buf.buffer), 0, ref);
	return buf;
}

// Encodes args into one contiguous Uint8Array of ARG_SIZE structs, pushing any
// backing byte/child buffers onto `keep` so they outlive the FFI call.
function encodeArgs(args: Argument[], keep: Uint8Array[]): Uint8Array {
	const buf = new Uint8Array(ARG_SIZE * args.length);
	const dv = new DataView(buf.buffer);
	args.forEach((arg, i) => encodeArg(dv, i * ARG_SIZE, arg, keep));
	keep.push(buf);
	return buf;
}

function encodeArg(
	dv: DataView,
	off: number,
	arg: Argument,
	keep: Uint8Array[],
): void {
	const setBytes = (kind: number, bytes: Uint8Array) => {
		keep.push(bytes);
		dv.setUint32(off, kind, true);
		dv.setBigUint64(off + 24, ffi.pointerOf(bytes), true);
		dv.setBigUint64(off + 32, BigInt(bytes.length), true);
	};
	if (typeof arg === "bigint") {
		if (arg < -(2n ** 63n) || arg >= 2n ** 63n) {
			// Outside the C ABI int64: ARG_BIG_INTEGER carries the canonical decimal
			// digits in bytes/bytes_len and the sign in boolean (ADR-0049).
			const negative = arg < 0n;
			setBytes(
				ARG_BIG_INTEGER,
				new TextEncoder().encode((negative ? -arg : arg).toString()),
			);
			dv.setUint32(off + 4, negative ? 1 : 0, true);
		} else {
			dv.setUint32(off, ARG_INTEGER, true);
			dv.setBigInt64(off + 8, arg, true);
		}
	} else if (typeof arg === "number") {
		dv.setUint32(off, ARG_FLOAT64, true);
		dv.setFloat64(off + 16, arg, true);
	} else if (typeof arg === "boolean") {
		dv.setUint32(off, ARG_BOOLEAN, true);
		dv.setUint32(off + 4, arg ? 1 : 0, true);
	} else if (arg instanceof Uint8Array) {
		setBytes(ARG_BYTES, arg);
	} else if (arg instanceof Sym) {
		setBytes(ARG_SYMBOL, new TextEncoder().encode(arg.value));
	} else if (arg instanceof Kw) {
		setBytes(ARG_KEYWORD, new TextEncoder().encode(arg.value));
	} else if (typeof arg === "string") {
		setBytes(ARG_STRING, new TextEncoder().encode(arg));
	} else if (arg === null) {
		dv.setUint32(off, ARG_VOID, true);
	} else if (isReference(arg)) {
		dv.setUint32(off, ARG_REFERENCE, true);
		writeReference(dv, off + 40, arg);
	} else if (Array.isArray(arg)) {
		writeItems(ARG_LIST, arg);
	} else if (arg instanceof PSet) {
		writeItems(ARG_SET, arg.items);
	} else if (arg instanceof Tagged) {
		setBytes(ARG_TAGGED, new TextEncoder().encode(arg.tag));
		writeItems(ARG_TAGGED, arg.value);
	} else {
		throw new PancakeError(UNSUPPORTED_VALUE, "unsupported argument value");
	}

	function writeItems(kind: number, items: Argument[]): void {
		dv.setUint32(off, kind, true);
		const child = encodeArgs(items, keep);
		dv.setBigUint64(off + 56, ffi.pointerOf(child), true);
		dv.setBigUint64(off + 64, BigInt(items.length), true);
	}
}

// ── Marshalling (decode) ─────────────────────────────────────────────────────

function readReference(view: DataView, off: number): Reference {
	const kind = view.getUint32(off, true);
	const sub = view.getUint32(off + 4, true);
	const id = view.getBigUint64(off + 8, true);
	const promise = sub === REF_SUB_PROMISE;
	switch (kind) {
		case REF_NEAR:
			return { kind: "near", id, promise };
		case REF_FAR:
			return { kind: "far", id, promise };
		case REF_PROMISE:
			return { kind: "promise", answer: id };
		case REF_STURDY:
			return { kind: "sturdy" };
		default:
			return { kind: "broken" };
	}
}

export function readBytes(ptrValue: Ptr, len: bigint): Uint8Array {
	if (ptrValue === NULL || len === 0n) return new Uint8Array(0);
	return new Uint8Array(ffi.readMemory(ptrValue, Number(len)));
}

// Read a (pointer, length) out-pair a borrowed-view accessor filled, copying the
// bytes out before the view's owner can change. Null pointer or zero length → null.
function readViewCopy(
	ptrBuf: Uint8Array,
	lenBuf: Uint8Array,
): Uint8Array | null {
	const len = new DataView(lenBuf.buffer, lenBuf.byteOffset, 8).getBigUint64(
		0,
		true,
	);
	if (len === 0n) return null;
	const ptr = new DataView(ptrBuf.buffer, ptrBuf.byteOffset, 8).getBigUint64(
		0,
		true,
	);
	if (ptr === NULL) return null;
	return readBytes(ptr, len).slice();
}

function readArg(view: DataView, off: number): Argument {
	const kind = view.getUint32(off, true);
	switch (kind) {
		case ARG_INTEGER:
			return view.getBigInt64(off + 8, true);
		case ARG_FLOAT64:
			return view.getFloat64(off + 16, true);
		case ARG_BOOLEAN:
			return view.getUint32(off + 4, true) !== 0;
		case ARG_BYTES:
			return readBytes(
				view.getBigUint64(off + 24, true),
				view.getBigUint64(off + 32, true),
			);
		case ARG_STRING:
			return new TextDecoder().decode(
				readBytes(
					view.getBigUint64(off + 24, true),
					view.getBigUint64(off + 32, true),
				),
			);
		case ARG_SYMBOL:
			return new Sym(
				new TextDecoder().decode(
					readBytes(
						view.getBigUint64(off + 24, true),
						view.getBigUint64(off + 32, true),
					),
				),
			);
		case ARG_REFERENCE:
			return readReference(view, off + 40);
		case ARG_LIST:
			return readArgArray(
				view.getBigUint64(off + 56, true),
				view.getBigUint64(off + 64, true),
			);
		case ARG_SET:
			return new PSet(
				readArgArray(
					view.getBigUint64(off + 56, true),
					view.getBigUint64(off + 64, true),
				),
			);
		case ARG_TAGGED:
			return new Tagged(
				new TextDecoder().decode(
					readBytes(
						view.getBigUint64(off + 24, true),
						view.getBigUint64(off + 32, true),
					),
				),
				readArgArray(
					view.getBigUint64(off + 56, true),
					view.getBigUint64(off + 64, true),
				),
			);
		case ARG_KEYWORD:
			return new Kw(
				new TextDecoder().decode(
					readBytes(
						view.getBigUint64(off + 24, true),
						view.getBigUint64(off + 32, true),
					),
				),
			);
		case ARG_VOID:
			return null;
		case ARG_BIG_INTEGER: {
			// Canonical decimal digits + sign flag back to a native bigint (ADR-0049).
			const digits = new TextDecoder().decode(
				readBytes(
					view.getBigUint64(off + 24, true),
					view.getBigUint64(off + 32, true),
				),
			);
			const magnitude = BigInt(digits);
			return view.getUint32(off + 4, true) !== 0 ? -magnitude : magnitude;
		}
		default:
			throw new PancakeError(
				INVALID_ARGUMENT,
				"unrecognized decoded argument kind",
			);
	}
}

function readArgArray(ptrValue: Ptr, len: bigint): Argument[] {
	if (ptrValue === NULL || len === 0n) return [];
	const view = new DataView(ffi.readMemory(ptrValue, Number(len) * ARG_SIZE));
	const out: Argument[] = [];
	for (let i = 0; i < Number(len); i++) out.push(readArg(view, i * ARG_SIZE));
	return out;
}

// ── Allocation context ───────────────────────────────────────────────────────

// An owned inbound frame the library holds: its bytes and the release
// trampoline must outlive the library's ownership and be reclaimed off-stack.
type PinnedFrame = {
	owned: Uint8Array;
	release: NativeCallback | null;
	retired: boolean;
};

/** A host allocation backend for `Context.withAllocator`. Methods may be called
 * from any thread that touches a handle created in the context. */
export interface HostAllocator {
	/** Return a block of at least `size` bytes aligned to `alignment`. */
	alloc(size: number, alignment: number): Uint8Array;
	/** Release a block previously returned by `alloc`. */
	free(block: Uint8Array, size: number, alignment: number): void;
}

/** An allocation scope. Peers and netlayers created with `Peer.newIn` /
 * `Netlayer.newIn` route every allocation through it. A context must outlive
 * every handle created in it; release it (via `using` / `[Symbol.dispose]`)
 * only after those handles. */
export class Context {
	#raw: Ptr;
	// Kept alive while C holds them so the GC cannot reclaim the trampolines
	// or the live allocation blocks the trampolines manage.
	#allocCb: NativeCallback | null = null;
	#freeCb: NativeCallback | null = null;
	#allocStruct: Uint8Array | null = null;
	#live: Map<bigint, Uint8Array> | null = null;

	private constructor(raw: Ptr) {
		this.#raw = raw;
	}

	/** A context backed by the library-owned allocator. */
	static default(): Context {
		const out = new Uint8Array(8);
		check(s.pancake_context_new(out));
		return new Context(outPointer(out));
	}

	/** A context that routes every allocation through `allocator`. The host
	 * callbacks are kept alive for the context's whole lifetime. */
	static withAllocator(allocator: HostAllocator): Context {
		const ctx = new Context(NULL);
		// pointer value -> the JS-owned block backing it, so free can reclaim it and
		// GC cannot collect a block C still references.
		const live = new Map<bigint, Uint8Array>();
		ctx.#live = live;

		const allocCb = ffi.makeCallback(
			{ parameters: ["pointer", "usize", "usize"], result: "pointer" },
			(_user: Ptr, size: bigint, alignment: bigint): Ptr => {
				const n = Number(size);
				if (n === 0) return NULL;
				const block = allocator.alloc(n, Number(alignment));
				const ptr = ffi.pointerOf(block);
				if (ptr === NULL) return NULL;
				live.set(ptr, block);
				return ptr;
			},
		);
		const freeCb = ffi.makeCallback(
			{ parameters: ["pointer", "pointer", "usize", "usize"], result: "void" },
			(_user: Ptr, ptr: Ptr, size: bigint, alignment: bigint): void => {
				if (ptr === NULL) return;
				const block = live.get(ptr);
				live.delete(ptr);
				if (block !== undefined) {
					allocator.free(block, Number(size), Number(alignment));
				}
			},
		);
		ctx.#allocCb = allocCb;
		ctx.#freeCb = freeCb;

		// PancakeAllocator { alloc fn-ptr; free fn-ptr; user_data } — three pointers.
		const allocStruct = new Uint8Array(24);
		const dv = new DataView(allocStruct.buffer);
		dv.setBigUint64(0, allocCb.pointer, true);
		dv.setBigUint64(8, freeCb.pointer, true);
		dv.setBigUint64(16, 0n, true); // user_data unused; state lives in the closures
		ctx.#allocStruct = allocStruct;

		const out = new Uint8Array(8);
		const rc = s.pancake_context_new_with_allocator(allocStruct, out);
		if (rc !== OK) {
			allocCb.close();
			freeCb.close();
			throw new PancakeError(rc);
		}
		ctx.#raw = outPointer(out);
		return ctx;
	}

	/** Opaque handle, for use by `Peer.newIn` / `Netlayer.newIn`. */
	get pointer(): Ptr {
		return this.#raw;
	}

	release(): void {
		if (this.#raw !== NULL) {
			// Release the context first — it frees its tables through the allocator —
			// then close the callbacks the trampolines borrowed.
			s.pancake_context_release(this.#raw);
			this.#raw = NULL;
		}
		this.#allocCb?.close();
		this.#freeCb?.close();
		this.#allocCb = null;
		this.#freeCb = null;
		this.#allocStruct = null;
		this.#live = null;
	}

	[Symbol.dispose](): void {
		this.release();
	}
}

// ── The Peer ─────────────────────────────────────────────────────────────────

export class Peer {
	#raw: Ptr;

	// Keeps this peer's owned-frame buffers and their release trampolines alive
	// while the library holds them, so the GC cannot reclaim either before the
	// release callback runs. Per-peer so releasing one peer drops only its pins.
	#pinnedFrames = new Set<PinnedFrame>();

	/** An authenticated v1.0 peer in the negotiating state. Use
	 * `Peer.negotiated(...)` to choose another profile or codec. */
	constructor(raw?: Ptr) {
		if (raw !== undefined) {
			this.#raw = raw;
			return;
		}
		const out = new Uint8Array(8);
		check(s.pancake_peer_new(out));
		this.#raw = outPointer(out);
	}

	/** A negotiating peer whose allocations route through `context`; the context must outlive it. */
	static newIn(context: Context): Peer {
		const out = new Uint8Array(8);
		check(s.pancake_peer_new_in(context.pointer, out));
		return new Peer(outPointer(out));
	}

	/** A negotiating peer carrying an out-of-band negotiated profile and codec.
	 * Both ends of a connection must construct with the same pair; the codec
	 * must match the one the connection's endpoint frames with. */
	static negotiated(profile: Profile, codec: Codec = "syrup"): Peer {
		const out = new Uint8Array(8);
		check(
			s.pancake_peer_new_negotiated(profileId(profile), codecId(codec), out),
		);
		return new Peer(outPointer(out));
	}

	/** Context-backed counterpart of `Peer.negotiated`. */
	static negotiatedIn(
		context: Context,
		profile: Profile,
		codec: Codec = "syrup",
	): Peer {
		const out = new Uint8Array(8);
		check(
			s.pancake_peer_new_negotiated_in(
				context.pointer,
				profileId(profile),
				codecId(codec),
				out,
			),
		);
		return new Peer(outPointer(out));
	}

	/** Already-open peer for tests and low-level direct-frame fixtures. */
	static rawOpen(): Peer {
		const out = new Uint8Array(8);
		check(s.pancake_peer_new_raw_open(out));
		return new Peer(outPointer(out));
	}

	/** Context-backed counterpart of `Peer.rawOpen`. */
	static rawOpenIn(context: Context): Peer {
		const out = new Uint8Array(8);
		check(s.pancake_peer_new_raw_open_in(context.pointer, out));
		return new Peer(outPointer(out));
	}

	release(): void {
		if (this.#raw !== NULL) {
			// Releasing the peer frees any owned frames still queued in the library,
			// synchronously invoking each release callback (which retires its pin).
			s.pancake_peer_release(this.#raw);
			this.#raw = NULL;
		}
		// The library no longer holds any of this peer's frames, so reclaim every
		// remaining pin (retired or not) here rather than leaving them dangling
		// until some other peer's next feedOwned sweep runs.
		for (const pin of this.#pinnedFrames) {
			pin.release?.close();
			pin.release = null;
		}
		this.#pinnedFrames.clear();
	}

	[Symbol.dispose](): void {
		this.release();
	}

	registerExport(id: bigint): void {
		check(s.pancake_peer_register_export(this.#raw, id));
	}

	/** Allocate and register the next free export position from the session's
	 * one export allocator — the counter that also mints bootstrap and resolver
	 * exports, so a spawned position can never alias one of them. */
	nextExport(): bigint {
		const out = new Uint8Array(8);
		check(s.pancake_peer_next_export(this.#raw, out));
		return new DataView(out.buffer).getBigUint64(0, true);
	}

	registerImport(id: bigint): void {
		check(s.pancake_peer_register_import(this.#raw, id));
	}

	/** Allocate the next outbound answer position from the session's one answer
	 * allocator — the counter that backs every outbound question, so a
	 * privately-counted answer can never alias a live one. */
	nextAnswer(): bigint {
		const out = new Uint8Array(8);
		check(s.pancake_peer_next_answer(this.#raw, out));
		return new DataView(out.buffer).getBigUint64(0, true);
	}

	/** Sign and queue `op:start-session` from this negotiating peer. The
	 * handshake speaks the profile the peer was constructed with
	 * (`Peer.negotiated("pre-spec")` for upstream OCapN). The 32-byte `seed` is
	 * the session key (the library refuses any other length);
	 * `transport`/`designator` form the locator the partner verifies, so they
	 * must be what it expects — for a Goblins partner, `"tcp"` with
	 * `hintsEmptyFalse` true (Goblins emits the empty hints as the boolean
	 * `#f`). Flush it with `step` + `takeOutbound`, then pump until
	 * `sessionIsOpen`. */
	startSession(opts: {
		transport: string;
		designator: string;
		seed: Uint8Array;
		hintsEmptyFalse?: boolean;
	}): void {
		if (opts.seed.length !== 32) {
			throw new Error("a session seed must be 32 bytes");
		}
		const transport = new TextEncoder().encode(opts.transport);
		const designator = new TextEncoder().encode(opts.designator);
		check(s.pancake_peer_start_session(
			this.#raw,
			ab(transport),
			BigInt(transport.length),
			ab(designator),
			BigInt(designator.length),
			(opts.hintsEmptyFalse ?? true) ? HINTS_EMPTY_FALSE : HINTS_EMPTY_MAP,
			ab(opts.seed),
			BigInt(opts.seed.length),
		));
	}

	/** Whether the authenticated handshake has completed and the session is open for
	 * traffic. Pump the connection and poll this before sending application
	 * messages. */
	sessionIsOpen(): boolean {
		const rc = s.pancake_peer_session_is_open(this.#raw);
		if (rc < 0) throw new PancakeError(rc);
		return rc === 1;
	}

	/** The typed cause of this peer's most recent local dispatch failure, or
	 * null when none has been recorded. The per-call `PancakeError` code names
	 * the failure family; this names the member. Errors thrown by `feed`,
	 * `feedOwned`, and `recvStream` carry it already as `err.abort`. */
	lastAbort(): AbortDetail | null {
		// PancakeLastAbort { domain(0) u32; has_kind(4) u32; kind_name(8);
		//   kind_name_len(16); message(24); message_len(32); error_name(40);
		//   error_name_len(48) } = 56 bytes, LP64.
		const buf = new Uint8Array(56);
		const rc = s.pancake_peer_last_abort(this.#raw, buf);
		if (rc === WOULD_BLOCK) return null;
		check(rc);
		const dv = new DataView(buf.buffer);
		const text = (off: number): string =>
			new TextDecoder().decode(
				readBytes(dv.getBigUint64(off, true), dv.getBigUint64(off + 8, true)),
			);
		const domainNum = dv.getUint32(0, true);
		return {
			domain: domainNum === ABORT_DOMAIN_CODEC
				? "codec"
				: domainNum === ABORT_DOMAIN_SESSION
				? "session"
				: "foreign",
			kind: dv.getUint32(4, true) !== 0 ? text(8) : null,
			message: text(24),
			errorName: text(40),
		};
	}

	// A PancakeError for a refused frame, carrying the typed abort cause. The
	// error is constructed first so it captures the thread-local message before
	// any later call clobbers it.
	#dispatchError(code: number): PancakeError {
		const err = new PancakeError(code);
		try {
			err.abort = this.lastAbort();
		} catch {
			// A peer that cannot report leaves the flat code on its own.
		}
		return err;
	}

	feed(frame: Uint8Array): void {
		const f = new Uint8Array(24);
		const dv = new DataView(f.buffer);
		dv.setBigUint64(0, ffi.pointerOf(frame), true);
		dv.setBigUint64(8, BigInt(frame.length), true);
		dv.setUint32(16, FRAME_SHAPE_BYTE, true);
		const rc = s.pancake_peer_feed_borrowed(this.#raw, f);
		if (rc !== OK) throw this.#dispatchError(rc);
	}

	/** Frame and dispatch one whole frame out of a streaming buffer. `data` is a
	 * borrowed slice of bytes read from the wire, possibly spanning more or less
	 * than one frame. Returns the number of bytes consumed (the length of the one
	 * frame framed and dispatched), `null` when `data` holds only a partial frame
	 * (read more bytes and retry), and throws `PancakeError` on a malformed or
	 * oversized frame. */
	recvStream(data: Uint8Array): number | null {
		const out = new Uint8Array(8);
		const rc = s.pancake_peer_recv_stream(
			this.#raw,
			ab(data),
			BigInt(data.length),
			ab(out),
		);
		if (rc === WOULD_BLOCK) return null;
		if (rc !== OK) throw this.#dispatchError(rc);
		return Number(new DataView(out.buffer).getBigUint64(0, true));
	}

	/** Transfer owned `data` into the inbound queue for the next `step` — no
	 * borrow to keep alive past the call, no copy by the library. On success the
	 * library owns the bytes and frees them via the release callback; on failure
	 * the bytes are reclaimed here before throwing. */
	feedOwned(data: Uint8Array): void {
		// Reclaim trampolines for frames the library already released.
		this.#sweepRetired();

		// Own a private copy so the caller's `data` lifetime is irrelevant.
		const owned = new Uint8Array(data.length);
		owned.set(data);

		// PancakeManagedFrame { bytes(0); len(8); shape(16,+pad); release(24); private(32) } = 40.
		const mf = new Uint8Array(40);
		const dv = new DataView(mf.buffer);
		dv.setBigUint64(0, ffi.pointerOf(owned), true);
		dv.setBigUint64(8, BigInt(owned.length), true);
		dv.setUint32(16, FRAME_SHAPE_BYTE, true);

		// The release callback runs synchronously inside `feed_owned` / `step`.
		// Closing a native callback from inside its own invocation frees the
		// trampoline mid-call (a crash), so the callback only retires the entry; the
		// owning buffer and the trampoline are reclaimed later, off the C stack.
		const pin: PinnedFrame = { owned, release: null, retired: false };
		const cb = ffi.makeCallback(
			{ parameters: ["pointer"], result: "void" },
			(_frame: Ptr): void => {
				pin.retired = true; // library handed ownership back; reclaim off-stack
			},
		);
		pin.release = cb;
		dv.setBigUint64(24, cb.pointer, true);
		dv.setBigUint64(32, 0n, true); // private_data unused; state lives in the closure
		this.#pinnedFrames.add(pin);

		const rc = s.pancake_peer_feed_owned(this.#raw, mf);
		if (rc !== OK) {
			// Not adopted: our descriptor still names our bytes; the library did not
			// call release. Build the error (capturing the typed abort cause), then
			// retire and reclaim ourselves before throwing.
			const err = this.#dispatchError(rc);
			pin.retired = true;
			this.#sweepRetired();
			throw err;
		}
	}

	// Close trampolines and drop buffers for frames the library released. Always
	// runs off the C stack (next feedOwned, the failure path, or release), never
	// from inside a release callback.
	#sweepRetired(): void {
		for (const pin of this.#pinnedFrames) {
			if (pin.retired) {
				pin.release?.close();
				pin.release = null;
				this.#pinnedFrames.delete(pin);
			}
		}
	}

	step(): void {
		check(s.pancake_peer_step(this.#raw));
	}

	/**
	 * Advance to quiescence: encode every pending outbound message, including the
	 * ones a cascading settlement queues (a resolve that drains a projection
	 * whose own resolve fires a listener that queues a deliver), so one
	 * `takeOutbound` sweep drains the whole batch. A single `step` does one unit
	 * of work; this runs them all.
	 */
	stepToIdle(): void {
		check(s.pancake_peer_step_to_idle(this.#raw));
	}

	/** Publish a local capability behind `swissnum`; returns the export id. */
	registerBootstrapCap(swissnum: Uint8Array): bigint {
		const out = new Uint8Array(8);
		check(
			s.pancake_peer_register_bootstrap_cap(
				this.#raw,
				ab(swissnum),
				BigInt(swissnum.length),
				out,
			),
		);
		return new DataView(out.buffer).getBigUint64(0, true);
	}

	/** Queue the canonical bootstrap `fetch` for the capability published
	 * behind `name`, returning the answer position the partner's resolution
	 * arrives on (as a typed resolve event). Registers the bootstrap import and
	 * allocates the answer from the session's own counters. */
	sendBootstrapFetch(name: Uint8Array): bigint {
		const out = new Uint8Array(8);
		check(
			s.pancake_peer_send_bootstrap_fetch(
				this.#raw,
				ab(name),
				BigInt(name.length),
				out,
			),
		);
		return new DataView(out.buffer).getBigUint64(0, true);
	}

	/** Begin enlivening the sturdyref published behind `swissnum` (ADR-0012): the
	 * requester half over bootstrap-fetch with the dedup cache. Returns the
	 * `PancakeEnlivenStart` — a status plus either the cached far reference (read
	 * `importPosition`/`kind`) or the answer to drive. Requires the session to
	 * have negotiated the sturdyref feature and be open. */
	prepareEnliven(
		swissnum: Uint8Array,
	): { status: number; kind: number; answer: bigint; importPosition: bigint } {
		const out = new Uint8Array(24); // { u32 status, u32 kind, u64 answer, u64 import_position }
		check(
			s.pancake_peer_prepare_enliven(
				this.#raw,
				ab(swissnum),
				BigInt(swissnum.length),
				out,
			),
		);
		const view = new DataView(out.buffer);
		return {
			status: view.getUint32(0, true),
			kind: view.getUint32(4, true),
			answer: view.getBigUint64(8, true),
			importPosition: view.getBigUint64(16, true),
		};
	}

	/** Settle a fresh enliven once its bootstrap-fetch resolution arrives: cache
	 * the fulfilled far reference (`importPosition`/`kind`, an `ENLIVEN_OUTCOME_*`
	 * outcome) under `swissnum` so a repeat short-circuits, or clear the in-flight
	 * marker on a break. */
	recordEnlivenment(
		swissnum: Uint8Array,
		outcome: number,
		importPosition: bigint,
		kind: number,
	): void {
		check(s.pancake_peer_record_enlivenment(
			this.#raw,
			ab(swissnum),
			BigInt(swissnum.length),
			outcome,
			importPosition,
			kind,
		));
	}

	/** The codec the session speaks (a `CODEC_*` value), so an opaque `other`
	 * frame drained after a typed-poll refusal can be interpreted. */
	codec(): number {
		const out = new Uint8Array(4);
		check(s.pancake_peer_codec(this.#raw, out));
		return new DataView(out.buffer).getUint32(0, true);
	}

	/** Queue an `op:gc-export` releasing wire-delta counts on imports this peer
	 * holds: `positions[i]` is released by `deltas[i]`. The arrays are parallel
	 * and must be non-empty and the same length. */
	sendGcExport(positions: bigint[], deltas: bigint[]): void {
		if (positions.length !== deltas.length) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"positions and deltas must be the same length",
			);
		}
		const pos = new Uint8Array(8 * positions.length);
		const del = new Uint8Array(8 * deltas.length);
		const posView = new DataView(pos.buffer);
		const delView = new DataView(del.buffer);
		for (let i = 0; i < positions.length; i++) {
			posView.setBigUint64(8 * i, positions[i], true);
			delView.setBigUint64(8 * i, deltas[i], true);
		}
		check(
			s.pancake_peer_send_gc_export(
				this.#raw,
				pos,
				del,
				BigInt(positions.length),
			),
		);
	}

	/** Queue an `op:gc-answer` releasing an answer this peer no longer needs. */
	sendGcAnswer(answer: bigint): void {
		check(s.pancake_peer_send_gc_answer(this.#raw, answer));
	}

	sendDeliver(
		target: Reference,
		args: Argument[],
		answer: bigint | null = null,
	): void {
		const keep: Uint8Array[] = [];
		const t = refStruct(target);
		const argsBuf = encodeArgs(args, keep);
		check(s.pancake_peer_send_deliver(
			this.#raw,
			ab(t),
			args.length ? ab(argsBuf) : new Uint8Array(0),
			BigInt(args.length),
			answer !== null ? 1 : 0,
			answer ?? 0n,
		));
	}

	/** Queue an `op:get` projection (ADR-0050): export a fresh promise at
	 * `answer` resolving to `field` of whatever `receiver` resolves to. `receiver`
	 * is typically a `promise(...)` of an earlier send's answer, so the projection
	 * pipelines ahead of that answer settling. `answer` must come from
	 * `nextAnswer`. */
	sendGet(receiver: Reference, field: string, answer: bigint): void {
		const f = new TextEncoder().encode(field);
		check(
			s.pancake_peer_send_get(
				this.#raw,
				ab(refStruct(receiver)),
				ab(f),
				BigInt(f.length),
				answer,
			),
		);
	}

	/** Queue an `op:index` projection (ADR-0050): like `sendGet` but for List
	 * element `index`. `answer` must come from `nextAnswer`. */
	sendIndex(receiver: Reference, index: bigint, answer: bigint): void {
		check(
			s.pancake_peer_send_index(
				this.#raw,
				ab(refStruct(receiver)),
				index,
				answer,
			),
		);
	}

	/** Queue an `op:untag` projection (ADR-0052): export a fresh promise at
	 * `answer` resolving to the payload of whatever `receiver` resolves to,
	 * requiring a Tagged record whose tag equals `tag`. `answer` must come from
	 * `nextAnswer`. */
	sendUntag(receiver: Reference, tag: string, answer: bigint): void {
		const t = new TextEncoder().encode(tag);
		check(
			s.pancake_peer_send_untag(
				this.#raw,
				ab(refStruct(receiver)),
				ab(t),
				BigInt(t.length),
				answer,
			),
		);
	}

	/** Recipient half of a three-party handoff (ADR-0009/ADR-0056): sign a
	 * `desc:handoff-receive` over the verbatim `give` bytes and queue a
	 * `withdraw-gift` `op:deliver` to the exporter's bootstrap under `answer`.
	 * Requires an open keyed session to the exporter opened with this same 32-byte
	 * `seed` — that session key is what the exporter verifies the receive against.
	 * `handoffCount` is the count of prior withdrawals from this exporter session
	 * (0 for the first, rising monotonically), which the exporter requires to
	 * increase. The withdrawn reference arrives as the resolution of `answer`. */
	sendWithdrawGift(
		give: Uint8Array,
		seed: Uint8Array,
		handoffCount: bigint,
		answer: bigint,
	): void {
		if (seed.length !== 32) throw new Error("a session seed must be 32 bytes");
		check(s.pancake_peer_send_withdraw_gift(
			this.#raw,
			ab(give),
			BigInt(give.length),
			ab(seed),
			BigInt(seed.length),
			handoffCount,
			answer,
		));
	}

	/** The partner's session public key learned from its `op:start-session`, or
	 * null before the handshake half arrives. A gifter reads it on the
	 * to-recipient session for a give's recipient key and on the to-exporter
	 * session to derive the gifter↔exporter session name. The bytes are copied
	 * out of the borrowed view. */
	partnerSessionKey(): Uint8Array | null {
		const ptrBuf = new Uint8Array(8), lenBuf = new Uint8Array(8);
		check(
			s.pancake_peer_partner_session_key(this.#raw, ab(ptrBuf), ab(lenBuf)),
		);
		return readViewCopy(ptrBuf, lenBuf);
	}

	/** The partner's verbatim `<ocapn-peer …>` location-record bytes from its
	 * `op:start-session`, or null when none were captured. A gifter embeds these
	 * as a give's exporter location so a peer comparing locations matches
	 * byte-for-byte. Copied out of the borrowed view. */
	partnerLocatorRaw(): Uint8Array | null {
		const ptrBuf = new Uint8Array(8), lenBuf = new Uint8Array(8);
		check(
			s.pancake_peer_partner_locator_raw(this.#raw, ab(ptrBuf), ab(lenBuf)),
		);
		return readViewCopy(ptrBuf, lenBuf);
	}

	/** Gifter half of a three-party handoff (ADR-0009/ADR-0056): deposit a gift
	 * with this (exporter) session — a `deposit-gift` `op:deliver` to the
	 * exporter's bootstrap carrying `giftId` and the `gifted` reference. The
	 * exporter records the gift; a `withdraw-gift` that arrives first parks until
	 * this deposit lands. Fire-and-forget (no answer). */
	sendDepositGift(giftId: Uint8Array, gifted: Reference): void {
		check(
			s.pancake_peer_send_deposit_gift(
				this.#raw,
				ab(giftId),
				BigInt(giftId.length),
				ab(refStruct(gifted)),
			),
		);
	}

	/** Resolve `answer` (a question a recipient asked this gifter) with a signed
	 * `desc:handoff-give`: an `op:resolve` whose fulfill carries `give` verbatim,
	 * so the recipient redeems it transparently. */
	sendResolveHandoffGive(answer: bigint, give: Uint8Array): void {
		if (give.length === 0) throw new Error("a handoff give must be non-empty");
		check(
			s.pancake_peer_send_resolve_handoff_give(
				this.#raw,
				answer,
				ab(give),
				BigInt(give.length),
			),
		);
	}

	/** Bind a shared gift registry (or null to detach) onto this peer, so inbound
	 * `deposit-gift` / `withdraw-gift` resolve against the shared table the
	 * exporter node shares across its connections. Set before the handshake; the
	 * registry must outlive the peer. Binding-internal. */
	setGiftRegistry(registry: Ptr): void {
		check(s.pancake_peer_set_gift_registry(this.#raw, registry));
	}

	sendResolve(answer: bigint, resolution: Resolution): void {
		if ("handoff" in resolution) {
			// A handoff *give* resolution is authored through `sendResolveHandoffGive`,
			// which carries the verbatim signed bytes; the structured `Resolution` arm
			// has no give bytes to emit, so refuse it here.
			throw new Error(
				"use sendResolveHandoffGive to send a handoff resolution",
			);
		}
		if ("fulfill" in resolution) {
			const keep: Uint8Array[] = [];
			const buf = encodeArgs([resolution.fulfill], keep);
			check(
				s.pancake_peer_send_resolve(
					this.#raw,
					answer,
					RESOLUTION_FULFILL,
					ab(buf),
					new Uint8Array(0),
					0n,
				),
			);
		} else {
			const msg = new TextEncoder().encode(resolution.break);
			check(
				s.pancake_peer_send_resolve(
					this.#raw,
					answer,
					RESOLUTION_BREAK,
					new Uint8Array(0),
					msg,
					BigInt(msg.length),
				),
			);
		}
	}

	takeOutbound(): Uint8Array | null {
		const frame = new Uint8Array(40);
		const rc = s.pancake_peer_take_outbound(this.#raw, frame);
		if (rc === WOULD_BLOCK) return null;
		// Any other non-OK code (e.g. an OOM after the frame was dequeued and freed)
		// is a real failure: throw instead of silently dropping an outbound frame
		// and ending the drain as if the queue were empty.
		check(rc);
		const dv = new DataView(frame.buffer);
		const ptr = dv.getBigUint64(0, true);
		const len = dv.getBigUint64(8, true);
		const out = readBytes(ptr, len).slice();
		s.pancake_managed_frame_release(frame);
		return out;
	}

	poll(): Event | null {
		const kind = s.pancake_peer_peek_event(this.#raw);
		if (kind === EVENT_DELIVER) return this.#pollDeliver();
		if (kind === EVENT_RESOLVE) return this.#pollResolve();
		if (kind === WOULD_BLOCK) return null;
		// A negative code is a peek failure (e.g. a released peer), not an event
		// kind; fail closed rather than fabricating an `other` event with kind 0.
		if (kind < 0) throw new PancakeError(kind);
		return this.#pollOther();
	}

	#pollDeliver(): Event {
		const buf = new Uint8Array(56);
		const rc = s.pancake_peer_poll_event_deliver(this.#raw, buf);
		if (rc === UNSUPPORTED_VALUE) {
			// The typed projection cannot carry this deliver (e.g. a handoff
			// argument). The event stays queued, so drain it as an opaque `other` —
			// throwing here would peek the same event forever.
			return this.#pollOther();
		}
		check(rc);
		const dv = new DataView(buf.buffer);
		const target = readReference(dv, 0);
		const args = readArgArray(
			dv.getBigUint64(16, true),
			dv.getBigUint64(24, true),
		);
		const hasAnswer = dv.getUint32(32, true) !== 0;
		const answer = dv.getBigUint64(40, true);
		s.pancake_deliver_release(buf);
		return { kind: "deliver", target, args, answer: hasAnswer ? answer : null };
	}

	#pollResolve(): Event {
		// PancakeResolve = answer(8) + kind(4,pad to 16) + fulfill(ARG_SIZE) +
		// break_ptr(8) + break_len(8) + handoff PancakeHandoffGive(48) + owner(8).
		const base = 16 + ARG_SIZE;
		const buf = new Uint8Array(base + 16 + 48 + 8);
		const rc = s.pancake_peer_poll_event_resolve(this.#raw, buf);
		if (rc === UNSUPPORTED_VALUE) {
			// Same leave-queued contract as #pollDeliver: drain the refused resolve
			// as an opaque `other` so the loop survives.
			return this.#pollOther();
		}
		check(rc);
		const dv = new DataView(buf.buffer);
		const answer = dv.getBigUint64(0, true);
		const resKind = dv.getUint32(8, true);
		let resolution: Resolution;
		if (resKind === RESOLUTION_FULFILL) {
			resolution = { fulfill: readArg(dv, 16) };
		} else if (resKind === RESOLUTION_HANDOFF) {
			// PancakeHandoffGive starts at base + break_ptr(8) + break_len(8).
			const h = base + 16;
			const give = readBytes(
				dv.getBigUint64(h, true),
				dv.getBigUint64(h + 8, true),
			).slice();
			const locator = new TextDecoder().decode(
				readBytes(dv.getBigUint64(h + 16, true), dv.getBigUint64(h + 24, true)),
			);
			const recipientKey = readBytes(
				dv.getBigUint64(h + 32, true),
				dv.getBigUint64(h + 40, true),
			).slice();
			resolution = {
				handoff: { give, exporterLocator: locator, recipientKey },
			};
		} else {
			const ptr = dv.getBigUint64(base, true);
			const len = dv.getBigUint64(base + 8, true);
			resolution = { break: new TextDecoder().decode(readBytes(ptr, len)) };
		}
		s.pancake_resolve_release(buf);
		return { kind: "resolve", answer, resolution };
	}

	#pollOther(): Event {
		const buf = new Uint8Array(48);
		check(s.pancake_peer_poll_event(this.#raw, buf));
		const dv = new DataView(buf.buffer);
		const eventKind = dv.getUint32(0, true);
		const ptr = dv.getBigUint64(8, true);
		const len = dv.getBigUint64(16, true);
		const frame = readBytes(ptr, len).slice();
		s.pancake_event_release(buf);
		return { kind: "other", eventKind, frame };
	}
}

// ── Actors ───────────────────────────────────────────────────────────────────

// Goblins-shaped actors over the pancake peer, in native TypeScript. This mirrors
// pancake's Zig actor layer (`src/actors/vat.zig`) and the Goblins-faithful Racket
// binding: one unified `Ref` for a local actor or far partner object, one `Vow`
// for a local result or far wire answer, and a peer-aware `Vat` that routes
// between them.
//
// An actor is a TypeScript callback, not a wrapped C vat. Likewise,
// `AsyncConnection` is Deno networking rather than a foreign reactor. The vat
// holds local actors, each a closure over a method verb and its arguments. When it
// is bound to a peer, it routes eventual-sends to far objects over the wire. A
// leading `Sym` argument is the method verb, matching Goblins's
// `($ obj 'method arg ...)`; the rest are the call's arguments.
//
// Two verbs match Goblins and the Zig actor layer:
//   * `call` is the synchronous near-call (`$`). It runs a local actor's handler
//     immediately and returns its value. A far ref throws; near-call is local only.
//   * `send` is the eventual send (`<-`). It is location-transparent: a local
//     target queues a turn for `drive`, and a far target sends an `op:deliver`
//     over the bound peer with a fresh answer. Either way it returns a `Vow` you
//     observe with `on`.

/** An actor behavior: handle a `(verb, args)` call, returning a reply. Throw to
 * signal a broken resolution; the thrown error's message becomes the break. */
export type Behavior = (verb: string, args: Argument[]) => Argument;

/** An object-capability membrane (ADR-0064): a forwarding proxy over `target`
 * (local or far). A caretaker forwards until revoked, then breaks every call; an
 * attenuator forwards only its allow-listed verbs and breaks the rest. The proxy
 * is an ordinary export — a partner delivers to it like any other capability. */
interface Membrane {
	target: VatRef;
	policy:
		| { kind: "caretaker"; live: boolean }
		| { kind: "attenuate"; verbs: string[] };
}

/** A reference the vat can eventual-send to, wherever the object lives. A
 * `LocalRef` names an actor in this vat; a `FarRef` wraps a `far` reference to
 * a partner-hosted object the bound peer holds as an import. */
type VatRef = LocalRef | FarRef;

/** An actor living in this vat. `call` and `send` run its turns here. */
export class LocalRef {
	readonly location = "local" as const;
	constructor(public readonly id: number) {}
}

/** A partner-hosted object the bound peer holds as an import. `send` routes to
 * it as an `op:deliver`; `call` (near) is illegal. */
export class FarRef {
	readonly location = "far" as const;
	constructor(public readonly reference: Reference) {}
}

/** How a vow settled. */
export type Settlement = { fulfilled: Argument } | { broken: string };

/** A one-shot listener on a vow: `onFulfilled` runs with the value on a
 * fulfill, `onBroken` with the message on a break. */
export type VowListener = {
	onFulfilled?: (value: Argument) => void;
	onBroken?: (message: string) => void;
};

/** A handle to the eventual result of a `Vat.send`. A `LocalVow` settles during
 * `drive`; a `FarVow` settles when the peer surfaces the partner's resolution
 * event and the application hands it to `serve`. */
export type Vow = LocalVow | FarVow;

// A vow is awaitable: `await vat.send(...)` resolves with the value, or rejects
// with a typed `VowBroken` carrying the break message. The promise is registered
// lazily, the first time the vow is awaited (or `.then`'d), so a fire-and-forget
// send that no one observes settles into nothing — no stray unhandled rejection.
// `vat.on` is still here for the callback style.
function settle(vat: Vat, vow: Vow): Promise<Argument> {
	return new Promise<Argument>((resolve, reject) => {
		vat.on(
			vow,
			(value) => resolve(value),
			(message) => reject(new VowBroken(message)),
		);
	});
}

/** The result of a local send; settled by `Vat.drive`. Await it for the value,
 * or observe it with `Vat.on`. */
export class LocalVow {
	readonly location = "local" as const;
	constructor(public readonly id: number, private readonly vat: Vat) {}
	then<R1 = Argument, R2 = never>(
		onFulfilled?: ((value: Argument) => R1 | PromiseLike<R1>) | null,
		onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
	): Promise<R1 | R2> {
		return settle(this.vat, this).then(onFulfilled, onRejected);
	}
}

/** The result of a far send, keyed by the outbound answer position the partner
 * resolves. Await it for the value, or observe it with `Vat.on`. */
export class FarVow {
	readonly location = "far" as const;
	constructor(public readonly answer: bigint, private readonly vat: Vat) {}
	then<R1 = Argument, R2 = never>(
		onFulfilled?: ((value: Argument) => R1 | PromiseLike<R1>) | null,
		onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
	): Promise<R1 | R2> {
		return settle(this.vat, this).then(onFulfilled, onRejected);
	}
}

/** The handle `Connection.send` hands back: the eventual result of one
 * eventual-send, and — the point of promise pipelining (ADR-0007) — a target
 * you can `send` to before it resolves.
 *
 * It is a real `Promise<AppValue>` subclass, so `await conn.send(...)`,
 * `Promise.all([...])`, and `instanceof Promise` all work natively. Pass it
 * *unawaited* as the `target` of a later `send` to address the object the answer
 * will resolve to — the dependent call rides a `desc:answer` deliver and the
 * partner queues it until the answer settles, so a `create → use` chain costs
 * one round trip:
 *
 *     const task = conn.send(root, "create", ["x"]);  // not awaited
 *     conn.send(task, "assign", ["alice"]);            // pipelined at the answer
 *     const status = await conn.send(task, "status");  // settles the chain
 *
 * The send is issued (queued) when this is created, but the bytes leave the wire
 * only when it — or any send pipelined behind it — is first observed (awaited,
 * `then`, `catch`, or `finally`). A handle that is never observed is a
 * fire-and-forget send; prefer `Connection.tell` for that. Because the send is
 * lazy, an unawaited anchor whose far answer *breaks* never surfaces that
 * rejection — no flush, no settlement — so it cannot raise an unhandled
 * rejection. `answer` is the outbound answer position a far send resolves, or
 * `null` for a local send (not pipelinable).
 *
 * The projection verbs `get`/`index`/`untag` (ADR-0050/ADR-0052) pipeline a
 * field, element, or untag access *at the answer*, before it resolves: each
 * returns a new `RemotePromise` for the projected value, addressed at this
 * answer, so `task.get("rows").index(0)` costs no extra round trip. */
export class RemotePromise extends Promise<AppValue> {
	readonly #begin: () => Promise<AppValue>;
	#started = false;
	readonly #resolve: (value: AppValue | PromiseLike<AppValue>) => void;
	readonly #reject: (reason?: unknown) => void;
	// Issues a projection op (get/index/untag) at this answer and returns the new
	// RemotePromise; null for a local-send handle (no answer to project against).
	readonly #project:
		| ((op: "get" | "index" | "untag", key: string | bigint) => RemotePromise)
		| null;

	constructor(
		public readonly answer: bigint | null,
		begin: () => Promise<AppValue>,
		project:
			| ((op: "get" | "index" | "untag", key: string | bigint) => RemotePromise)
			| null = null,
	) {
		// The executor only captures the settlement functions; it runs no flush, so
		// construction is side-effect-free and the send stays lazy.
		let resolve!: (value: AppValue | PromiseLike<AppValue>) => void;
		let reject!: (reason?: unknown) => void;
		super((res, rej) => {
			resolve = res;
			reject = rej;
		});
		this.#begin = begin;
		this.#resolve = resolve;
		this.#reject = reject;
		this.#project = project;
	}

	#projectOp(
		op: "get" | "index" | "untag",
		key: string | bigint,
	): RemotePromise {
		if (this.#project === null) {
			throw new Error(
				"cannot project a local-send promise; await it for a value",
			);
		}
		return this.#project(op, key);
	}

	/** Pipeline an `op:get` for `field` at this answer (ADR-0050): a new
	 * `RemotePromise` for the Struct field of whatever this resolves to. */
	get(field: string): RemotePromise {
		return this.#projectOp("get", field);
	}

	/** Pipeline an `op:index` for `i` at this answer (ADR-0050): a new
	 * `RemotePromise` for the List element of whatever this resolves to. */
	index(i: number | bigint): RemotePromise {
		return this.#projectOp("index", BigInt(i));
	}

	/** Pipeline an `op:untag` for `tag` at this answer (ADR-0052): a new
	 * `RemotePromise` for the payload of whatever this resolves to, which must be
	 * a Tagged record whose tag equals `tag`. */
	untag(tag: string): RemotePromise {
		return this.#projectOp("untag", tag);
	}

	// First observation issues the send's flush + reply wait, exactly once; the
	// native promise caches the settlement so repeated awaits share it. `catch`
	// and `finally` are inherited from `Promise` and delegate to this `then`, so
	// observing through any of them triggers the send.
	override then<R1 = AppValue, R2 = never>(
		onFulfilled?: ((value: AppValue) => R1 | PromiseLike<R1>) | null,
		onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
	): Promise<R1 | R2> {
		if (!this.#started) {
			this.#started = true;
			// `begin` already lifted the wire value to an `AppValue` (connection-aware,
			// so a redeemed handoff ref carries its exporter home).
			this.#begin().then(this.#resolve, this.#reject);
		}
		return super.then(onFulfilled, onRejected);
	}

	// Required, not decorative. `then`/`catch`/`finally` build their result
	// promise via `this.constructor[Symbol.species]`; without this, the platform
	// would call `new RemotePromise(executor)` against the `(answer, begin)`
	// constructor and every chained reaction would break. Returning `Promise`
	// also keeps derived promises plain (no per-hop subclass cost).
	static override get [Symbol.species](): PromiseConstructor {
		return Promise;
	}

	override get [Symbol.toStringTag](): string {
		return "RemotePromise";
	}
}

/** A turn loop over local and far actors. A pure-local vat (`new Vat()`) drives
 * local actors only; a peer-bound vat (`new Vat(peer)`) also routes far sends
 * over the wire and hosts published actors for inbound delivery via `serve`.
 *
 * The vat owns no I/O and no scheduler; you drive it. Around `serve`, callers
 * feed frames to the peer, step it, take outbound frames, and hand surfaced
 * events back to the vat. */
export class Vat {
	#peer: Peer | null;
	#actors = new Map<number, Behavior>();
	#queue: Array<{ id: number; verb: string; args: Argument[]; vow: number }> = [];
	#localListeners = new Map<number, VowListener>();
	#farListeners = new Map<bigint, VowListener>(); // outbound answer -> listener
	// A far answer can settle before its handle is ever observed: a sibling op on
	// the same connection (a pipelined projection's flush, say) pumps the inbound
	// loop, so the source answer's resolve can land before anyone awaits it. Stash
	// that resolution here so a late `on` settles from it instead of hanging.
	#farResolutions = new Map<bigint, Settlement>(); // outbound answer -> settled
	#exports = new Map<bigint, number>(); // export id -> local actor id
	// Membrane (caretaker/attenuator) for each local id that hosts one, instead
	// of an ordinary behavior (ADR-0064).
	#membranes = new Map<number, Membrane>();
	#nextActor = 1;
	#nextVow = 1;
	// An optional hook the owning Connection installs: when a published actor
	// fulfills an inbound answer with a capability that lives on a *different*
	// connection (the gifter half of a three-party handoff), the Connection takes
	// over resolving the answer asynchronously — deposit the gift and resolve with
	// a signed give — and this returns true so the vat does not also send a plain
	// (and wrong, cross-connection) fulfill. Null for a vat with no router above.
	#resolveInterceptor:
		| ((answer: bigint, fulfilled: Argument) => boolean)
		| null = null;

	/** A pure-local vat, or, when given a peer, one that routes far sends and hosts
	 * published actors. */
	constructor(peer?: Peer) {
		this.#peer = peer ?? null;
	}

	/** Install the foreign-home resolve interceptor (binding-internal; the
	 * `Connection` sets it to originate three-party handoffs). */
	setResolveInterceptor(
		fn: (answer: bigint, fulfilled: Argument) => boolean,
	): void {
		this.#resolveInterceptor = fn;
	}

	/** The bound peer, or null for a pure-local vat. */
	get peer(): Peer | null {
		return this.#peer;
	}

	/** Spawn a local actor, returning a `LocalRef`. */
	spawn(behavior: Behavior): LocalRef {
		const id = this.#nextActor++;
		this.#actors.set(id, behavior);
		return new LocalRef(id);
	}

	/** The synchronous near-call (`$`): run `ref`'s handler now and return its
	 * value. Legal only for a local ref — a far ref must be reached with `send`.
	 * Throws if `ref` names no actor; an actor that throws propagates here. */
	call(ref: VatRef, verb: string, args: Argument[]): Argument {
		if (ref.location === "far") {
			throw new Error("cannot near-call a far ref; use send");
		}
		return this.#callLocal(ref.id, verb, args);
	}

	#callLocal(id: number, verb: string, args: Argument[]): Argument {
		const behavior = this.#actors.get(id);
		if (behavior === undefined) throw new Error(`no such actor: ${id}`);
		return behavior(verb, args);
	}

	/** The eventual send (`<-`): location-transparent. A local target queues a
	 * turn for `drive`; a far target sends an `op:deliver` over the bound peer
	 * with a fresh answer (a leading symbol carries the verb, matching Goblins's
	 * `($ obj 'method …)`). Returns a `Vow` for the result. */
	send(ref: VatRef, verb: string, args: Argument[]): Vow {
		if (ref.location === "local") {
			const vow = this.#nextVow++;
			this.#queue.push({ id: ref.id, verb, args, vow });
			return new LocalVow(vow, this);
		}
		const peer = this.#peer;
		if (peer === null) {
			throw new Error("this vat has no peer; far sends need new Vat(peer)");
		}
		const answer = peer.nextAnswer();
		const payload: Argument[] = verb.length > 0 ? [new Sym(verb), ...args] : args;
		peer.sendDeliver(ref.reference, payload, answer);
		return new FarVow(answer, this);
	}

	/** Register a one-shot listener on `vow`. A local vow fires during `drive`; a
	 * far vow fires when `serve` dispatches the matching typed resolve event. */
	on(
		vow: Vow,
		onFulfilled?: (value: Argument) => void,
		onBroken?: (message: string) => void,
	): void {
		const listener: VowListener = { onFulfilled, onBroken };
		if (vow.location === "local") {
			this.#localListeners.set(vow.id, listener);
		} else {
			// If the answer already settled (observed late, after a sibling op pumped
			// the loop), fire from the stash now instead of waiting for a resolve that
			// has already come and gone.
			const settled = this.#farResolutions.get(vow.answer);
			if (settled !== undefined) {
				this.#farResolutions.delete(vow.answer);
				fire(listener, settled);
				return;
			}
			this.#farListeners.set(vow.answer, listener);
		}
	}

	/** Break every outstanding far vow with `message`, firing each listener's
	 * `onBroken`. A far vow settles only when the peer surfaces the partner's
	 * resolution, so once the connection is gone those replies can never come.
	 * The connection driver calls this on disconnect, so an awaiting `send` rejects
	 * instead of hanging forever. Local vows are untouched: they settle
	 * synchronously in `drive` and never wait on the wire. */
	breakFarVows(message: string): void {
		// Snapshot then clear before firing: a listener may react by registering
		// another far vow, and mutating the map mid-iteration would lose it.
		const pending = [...this.#farListeners.values()];
		this.#farListeners.clear();
		for (const listener of pending) listener.onBroken?.(message);
	}

	/** Run queued local eventual-sends to quiescence, settling each vow with the
	 * handler's value (or a break on a thrown error) and firing its listener.
	 * Turns a turn queues run in the same drive (FIFO). */
	drive(): void {
		while (this.#queue.length > 0) {
			const queued = this.#queue.shift()!;
			const settlement = this.#runLocal(queued.id, queued.verb, queued.args);
			this.#settleLocal(queued.vow, settlement);
		}
	}

	#runLocal(id: number, verb: string, args: Argument[]): Settlement {
		try {
			return { fulfilled: this.#callLocal(id, verb, args) };
		} catch (err) {
			return { broken: err instanceof Error ? err.message : String(err) };
		}
	}

	#settleLocal(vowId: number, settlement: Settlement): void {
		const listener = this.#localListeners.get(vowId);
		if (listener === undefined) return;
		this.#localListeners.delete(vowId); // one-shot
		fire(listener, settlement);
	}

	/** Publish a local actor at export position `exportId` so a partner's
	 * deliveries to it run the actor (dispatched by `serve`). Requires a bound
	 * peer. Returns the published `LocalRef`. */
	publish(exportId: bigint | number, behavior: Behavior): LocalRef {
		const peer = this.#peer;
		if (peer === null) {
			throw new Error("this vat has no peer; publish needs new Vat(peer)");
		}
		const id = BigInt(exportId);
		const ref = this.spawn(behavior);
		peer.registerExport(id);
		this.#exports.set(id, ref.id);
		return ref;
	}

	/** Publish a caretaker membrane at `exportId` forwarding to `target` (local or
	 * far, ADR-0064): deliveries forward to `target` until `revokeMembrane`, then
	 * break with `Revoked`. Returns the proxy `LocalRef`. */
	publishCaretaker(exportId: bigint | number, target: VatRef): LocalRef {
		return this.#publishMembrane(exportId, {
			target,
			policy: { kind: "caretaker", live: true },
		});
	}

	/** Publish an attenuator membrane at `exportId` forwarding to `target`
	 * (ADR-0064): a delivery whose verb is in `verbs` forwards; any other breaks
	 * with `Attenuated`. Returns the proxy `LocalRef`. */
	publishAttenuator(
		exportId: bigint | number,
		target: VatRef,
		verbs: string[],
	): LocalRef {
		return this.#publishMembrane(exportId, {
			target,
			policy: { kind: "attenuate", verbs },
		});
	}

	#publishMembrane(exportId: bigint | number, membrane: Membrane): LocalRef {
		const peer = this.#peer;
		if (peer === null) {
			throw new Error("this vat has no peer; a membrane needs new Vat(peer)");
		}
		const id = BigInt(exportId);
		const localId = this.#nextActor++;
		peer.registerExport(id);
		this.#exports.set(id, localId);
		this.#membranes.set(localId, membrane);
		return new LocalRef(localId);
	}

	/** Revoke the caretaker membrane published at `exportId`: deliveries to it
	 * then break with `Revoked`. A no-op for an unknown position or a
	 * non-caretaker membrane. */
	revokeMembrane(exportId: bigint | number): void {
		const localId = this.#exports.get(BigInt(exportId));
		if (localId === undefined) return;
		const membrane = this.#membranes.get(localId);
		if (membrane?.policy.kind === "caretaker") membrane.policy.live = false;
	}

	// Dispatch an inbound deliver that landed on a membrane proxy: refuse it
	// (revoked/attenuated) or forward it. A local target near-calls and resolves
	// synchronously; a far target eventual-sends and defers the answer onto the
	// forwarded send — the forward listener resolves it once that send settles
	// (ADR-0064's `Turn.forward`).
	#serveMembrane(
		localId: number,
		verb: string,
		rest: Argument[],
		answer: bigint | null,
	): void {
		const membrane = this.#membranes.get(localId)!;
		const peer = this.#peer!;
		const refusal = membrane.policy.kind === "caretaker"
			? (membrane.policy.live ? null : "Revoked")
			: (membrane.policy.verbs.includes(verb) ? null : "Attenuated");
		if (refusal !== null) {
			if (answer !== null) peer.sendResolve(answer, { break: refusal });
			return;
		}

		const target = membrane.target;
		if (target.location === "local") {
			const settlement = this.#runLocal(target.id, verb, rest);
			if (answer !== null) {
				if ("fulfilled" in settlement) {
					peer.sendResolve(answer, { fulfill: settlement.fulfilled });
				} else {
					peer.sendResolve(answer, { break: settlement.broken });
				}
			}
		} else {
			const vow = this.send(target, verb, rest);
			if (answer !== null) {
				const original = answer;
				this.on(
					vow,
					(value) => peer.sendResolve(original, { fulfill: value }),
					(message) => peer.sendResolve(original, { break: message }),
				);
			}
		}
	}

	/** Dispatch one inbound peer event. A deliver to a published export runs its
	 * actor (the leading `Sym` is the verb) and resolves the answer; a resolve
	 * for a pending far vow fires its listener. Returns whether the event
	 * belonged to this vat; `false` means it is not ours and the caller handles
	 * it. */
	serve(event: Event): boolean {
		if (event.kind === "deliver") return this.#serveDeliver(event);
		if (event.kind === "resolve") return this.#serveResolve(event);
		return false;
	}

	#serveDeliver(event: Event & { kind: "deliver" }): boolean {
		if (event.target.kind !== "near") return false;
		const actorId = this.#exports.get(event.target.id);
		if (actorId === undefined) return false;

		// A leading symbol is the method verb; the rest are its arguments.
		let verb = "";
		let rest = event.args;
		if (event.args.length > 0 && event.args[0] instanceof Sym) {
			verb = event.args[0].value;
			rest = event.args.slice(1);
		}

		// A membrane proxy forwards (or refuses) rather than running a behavior.
		if (this.#membranes.has(actorId)) {
			this.#serveMembrane(actorId, verb, rest, event.answer);
			return true;
		}

		const peer = this.#peer;
		if (event.answer !== null && peer !== null) {
			const settlement = this.#runLocal(actorId, verb, rest);
			if ("fulfilled" in settlement) {
				// A capability whose home is another connection cannot be resolved as a
				// plain fulfill here; let the router above originate a handoff instead.
				if (!this.#resolveInterceptor?.(event.answer, settlement.fulfilled)) {
					peer.sendResolve(event.answer, { fulfill: settlement.fulfilled });
				}
			} else {
				peer.sendResolve(event.answer, { break: settlement.broken });
			}
		} else {
			// A deliver-only send still runs the actor for its effects.
			this.#callLocal(actorId, verb, rest);
		}
		return true;
	}

	#serveResolve(event: Event & { kind: "resolve" }): boolean {
		let settlement: Settlement;
		if ("fulfill" in event.resolution) {
			settlement = { fulfilled: event.resolution.fulfill };
		} else if ("handoff" in event.resolution) {
			// A handoff give reaches the vat only when no dial-capable layer above it
			// intercepted it first (the `Connection` redeems transparently). The vat
			// cannot dial, so break the vow rather than hang it forever.
			settlement = { broken: "handoff give arrived at a vat with no redeemer" };
		} else {
			settlement = { broken: event.resolution.break };
		}
		const listener = this.#farListeners.get(event.answer);
		if (listener === undefined) {
			// No one is awaiting this answer yet. It may be observed later (a source
			// handle awaited after its projection pumped the loop), so stash the
			// resolution for a late `on`. Still ours to claim — return true.
			this.#farResolutions.set(event.answer, settlement);
			return true;
		}
		this.#farListeners.delete(event.answer); // one-shot
		fire(listener, settlement);
		return true;
	}
}

function fire(listener: VowListener, settlement: Settlement): void {
	if ("fulfilled" in settlement) {
		listener.onFulfilled?.(settlement.fulfilled);
	} else {
		listener.onBroken?.(settlement.broken);
	}
}

// ── Binding-internal seam ────────────────────────────────────────────────────
//
// These helpers are shared across the binding's modules — the transport modules
// (`./transport/tcp.ts`, `./transport/inproc.ts`, and the `@pancake/iroh`
// package) marshal frames through the same pointer and byte plumbing the core
// uses. They are exported for those siblings, not for applications.

export function outPointer(buf: Uint8Array): Ptr {
	return new DataView(buf.buffer).getBigUint64(0, true);
}

/** Release a managed frame the core ABI filled (a transport module's blocking
 * `readFrame` returns one). Part of the binding-internal seam. */
export function releaseManagedFrame(mf: Uint8Array): void {
	s.pancake_managed_frame_release(ab(mf));
}

// The runtime socket seam, re-exported for transports and dogfood tests that
// drive a raw connection (the keyed handshake, an unframed shuttle). An
// application uses `connect` / `listen`, not these.
export type { NetConn, NetListener } from "./internal/ffi/runtime.ts";

/** Dial a raw TCP socket through the host runtime. Binding-internal. */
export function connectTcp(host: string, port: number): Promise<NetConn> {
	return net.connect(host, port);
}

/** Bind a raw TCP listener through the host runtime. Binding-internal. */
export function listenTcp(host: string, port: number): Promise<NetListener> {
	return net.listen(host, port);
}

// The blocking transports are their own modules beside this one:
// `./transport/tcp.ts` rides `libpancake_net_transport_tcp`,
// `./transport/inproc.ts` rides `libpancake_net_transport_inproc`, and the
// optional `@pancake/iroh` package rides the `libpancake_net_transport_iroh`
// companion (ADR-0055 keeps the Rust sidecar out of the pure-Zig archives so the
// gate stays hermetic and this core stays pure Zig). The core reaches
// `@pancake/iroh` only through `connect` for an `iroh` locator — a lazy
// `import()` of that package, so it never hard-depends on the iroh artifact.
// Each transport plugs into the binding-internal seam above plus the exported
// `FramePump`/`KeyedLocator` contract, `AsyncConnection.fromPump`, and
// `Connection.fromAsync`.

// ── Native async I/O over the runtime's sockets ──────────────────────────────

/** The locator a keyed `op:start-session` signs for a transport. A dialer signs
 * an empty designator (its identity is the random session key); a listener signs
 * its own dialable designator. */
export interface KeyedLocator {
	transport: string;
	designator: string;
	hintsEmptyFalse?: boolean;
}

/** What the `AsyncConnection` pump needs of a transport. A frame is one
 * complete, codec-self-delimited CapTP message — the same unit `Peer.takeOutbound`
 * yields and `Peer.feed`/`recvStream` consume — so a transport differs only in
 * how it moves that unit, never in the pump that drives the peer over it. TCP
 * buffers raw bytes and lets the peer frame them; iroh sources whole frames
 * through the sidecar FFI. */
export interface FramePump {
	/** The locator a keyed `op:start-session` signs for this transport. */
	locator(): KeyedLocator;
	/** Dispatch one already-buffered inbound frame into `peer` without blocking;
	 * true when one was dispatched (the caller loops). A stream transport frames
	 * its byte buffer here; a transport that delivers exactly one frame per
	 * `receive` returns false. */
	dispatchBuffered(peer: Peer): boolean;
	/** Block for more inbound and dispatch it into `peer`; resolve false on a
	 * clean end of stream. */
	receive(peer: Peer): Promise<boolean>;
	/** Write one whole outbound frame to the wire. */
	writeFrame(frame: Uint8Array): Promise<void>;
	close(): void;
}

/** The TCP pump: a runtime `NetConn` plus the inbound byte buffer the peer
 * frames. The keyed locator signs the socket's own `host:port`, which a Goblins
 * partner accepts as a true `tcp` locator. */
class TcpPump implements FramePump {
	#conn: NetConn;
	// Inbound bytes read from the wire but not yet framed into whole frames.
	#inbox: Uint8Array = new Uint8Array(0);

	constructor(conn: NetConn) {
		this.#conn = conn;
	}

	locator(): KeyedLocator {
		const la = this.#conn.localAddr();
		return {
			transport: "tcp",
			designator: `${la.hostname}:${la.port}`,
			hintsEmptyFalse: true,
		};
	}

	dispatchBuffered(peer: Peer): boolean {
		if (this.#inbox.length === 0) return false;
		const consumed = peer.recvStream(this.#inbox);
		if (consumed === null) return false;
		this.#inbox = this.#inbox.subarray(consumed);
		return true;
	}

	async receive(_peer: Peer): Promise<boolean> {
		const chunk = await this.#conn.read();
		if (chunk === null) return false; // clean EOF
		this.#appendInbox(chunk);
		return true;
	}

	async writeFrame(frame: Uint8Array): Promise<void> {
		await this.#conn.write(frame);
	}

	#appendInbox(bytes: Uint8Array): void {
		if (this.#inbox.length === 0) {
			// Copy out of the read buffer so the next read can reuse it.
			this.#inbox = bytes.slice();
			return;
		}
		const grown = new Uint8Array(this.#inbox.length + bytes.length);
		grown.set(this.#inbox, 0);
		grown.set(bytes, this.#inbox.length);
		this.#inbox = grown;
	}

	close(): void {
		this.#conn.close();
	}
}

/** An OCapN/CapTP peer driven asynchronously over a transport `FramePump`.
 *
 * The sync `Peer` is sans-io: it never blocks and never owns a socket. This
 * class owns one peer and one pump and drives the peer over it — sources whole
 * frames (or raw bytes the peer frames), lets the peer dispatch them, writes the
 * peer's outbound frames back, and surfaces typed events. The pump is the only
 * thing that differs between transports (TCP today, iroh through the sidecar);
 * the drive loop is identical. One `AsyncConnection` owns one peer, so it lives
 * on one task; the peer is a single-owner state machine, never shared across
 * tasks. This is the pump layer `Connection` builds on; an application usually
 * holds a `Connection`. */
export class AsyncConnection {
	#peer: Peer;
	#pump: FramePump;
	#vat: Vat | null = null;
	// Serializes outbound pumps. `#pumpOutbound` runs from several async callers
	// (a `send`/`fetch` flush, the inbound iterator's re-pump, a finalizer-driven
	// GC release) that could otherwise interleave their `writeFrame` awaits and
	// splice two messages' bytes on the one socket. Chaining each pump behind the
	// last keeps every frame whole and in submission order.
	#writing: Promise<void> = Promise.resolve();

	private constructor(peer: Peer, pump: FramePump) {
		this.#peer = peer;
		this.#pump = pump;
	}

	/** Connect to `hostname:port` and complete the keyed OCapN handshake. */
	static async connect(
		hostname: string,
		port: number,
	): Promise<AsyncConnection> {
		const conn = await net.connect(hostname, port);
		const ac = new AsyncConnection(new Peer(), new TcpPump(conn));
		await openKeyedSession(ac);
		return ac;
	}

	/** Wrap an already-connected socket and a peer you have configured (registered
	 * exports/imports, bootstrap caps, …). */
	static fromConn(peer: Peer, conn: NetConn): AsyncConnection {
		return new AsyncConnection(peer, new TcpPump(conn));
	}

	/** Wrap a peer and an already-built frame pump — the transport-neutral
	 * constructor the iroh path uses. */
	static fromPump(peer: Peer, pump: FramePump): AsyncConnection {
		return new AsyncConnection(peer, pump);
	}

	/** The locator this connection's transport signs in its keyed start-session. */
	get locator(): KeyedLocator {
		return this.#pump.locator();
	}

	/** Borrow the owned peer — e.g. to register exports/imports before driving. */
	get peer(): Peer {
		return this.#peer;
	}

	/** A `Vat` bound to this connection's peer, created once and cached. This is
	 * how you drive actors over the wire: `publish` an actor to host it, `send` to
	 * a `FarRef` to call a remote object, and hand each event from `nextEvent` to
	 * `vat.serve`. The vat enqueues on the peer; `nextEvent` and `flush` move the
	 * bytes. */
	vat(): Vat {
		if (this.#vat === null) this.#vat = new Vat(this.#peer);
		return this.#vat;
	}

	/** Queue a call to `target` and flush it to the wire. `answer` requests a reply. */
	async sendDeliver(
		target: Reference,
		args: Argument[],
		answer: bigint | null = null,
	): Promise<void> {
		this.#peer.sendDeliver(target, args, answer);
		await this.#pumpOutbound();
	}

	/** Queue a reply settling `answer` and flush it to the wire. */
	async sendResolve(answer: bigint, resolution: Resolution): Promise<void> {
		this.#peer.sendResolve(answer, resolution);
		await this.#pumpOutbound();
	}

	/** Flush whatever is already queued on the peer's outbound to the wire.
	 *
	 * The peer is sans-io: a `Vat.send` (or any direct `peer.sendDeliver` /
	 * `sendResolve`) only enqueues; the bytes leave only when something pumps the
	 * peer. `nextEvent` pumps at the top of its loop, so a reply queued while
	 * serving an inbound event leaves on the next turn. But work a *different*
	 * task queues onto this peer — a server pushing a broadcast to a subscriber
	 * whose own task is parked in `read()` — would otherwise sit unsent until that
	 * task happened to wake. Call `flush` right after such a cross-task `Vat.send`
	 * to put the bytes on the wire now. */
	async flush(): Promise<void> {
		await this.#pumpOutbound();
	}

	/** The connection as a native stream of events: `for await (const event of
	 * conn) …`. It yields each event the peer surfaces and ends on a clean
	 * disconnect, so the idiomatic receive loop is just a `for await`. (It is the
	 * same thing as looping on `nextEvent` until it returns null.) */
	async *[Symbol.asyncIterator](): AsyncGenerator<Event> {
		let event = await this.nextEvent();
		while (event !== null) {
			yield event;
			event = await this.nextEvent();
		}
	}

	/** Await the next application event, driving the transport as needed. Returns
	 * `null` on a clean end of stream. */
	async nextEvent(): Promise<Event | null> {
		for (;;) {
			// A surfaced event takes priority.
			let ev = this.#peer.poll();
			if (ev) return ev;
			// Flush anything the last dispatch queued (replies, aborts). Stepping to
			// idle settles answers, which drains their pipelined calls and
			// projections into *fresh* events, so re-poll before blocking on the
			// wire — otherwise those drained events sit unseen until the partner
			// happens to send again, hanging a pipelined batch.
			await this.#pumpOutbound();
			ev = this.#peer.poll();
			if (ev) return ev;
			// Dispatch every whole frame already buffered; each may surface an event
			// or queue outbound, so loop back to re-check.
			if (this.#pump.dispatchBuffered(this.#peer)) continue;
			// Block for more inbound; a clean end of stream ends the loop.
			if (!(await this.#pump.receive(this.#peer))) return null;
		}
	}

	/** Drive the keyed handshake without consuming application events. */
	async driveUntilSessionOpen(): Promise<void> {
		while (!this.#peer.sessionIsOpen()) {
			await this.#pumpOutbound();
			while (this.#pump.dispatchBuffered(this.#peer)) {
				if (this.#peer.sessionIsOpen()) return;
			}
			if (this.#peer.sessionIsOpen()) return;
			if (!(await this.#pump.receive(this.#peer))) {
				throw new Error("connection closed during the OCapN handshake");
			}
		}
	}

	// Encode every pending outbound message and write the queued frames. Stepping
	// to idle (not once) is what keeps a pipelined batch whole: a projection's
	// settlement cascades — a resolve drains the projection, whose resolve fires a
	// listener that queues a deliver — and each link is a separate step. A single
	// step would strand the tail in the queue, deadlocking a partner parked on the
	// answer it carries.
	#pumpOutbound(): Promise<void> {
		const prior = this.#writing;
		let release!: () => void;
		this.#writing = new Promise<void>((r) => (release = r));
		const run = async (): Promise<void> => {
			try {
				await prior;
				this.#peer.stepToIdle();
				let f: Uint8Array | null;
				while ((f = this.#peer.takeOutbound()) !== null) {
					await this.#pump.writeFrame(f);
				}
			} finally {
				release();
			}
		};
		return run();
	}

	close(): void {
		this.#pump.close();
		this.#peer.release();
	}

	[Symbol.asyncDispose](): Promise<void> {
		this.close();
		return Promise.resolve();
	}
}

// ── Connection: the application surface ──────────────────────────────────────
//
// This is what an application holds. It composes a peer, a vat, and the async
// I/O driver into one object, so a consumer never stitches those three together
// by hand. The verbs — `connect`/`listen`, `fetch`/`publish`, `spawn`,
// `send`, `tell`, `serve`, `close` — are the whole common surface. The raw `Peer`,
// `Vat`, and `AsyncConnection` are still here for power users (reach `conn.peer`
// for handoff/pipeline/session control), but no application needs them.

/** A capability — a reference to an object you can `send` to, wherever it lives.
 *
 * You get a `Ref` two ways: `conn.spawn(behavior)` (a local actor you host) or
 * `conn.fetch(name)` (a capability a partner published). A `Ref` is opaque: pass
 * it as an argument to `send` and it marshals to the right wire reference
 * automatically. You never construct `near`/`far` references by hand. */
export class Ref {
	constructor(
		/** The wire reference this marshals to when passed as a `send` argument. */
		readonly reference: Reference,
		/** The local actor id, if this `Ref` names an actor we host; else null. */
		readonly localActorId: number | null = null,
		/** The connection this reference lives on, when it is *not* the connection
		 * the application sends through. A capability redeemed from a three-party
		 * handoff lives on the exporter connection the machine dialed, so `send`
		 * routes there transparently. `null` means "the connection this Ref is used
		 * with" — the ordinary same-connection case. */
		readonly home: Connection | null = null,
	) {}
}

/** A value an application sends or receives: any OCapN `Argument`, a capability
 * `Ref`, or a list of those. The binding marshals `Ref`s to/from wire references
 * at the boundary, so applications work with capabilities as ordinary values. */
export type AppValue =
	| bigint
	| number
	| boolean
	| Uint8Array
	| string
	| Sym
	| Kw
	| null
	| Ref
	| AppValue[]
	| PSet
	| Tagged;

// Lower an application value to the wire vocabulary: a `Ref` becomes its
// underlying `Reference`; everything else passes through, recursing into
// lists, set items, and a tagged record's value so a capability nested in any
// of them marshals.
function lowerArg(arg: AppValue): Argument {
	if (arg instanceof Ref) return arg.reference;
	if (Array.isArray(arg)) return arg.map(lowerArg);
	if (arg instanceof PSet) {
		return new PSet((arg.items as AppValue[]).map(lowerArg));
	}
	if (arg instanceof Tagged) {
		return new Tagged(arg.tag, (arg.value as AppValue[]).map(lowerArg));
	}
	return arg;
}

// A capability whose `home` is a different connection cannot ride a plain send
// argument: lowering drops the home, so the wire reference would be meaningless
// to the partner. The gifter half handles this for a *returned* capability
// (C-i); passing one as an argument is the symmetric case still to land (C-ii),
// so fail closed and loudly rather than mis-encode it. Recurses into the
// container shapes a reference can hide in.
function assertNoForeignRef(value: AppValue, self: Connection): void {
	if (value instanceof Ref) {
		if (value.home !== null && value.home !== self) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"passing a capability that lives on another connection as a send argument is not yet supported; " +
					"introduce it as a return value instead (three-party handoff in argument position is the next lift)",
			);
		}
		return;
	}
	if (Array.isArray(value)) {
		for (const v of value) {
			assertNoForeignRef(v, self);
		}
	} else if (value instanceof PSet) {
		for (const v of value.items as AppValue[]) {
			assertNoForeignRef(v, self);
		}
	} else if (value instanceof Tagged) {
		for (const v of value.value as AppValue[]) {
			assertNoForeignRef(v, self);
		}
	}
}

// Lift a decoded argument to the application vocabulary: a wire `Reference`
// becomes a `Ref` the app can `send` to or pass on; lists, set items, and a
// tagged record's value recurse, so a capability arrives as a `Ref` wherever
// it is nested.
function liftArg(arg: Argument): AppValue {
	if (isReference(arg)) return new Ref(arg);
	if (Array.isArray(arg)) return arg.map(liftArg);
	if (arg instanceof PSet) {
		return new PSet(arg.items.map(liftArg) as Argument[]);
	}
	if (arg instanceof Tagged) {
		return new Tagged(arg.tag, arg.value.map(liftArg) as Argument[]);
	}
	return arg;
}

// As `liftArg`, but stamps every reference with the `home` connection it lives
// on, so a capability redeemed from a handoff (which lives on the exporter
// connection) routes there when the application sends to it. Nested capabilities
// from one resolution share the home.
function liftValue(arg: Argument, home: Connection): AppValue {
	if (isReference(arg)) return new Ref(arg, null, home);
	if (Array.isArray(arg)) return arg.map((a) => liftValue(a, home));
	if (arg instanceof PSet) {
		return new PSet(arg.items.map((a) => liftValue(a, home)) as Argument[]);
	}
	if (arg instanceof Tagged) {
		return new Tagged(
			arg.tag,
			arg.value.map((a) => liftValue(a, home)) as Argument[],
		);
	}
	return arg;
}

/** An actor: handle a `(verb, args)` call and return a reply. `args` may contain
 * `Ref`s (capabilities you were handed). Throw to break the caller's promise. */
export type Actor = (verb: string, args: AppValue[]) => AppValue | void;

// Complete the keyed `op:start-session` handshake over a negotiating peer: sign
// the transport's own locator (with a per-connection random session key), flush
// it, and pump until the partner's start-session opens the session. Entropy is
// generated here, at the I/O boundary, never in the sans-io core. The locator is
// what a partner verifies; the pump provides it — a true `tcp` host:port a
// Goblins partner accepts, or an `iroh` endpoint id.
export async function openKeyedSession(
	ac: AsyncConnection,
	seed?: Uint8Array,
): Promise<void> {
	const loc = ac.locator;
	// Entropy at the I/O boundary, never in the sans-io core. A handoff recipient
	// passes its machine's retained identity so the exporter recognizes it as the
	// party the give names; an ordinary dial gets a fresh per-connection key.
	seed = seed ?? crypto.getRandomValues(new Uint8Array(32));
	if (seed.length !== 32) throw new Error("a session seed must be 32 bytes");
	ac.peer.startSession({
		transport: loc.transport,
		designator: loc.designator,
		seed,
		hintsEmptyFalse: loc.hintsEmptyFalse ?? true,
	});
	await ac.flush();
	await ac.driveUntilSessionOpen();
}

/** Author the signed `desc:handoff-give` a gifter returns to a recipient
 * (ADR-0009). `seed` is the gifter's 32-byte identity seed — the key it
 * presents on its session to the exporter, which signs the give and must equal
 * the deposit's provenance. `recipientKey` is the recipient's session public
 * key; `exporterLocatorRaw` the exporter's verbatim location bytes (read off the
 * gifter's session to the exporter with `Peer.partnerLocatorRaw`);
 * `exporterSessionKey` the exporter's session public key; `giftId` the deposited
 * gift's id. Returns owned give bytes. */
export function buildHandoffGive(opts: {
	seed: Uint8Array;
	recipientKey: Uint8Array;
	exporterLocatorRaw: Uint8Array;
	exporterSessionKey: Uint8Array;
	giftId: Uint8Array;
}): Uint8Array {
	if (opts.seed.length !== 32) {
		throw new Error("a gifter seed must be 32 bytes");
	}
	const outGive = new Uint8Array(8), outLen = new Uint8Array(8);
	check(s.pancake_build_handoff_give(
		ab(opts.seed),
		32n,
		ab(opts.recipientKey),
		BigInt(opts.recipientKey.length),
		ab(opts.exporterLocatorRaw),
		BigInt(opts.exporterLocatorRaw.length),
		ab(opts.exporterSessionKey),
		BigInt(opts.exporterSessionKey.length),
		ab(opts.giftId),
		BigInt(opts.giftId.length),
		ab(outGive),
		ab(outLen),
	));
	const ptr = new DataView(outGive.buffer).getBigUint64(0, true);
	const len = new DataView(outLen.buffer).getBigUint64(0, true);
	try {
		return readBytes(ptr, len).slice();
	} finally {
		s.pancake_handoff_give_bytes_release(ptr, len);
	}
}

/** A vat-scoped deposited-gift table a node shares across its peers (ADR-0056).
 * An exporter receives a gift's `deposit-gift` on the gifter session and its
 * `withdraw-gift` on the recipient's separate session; one registry bound on
 * both peers is what lets the second find what the first deposited. Borrowed by
 * every peer it is set on — it must outlive them, so `free` it last. */
export class GiftRegistry {
	#raw: Ptr;

	constructor() {
		const out = new Uint8Array(8);
		check(s.pancake_gift_registry_new(ab(out)));
		this.#raw = outPointer(out);
	}

	/** The opaque handle, for `Peer.setGiftRegistry`. Binding-internal. */
	get pointer(): Ptr {
		return this.#raw;
	}

	/** Release the registry and every gift row it still owns. Every peer it was
	 * set on must already be released. Idempotent. */
	free(): void {
		if (this.#raw !== NULL) {
			s.pancake_gift_registry_free(this.#raw);
			this.#raw = NULL;
		}
	}

	[Symbol.dispose](): void {
		this.free();
	}
}

/** The CapTP machine for one peer — pancake's analogue of Goblins' `mycapn`,
 * kept deliberately distinct from the per-partner netlayer (`AsyncConnection`)
 * and the actor layer (`Vat`). It holds the peer's stable identity (one session
 * seed, reused for every connection it opens) and owns the connections it dials
 * to redeem three-party handoffs (ADR-0009/ADR-0056). A `Connection` delegates
 * redemption to its machine; the machine dials the exporter keyed with the
 * retained identity — so the exporter recognizes the recipient the give names —
 * withdraws the gift, and hands back a capability whose `home` is the exporter
 * connection. Routing by a ref's home is what keeps the machine a router above
 * the connections rather than a connection that proxies. */
export class Machine {
	/** The peer's retained identity seed (32 bytes), reused for every dial. */
	readonly seed: Uint8Array;
	readonly #exporters = new Map<string, Connection>();
	readonly #counts = new Map<string, bigint>();
	// One deposited-gift table shared across every peer this machine binds, so an
	// exporter node's deposit (on the gifter connection) and withdraw (on the
	// recipient connection) resolve against the same authority. Lazily created the
	// first time a peer is bound; outlives every connection, so it is not freed
	// when a single connection closes — `disposeRegistry` releases it.
	#giftRegistry: GiftRegistry | null = null;
	// Every live connection of this node, so a node-giftable object published once
	// appears on all of them — including connections accepted later.
	readonly #connections = new Set<Connection>();
	// Node-giftable objects by swissnum: capabilities this node exports under one
	// stable identity on *every* connection. A three-party handoff recipient
	// withdraws a gift on a connection it dialed itself, separate from the one the
	// gifter deposited on; the exporter can only honor it if the gifted object is
	// published on the withdrawing connection too. Publishing node-wide is what
	// makes the engine's swiss re-resolution (ADR-0009 exporter half) find it.
	readonly #giftable = new Map<string, Actor>();

	constructor(seed?: Uint8Array) {
		this.seed = seed ?? crypto.getRandomValues(new Uint8Array(32));
		if (this.seed.length !== 32) {
			throw new Error("a session seed must be 32 bytes");
		}
	}

	/** Bind this node's shared gift registry onto `peer` before its handshake, so
	 * the peer's inbound deposit/withdraw resolve against the node-wide table.
	 * Binding-internal: every `Connection` constructor calls it. */
	bindRegistry(peer: Peer): void {
		this.#giftRegistry ??= new GiftRegistry();
		peer.setGiftRegistry(this.#giftRegistry.pointer);
	}

	/** Release the shared gift registry, once every connection that referenced it
	 * is closed. Idempotent; a machine with no exporter activity never allocated
	 * one. Call at node shutdown, after `closeExporters`. */
	disposeRegistry(): void {
		this.#giftRegistry?.free();
		this.#giftRegistry = null;
	}

	/** Publish `behavior` under `name` on every connection of this node — those
	 * open now and any accepted later — so a recipient can withdraw a gift naming
	 * it on a connection it dialed itself (the exporter half of a three-party
	 * handoff, ADR-0009). Re-publishing a name replaces it on new connections;
	 * connections that already published the prior behavior keep it. Returns
	 * nothing — the gift's `Ref` is what the gifter passes on. */
	publishGiftable(name: string, behavior: Actor): void {
		this.#giftable.set(name, behavior);
		for (const conn of this.#connections) conn.publish(name, behavior);
	}

	/** Track a connection and publish every node-giftable on it. Binding-internal:
	 * the `Connection` constructor calls it once its session is open. */
	register(conn: Connection): void {
		this.#connections.add(conn);
		for (const [name, behavior] of this.#giftable) conn.publish(name, behavior);
	}

	/** Stop tracking a closed connection. Binding-internal. */
	unregister(conn: Connection): void {
		this.#connections.delete(conn);
	}

	/** Redeem a handoff give: dial the named exporter keyed with this machine's
	 * identity (reusing an open connection to it), withdraw the gift, and return
	 * the live capability plus the connection it lives on. */
	async redeem(
		give: HandoffGive,
	): Promise<{ conn: Connection; reference: Reference }> {
		if (give.exporterLocator.length === 0) {
			throw new Error("handoff give names no dialable exporter locator");
		}
		let conn = this.#exporters.get(give.exporterLocator);
		if (conn === undefined) {
			conn = await Connection.dialExporter(give.exporterLocator, this);
			this.#exporters.set(give.exporterLocator, conn);
			conn.serve();
		}
		// Goblins tracks handoff-count per exporter session and requires it to rise;
		// the first withdrawal on a fresh exporter connection is 0 (matches the live
		// `goblins-handoff` reference driver), the next is 1, and so on.
		const count = this.#counts.get(give.exporterLocator) ?? 0n;
		this.#counts.set(give.exporterLocator, count + 1n);
		const reference = await conn.withdrawGift(give.give, this.seed, count);
		return { conn, reference };
	}

	/** Close every exporter connection this machine dialed. */
	closeExporters(): void {
		for (const conn of this.#exporters.values()) conn.closeTransport();
		this.#exporters.clear();
	}
}

/** A live connection to one OCapN partner — the one object an application holds.
 *
 *   const conn = await connect(tcpLocator("127.0.0.1", 9099));
 *   conn.serve().catch((e) => console.error(e));
 *   const room = await conn.fetch("room");
 *   const inbox = conn.spawn((verb, args) => { ...; });
 *   await conn.send(room, "subscribe", ["alice", inbox]);
 */
export class Connection {
	#ac: AsyncConnection;
	#vat: Vat;
	#machine: Machine;
	#serving: Promise<void> | null = null;
	#closing = false;
	// Outbound answers whose handoff give the machine redeemed: the answer maps to
	// the exporter connection its capability lives on, so the resolution lifts
	// with the right `home`.
	readonly #redeemedHome = new Map<bigint, Connection>();
	// A published actor returned a capability that lives on another connection (a
	// gift to pass on): the lowered wire reference maps to its exporter home, read
	// back by the resolve interceptor to originate the handoff. Set in `#wrap` and
	// consumed immediately in the interceptor (same synchronous turn).
	readonly #foreignReturn = new Map<Reference, Connection>();

	// Distributed GC (ADR-0063), opt-in and off by default. When on, a `fetch`
	// result is registered so its import is released — one `op:gc-exports` — once
	// the runtime reclaims the last `Ref` to it. The cleanup callback runs on the
	// event loop, so it parks the position on `#gcPending` and a single serialized
	// drain enqueues and flushes the release.
	#gc = false;
	#gcRegistry: FinalizationRegistry<bigint> | null = null;
	readonly #gcPending: bigint[] = [];
	#gcDraining = false;

	private constructor(ac: AsyncConnection, machine: Machine) {
		this.#ac = ac;
		this.#vat = ac.vat();
		this.#machine = machine;
		// Originate a three-party handoff when a published actor returns a
		// capability whose home is a different connection (ADR-0009).
		this.#vat.setResolveInterceptor((answer, fulfilled) => {
			if (!isReference(fulfilled)) return false;
			const exporter = this.#foreignReturn.get(fulfilled);
			if (exporter === undefined) return false;
			this.#foreignReturn.delete(fulfilled);
			void this.#originateHandoff(answer, fulfilled, exporter);
			return true;
		});
		// Join the node so any node-giftable object is published on this connection
		// too — including this one, accepted after the giftable was registered.
		this.#machine.register(this);
	}

	/** Dial `host:port`, complete the keyed OCapN handshake, and return a ready
	 * connection. The session is open (the `op:start-session` exchange has
	 * completed) before this resolves, so a `fetch`/`send` rides an established
	 * session — the same handshake a real Goblins peer requires. (TCP today; a
	 * future transport is a constructor option, never a different `Connection`
	 * type.) */
	static async connect(
		host: string,
		port: number,
		machine: Machine = new Machine(),
	): Promise<Connection> {
		const tcp = await net.connect(host, port);
		const ac = AsyncConnection.fromConn(new Peer(), tcp);
		machine.bindRegistry(ac.peer);
		await openKeyedSession(ac, machine.seed);
		return new Connection(ac, machine);
	}

	/** Wrap a socket a server already accepted and complete the keyed handshake
	 * from the responder side (used by `listen`). Resolves once the session is
	 * open. */
	static async accept(
		tcp: NetConn,
		machine: Machine = new Machine(),
	): Promise<Connection> {
		const ac = AsyncConnection.fromConn(new Peer(), tcp);
		machine.bindRegistry(ac.peer);
		// Construct (which runs `machine.register`, publishing the node's giftables
		// as bootstrap caps) *before* driving the handshake to completion. A dialer
		// — Goblins notably — pipelines its bootstrap fetch right after
		// `op:start-session`, and that fetch is auto-answered as the handshake drive
		// consumes inbound; if the giftable is not registered yet the fetch resolves
		// as missing and the dialer's enliven hangs. Registering first closes that
		// window. A handshake failure unregisters the half-built connection.
		const conn = new Connection(ac, machine);
		try {
			await openKeyedSession(ac, machine.seed);
		} catch (err) {
			conn.closeTransport();
			throw err;
		}
		return conn;
	}

	/** Wrap an `AsyncConnection` whose keyed session is already open — the
	 * transport-neutral constructor the `@pancake/iroh` package builds an iroh
	 * `Connection` through. Part of the binding-internal seam. */
	static fromAsync(
		ac: AsyncConnection,
		machine: Machine = new Machine(),
	): Connection {
		machine.bindRegistry(ac.peer);
		return new Connection(ac, machine);
	}

	/** Dial an exporter named by a handoff give's `ocapn://` locator, keyed with
	 * `machine`'s retained identity, and bind the result to that same machine so
	 * the redeemed capability and any further handoff it triggers share one
	 * identity and connection table. Binding-internal: the machine calls this to
	 * redeem a give. TCP today; an iroh exporter locator is a later lift. */
	static async dialExporter(
		uri: string,
		machine: Machine,
	): Promise<Connection> {
		const loc = parseLocator(uri);
		if (loc.transport !== "tcp") {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`handoff redeem: unsupported exporter transport "${loc.transport}" in ${uri}`,
			);
		}
		const colon = loc.designator.lastIndexOf(":");
		if (colon < 0) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`tcp locator designator is not host:port: ${loc.designator}`,
			);
		}
		const tcp = await net.connect(
			loc.designator.slice(0, colon),
			Number(loc.designator.slice(colon + 1)),
		);
		const ac = AsyncConnection.fromConn(new Peer(), tcp);
		machine.bindRegistry(ac.peer);
		await openKeyedSession(ac, machine.seed);
		return new Connection(ac, machine);
	}

	/** The underlying sans-io peer — the escape hatch for handoff, pipelining, and
	 * session control. Applications do not need it. */
	get peer(): Peer {
		return this.#ac.peer;
	}

	/** The node's shared machine — its retained identity and gift registry. Shared
	 * by every connection of one node, so the gifter half of a handoff can reach a
	 * sibling connection's session keys. Binding-internal. */
	get machine(): Machine {
		return this.#machine;
	}

	/** Spawn a local actor and return a capability to it. The `Ref` auto-marshals
	 * when passed as a `send` argument, so handing a partner a callback is just
	 * `send(target, verb, [..., conn.spawn(behavior)])`. The position comes from
	 * the session's one export allocator, so it can never alias a bootstrap or
	 * resolver export. */
	spawn(behavior: Actor): Ref {
		const position = this.#ac.peer.nextExport();
		const local = this.#vat.publish(position, this.#wrap(behavior));
		return new Ref(near(position), local.id);
	}

	/** Publish an actor so a partner can `fetch` it by `name`. The name is a
	 * swiss-number: a readable string for a discoverable service, a cryptographic
	 * secret where the name itself is the authorization. */
	publish(name: string, behavior: Actor): Ref {
		const swiss = new TextEncoder().encode(name);
		const position = this.#ac.peer.registerBootstrapCap(swiss);
		const local = this.#vat.publish(position, this.#wrap(behavior));
		return new Ref(near(position), local.id);
	}

	/** Fetch a partner's published capability by `name`. Returns a `Ref` you can
	 * `send` to. Drives the inbound loop itself, so a `fetch` straight after
	 * `connect` works without a separate `serve()` call (which stays the way to
	 * keep serving until close). Rejects with `VowBroken` when the partner
	 * breaks the fetch, and with `FetchFailed` when it fulfills with something
	 * that is not a capability. */
	async fetch(name: string): Promise<Ref> {
		this.serve(); // idempotent; the resolution arrives on the inbound loop
		// The canonical fetch lives in the library: one call registers the
		// bootstrap import, allocates the answer, and queues the deliver.
		const answer = this.#ac.peer.sendBootstrapFetch(
			new TextEncoder().encode(name),
		);
		// Subscribe before flushing: the resolution can land on the serve loop the
		// instant `flush` yields the event loop.
		const settled = settle(this.#vat, new FarVow(answer, this.#vat));
		await this.#ac.flush();
		const result = await settled;
		if (!isReference(result)) {
			throw new FetchFailed(name);
		}
		// Stamp the home: a fetched capability lives on *this* connection. Used on
		// this connection, home is a no-op; returned to another connection (a gift
		// to pass on), the explicit home is what lets the gifter half recognize it
		// as foreign and originate a three-party handoff rather than mis-encode it.
		return this.#trackImport(new Ref(result, null, this));
	}

	/** Opt this connection into distributed GC (ADR-0063), off by default. Once
	 * on, a far capability returned by {@link fetch} releases its import to the
	 * partner — a single `op:gc-exports` delta — when the runtime reclaims the
	 * last `Ref` to it, so the partner can release the matching export. Collection
	 * is best-effort on the JS `FinalizationRegistry` schedule. Capabilities
	 * lifted elsewhere (a `send` reply, a delivered argument, an `enliven` result
	 * the dedup cache owns) are outside this seam. Returns `this` for chaining. */
	withGc(): this {
		this.#gc = true;
		return this;
	}

	// Register a fetched far import for GC (ADR-0063), when GC is on. The
	// bootstrap import (position 0) is refused in a `gc-exports`, so it is never
	// registered. A near or promise reference carries no wire-count to release.
	#trackImport(ref: Ref): Ref {
		if (this.#gc && ref.reference.kind === "far" && ref.reference.id !== 0n) {
			if (this.#gcRegistry === null) {
				this.#gcRegistry = new FinalizationRegistry<bigint>((position) => {
					this.#gcPending.push(position);
					void this.#drainGc();
				});
			}
			this.#gcRegistry.register(ref, ref.reference.id);
		}
		return ref;
	}

	// Drain the parked GC releases: one `op:gc-exports` delta per reclaimed
	// import, flushed through the serialized outbound pump. Best-effort — a
	// release that cannot be queued (the session is closing) costs a stranded
	// partner export reclaimed at teardown, never a fault. Self-serialized so a
	// burst of finalizations coalesces into one drain.
	async #drainGc(): Promise<void> {
		if (this.#gcDraining) return;
		this.#gcDraining = true;
		try {
			while (this.#gcPending.length > 0 && !this.#closing) {
				const positions = this.#gcPending.splice(0);
				for (const position of positions) {
					try {
						this.#ac.peer.sendGcExport([position], [1n]);
					} catch {
						// best-effort: a refused release strands a partner export only.
					}
				}
				try {
					await this.#ac.flush();
				} catch {
					// the session may be gone; teardown reclaims the rows.
				}
			}
		} finally {
			this.#gcDraining = false;
		}
	}

	/** Enliven a sturdyref against this connection (ADR-0012): bring the durable
	 * `(peer, swissnum)` to life as a live `Ref`. Parses `sturdyref` for its
	 * swissnum, then fetches it through the dedup cache — a repeat enliven of the
	 * same swissnum on this session short-circuits with no wire traffic. The
	 * connection must already be open to the sturdyref's peer; the sans-io core
	 * tracks no remote locator and never dials, so reaching the right peer is the
	 * caller's. Rejects with `VowBroken` when the partner breaks the enliven, and
	 * with `FetchFailed` when it fulfills with something that is not a
	 * capability. */
	async enliven(sturdyref: string): Promise<Ref> {
		const swiss = new TextEncoder().encode(
			parseLocator(sturdyref, true).swissnum,
		);
		this.serve(); // the resolution arrives on the inbound loop
		const peer = this.#ac.peer;
		const start = peer.prepareEnliven(swiss);
		if (start.status === ENLIVEN_CACHED) {
			// Cache hit: reconstruct the far reference, no wire traffic.
			return new Ref(
				far(start.importPosition, start.kind === REF_SUB_PROMISE),
				null,
				this,
			);
		}
		// FRESH or IN_FLIGHT: drive the (possibly shared) answer to settlement.
		const settled = settle(this.#vat, new FarVow(start.answer, this.#vat));
		await this.#ac.flush();
		let result: Argument;
		try {
			result = await settled;
		} catch (e) {
			peer.recordEnlivenment(swiss, ENLIVEN_OUTCOME_BROKEN, 0n, 0);
			throw e;
		}
		if (!isReference(result) || result.kind !== "far") {
			peer.recordEnlivenment(swiss, ENLIVEN_OUTCOME_BROKEN, 0n, 0);
			throw new FetchFailed(sturdyref);
		}
		// Cache the fulfilled far reference so a repeat enliven short-circuits.
		peer.recordEnlivenment(
			swiss,
			ENLIVEN_OUTCOME_FULFILLED,
			result.id,
			result.promise ? REF_SUB_PROMISE : REF_SUB_OBJECT,
		);
		return new Ref(result, null, this);
	}

	/** Eventual-send `verb(args)` to `target` and return a [`RemotePromise`] for
	 * the reply. `await` it for the value (a `Ref` if the partner returned a
	 * capability; rejects with `VowBroken` on a partner break), exactly as before.
	 *
	 * `target` is a capability `Ref` *or* a `RemotePromise` from an earlier send:
	 * passing the latter pipelines (ADR-0007) — the call is addressed at the
	 * answer that send will resolve, so a dependent chain costs one round trip
	 * instead of one per link. `args` may contain `Ref`s.
	 *
	 * The deliver is queued now; its bytes leave the wire when the returned handle
	 * — or any send pipelined behind it — is first awaited, so a pipelined batch
	 * travels together. */
	send(
		target: Ref | RemotePromise,
		verb: string,
		args: AppValue[] = [],
	): RemotePromise {
		// A capability redeemed from a handoff lives on the exporter connection the
		// machine dialed; route the send there so the bytes go straight to the
		// exporter, transparently to the application (Goblins' three-party handoff).
		if (target instanceof Ref && target.home !== null && target.home !== this) {
			return target.home.send(target, verb, args);
		}
		for (const a of args) assertNoForeignRef(a, this);
		const wireArgs = args.map(lowerArg);
		const vatTarget = this.#targetVatRef(target);
		const isLocal = vatTarget instanceof LocalRef;
		if (!isLocal) this.serve(); // far reply arrives on the inbound loop
		const vow = this.#vat.send(vatTarget, verb, wireArgs);
		// Defer the flush + reply wait to first observation. Registering the
		// listener before the flush keeps the subscribe-before-reply ordering a far
		// reply needs; deferring is what lets a pipelined chain queue together and
		// leave on the awaited tail's flush, which drains every queued deliver.
		const answer = vow.location === "far" ? vow.answer : null;
		const begin = async (): Promise<AppValue> => {
			const result = settle(this.#vat, vow);
			if (isLocal) this.#vat.drive();
			else await this.#ac.flush();
			const value = await result;
			// A redeemed handoff resolution lifts with the exporter connection as the
			// ref's home; every ordinary resolution lifts against this connection.
			const home = answer !== null ? (this.#redeemedHome.get(answer) ?? this) : this;
			return liftValue(value, home);
		};
		const project = answer !== null
			? (op: "get" | "index" | "untag", key: string | bigint) =>
				this.#projectAnswer(answer, op, key)
			: null;
		return new RemotePromise(answer, begin, project);
	}

	// Pipeline a projection (op:get / op:index / op:untag) at `sourceAnswer`
	// (ADR-0050/ADR-0052). Like `send`, the op is queued now and the flush is
	// deferred to the returned handle's first observation, so a chain of
	// projections leaves the wire together. The result is itself projectable.
	#projectAnswer(
		sourceAnswer: bigint,
		op: "get" | "index" | "untag",
		key: string | bigint,
	): RemotePromise {
		this.serve(); // the projected resolution arrives on the inbound loop
		const peer = this.#ac.peer;
		const receiver = promise(sourceAnswer);
		const answer = peer.nextAnswer();
		switch (op) {
			case "get":
				peer.sendGet(receiver, key as string, answer);
				break;
			case "index":
				peer.sendIndex(receiver, key as bigint, answer);
				break;
			case "untag":
				peer.sendUntag(receiver, key as string, answer);
				break;
		}
		const vow = new FarVow(answer, this.#vat);
		const begin = async (): Promise<AppValue> => {
			const result = settle(this.#vat, vow);
			await this.#ac.flush();
			return liftValue(await result, this);
		};
		const project = (op2: "get" | "index" | "untag", key2: string | bigint) =>
			this.#projectAnswer(answer, op2, key2);
		return new RemotePromise(answer, begin, project);
	}

	// Resolve a send target to its vat reference. A `Ref` names a near actor or a
	// far import as today; a `RemotePromise` names the still-pending answer of an
	// earlier far send, so the deliver rides a `desc:answer` target and pipelines.
	#targetVatRef(target: Ref | RemotePromise): VatRef {
		if (target instanceof RemotePromise) {
			if (target.answer === null) {
				throw new Error(
					"cannot pipeline against a local-send promise; await it for a Ref",
				);
			}
			return new FarRef(promise(target.answer));
		}
		return target.localActorId !== null
			? new LocalRef(target.localActorId)
			: new FarRef(target.reference);
	}

	/** Send `verb(args)` to `target` without awaiting a reply — the fire-and-forget
	 * eventual-send (Goblins `<-np`). No answer is allocated and none comes back,
	 * so it is the right call for a notification or a broadcast: it costs one
	 * deliver, not a deliver plus a reply. Flushes immediately. */
	async tell(target: Ref, verb: string, args: AppValue[] = []): Promise<void> {
		// Route a redeemed-handoff capability to its exporter connection, as `send`.
		if (target.home !== null && target.home !== this) {
			return await target.home.tell(target, verb, args);
		}
		for (const a of args) assertNoForeignRef(a, this);
		if (target.localActorId !== null) {
			this.#vat.send(
				new LocalRef(target.localActorId),
				verb,
				args.map(lowerArg),
			);
			this.#vat.drive();
			return;
		}
		const payload: Argument[] = verb.length > 0
			? [new Sym(verb), ...args.map(lowerArg)]
			: args.map(lowerArg);
		this.#ac.peer.sendDeliver(target.reference, payload, null);
		await this.#ac.flush();
	}

	/** Run the inbound event loop: dispatch each arriving call to the published or
	 * spawned actor it targets, and settle the promises of `send`s awaiting a
	 * reply. Resolves when the connection closes cleanly; rejects on a transport
	 * or protocol error. Started once; calling again returns the same promise. */
	serve(): Promise<void> {
		if (this.#serving === null) this.#serving = this.#serveLoop();
		return this.#serving;
	}

	/** Close the connection and every exporter connection its machine dialed for
	 * handoffs. A running `serve()` resolves cleanly. */
	close(): void {
		this.#closing = true;
		this.#machine.unregister(this);
		this.#machine.closeExporters();
		this.#ac.close();
	}

	/** Close just this connection's transport, without touching the machine's
	 * other connections — how the machine reclaims an exporter connection it owns.
	 * Binding-internal. */
	closeTransport(): void {
		this.#closing = true;
		this.#machine.unregister(this);
		this.#ac.close();
	}

	/** Withdraw a deposited gift from this (exporter) connection: sign a
	 * `desc:handoff-receive` over `give` keyed by `seed` and deliver `withdraw-gift`
	 * to the exporter's bootstrap, returning the withdrawn capability's reference
	 * once it resolves. Binding-internal: the machine calls this during redeem. */
	async withdrawGift(
		give: Uint8Array,
		seed: Uint8Array,
		count: bigint,
	): Promise<Reference> {
		this.serve();
		const answer = this.#ac.peer.nextAnswer();
		const settled = settle(this.#vat, new FarVow(answer, this.#vat));
		this.#ac.peer.sendWithdrawGift(give, seed, count, answer);
		await this.#ac.flush();
		const value = await settled;
		if (!isReference(value)) {
			throw new Error("withdraw-gift did not resolve to a capability");
		}
		return value;
	}

	[Symbol.dispose](): void {
		this.close();
	}

	// Drive inbound events to quiescence. A read cancelled by our own `close()` is
	// a clean shutdown (resolve); any other failure is a real fault (reject), so a
	// caller's `serve().catch(...)` sees genuine connection loss and nothing else.
	// Either way the wire is gone when the loop ends, so break any `send` still
	// awaiting a reply rather than leaving its promise pending forever.
	async #serveLoop(): Promise<void> {
		try {
			for await (const event of this.#ac) {
				// A give arriving as a resolution is redeemed by the machine, not the
				// vat: dial the exporter keyed with our identity, withdraw, and settle
				// the awaiting send with the live capability. Done off the loop so the
				// redeem's own I/O does not stall this connection's reads.
				if (event.kind === "resolve" && "handoff" in event.resolution) {
					void this.#redeemHandoff(event.answer, event.resolution.handoff);
					continue;
				}
				this.#vat.serve(event);
			}
		} catch (err) {
			if (!this.#closing) throw err;
		} finally {
			this.#vat.breakFarVows("connection closed");
			// The inbound stream is gone: either we closed (the transport is already
			// closing) or the peer disconnected (a clean EOF or a fault). In the
			// disconnect case the socket is still open, so release it — a dead
			// connection frees its fd instead of being left for GC. This also lets the
			// process exit on its own: a runtime whose sockets keep the event loop
			// alive while open (node:net under Bun/Node) would otherwise be pinned by
			// an accepted connection whose partner has already hung up. Idempotent
			// with an application `close()` (which has set `#closing`).
			if (!this.#closing) this.closeTransport();
		}
	}

	// Redeem a handoff give through the machine, then settle the original answer by
	// feeding the vat a synthetic fulfill carrying the redeemed capability — whose
	// `home` (recorded here) is the exporter connection it lives on. A redeem
	// failure breaks the awaiting send rather than hanging it.
	async #redeemHandoff(answer: bigint, give: HandoffGive): Promise<void> {
		try {
			const { conn, reference } = await this.#machine.redeem(give);
			this.#redeemedHome.set(answer, conn);
			this.#vat.serve({
				kind: "resolve",
				answer,
				resolution: { fulfill: reference },
			});
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			this.#vat.serve({
				kind: "resolve",
				answer,
				resolution: { break: `handoff redeem failed: ${message}` },
			});
		}
	}

	// Wrap an application actor so the vat sees a raw `Behavior`: lift incoming
	// reference args to `Ref`s, lower a returned `Ref` to its wire reference, and
	// normalize a `void` return to `null` (a bare ack). A returned capability whose
	// home is another connection is recorded for the resolve interceptor, which
	// originates a three-party handoff instead of mis-sending a cross-connection
	// reference (ADR-0009; the gifter half, C-i: a top-level returned capability).
	#wrap(behavior: Actor): Behavior {
		return (verb: string, rawArgs: Argument[]): Argument => {
			const result = behavior(verb, rawArgs.map(liftArg));
			if (
				result instanceof Ref && result.home !== null && result.home !== this
			) {
				this.#foreignReturn.set(result.reference, result.home);
				return result.reference;
			}
			return result === undefined || result === null ? null : lowerArg(result);
		};
	}

	// Originate the gifter half of a three-party handoff: deposit `gifted` (a
	// capability that lives on the `exporter` connection) back with the exporter,
	// then resolve the recipient's `answer` with a signed `desc:handoff-give` the
	// recipient redeems transparently. Crypto inputs come from this gifter's two
	// sessions — the recipient key from this (to-recipient) connection, the
	// exporter locator and key from the exporter connection — signed with the
	// node's one retained identity, which is also what the exporter saw on the
	// deposit, so the give's signature and the deposit's provenance match. A
	// failure breaks the recipient's answer rather than hanging it.
	async #originateHandoff(
		answer: bigint,
		gifted: Reference,
		exporter: Connection,
	): Promise<void> {
		try {
			const giftId = crypto.getRandomValues(new Uint8Array(32));
			// Deposit on the exporter connection (the gifted reference is one the
			// exporter exported to us, so it re-encodes to its own export there), and
			// put it on the wire before the recipient can dial in to withdraw.
			exporter.peer.sendDepositGift(giftId, gifted);
			await exporter.#flushOutbound();

			const recipientKey = this.peer.partnerSessionKey();
			const exporterLocatorRaw = exporter.peer.partnerLocatorRaw();
			const exporterSessionKey = exporter.peer.partnerSessionKey();
			if (
				recipientKey === null || exporterLocatorRaw === null ||
				exporterSessionKey === null
			) {
				throw new Error(
					"handoff origination needs open keyed sessions to both the recipient and the exporter",
				);
			}
			const give = buildHandoffGive({
				seed: this.#machine.seed,
				recipientKey,
				exporterLocatorRaw,
				exporterSessionKey,
				giftId,
			});
			this.peer.sendResolveHandoffGive(answer, give);
			await this.#flushOutbound();
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			try {
				this.peer.sendResolve(answer, {
					break: `handoff origination failed: ${message}`,
				});
				await this.#flushOutbound();
			} catch { /* the connection is already gone; nothing more to do */ }
		}
	}

	// Put whatever is queued on this connection's peer onto the wire now. Used by
	// the cross-connection handoff origination, which queues onto a peer whose own
	// serve loop may be parked in a read.
	async #flushOutbound(): Promise<void> {
		await this.#ac.flush();
	}
}

/** A listening server. Iterate it for an accepted `Connection` per partner —
 * `for await (const conn of listen(host, port)) { ... }`.
 *
 * Binding the socket is asynchronous on some runtimes, so `await server.ready()`
 * for the bound port (the value you need when you pass port 0 for an ephemeral
 * one). The async iterator awaits the bind itself, so a `for await` works
 * without `ready()`; the `port` getter requires `ready()` to have resolved. */
export class Server {
	#pending: Promise<NetListener>;
	#listener: NetListener | null = null;
	// One identity and one shared gift registry for the whole node: every accepted
	// connection keys its handshake with this machine's seed and binds its peer to
	// this machine's gift registry, so a gift deposited on one accepted connection
	// is withdrawable on another — the exporter-node shape a three-party handoff
	// recipient relies on (ADR-0009/ADR-0056).
	readonly #machine: Machine;

	constructor(pending: Promise<NetListener>, machine: Machine = new Machine()) {
		this.#pending = pending;
		this.#machine = machine;
	}

	/** The node's shared machine — its retained identity and gift registry. An
	 * exporter application reads it to originate gifts that recipients withdraw
	 * across the node's connections. */
	get machine(): Machine {
		return this.#machine;
	}

	/** Await the bind and return the bound TCP port. Idempotent. */
	async ready(): Promise<number> {
		if (this.#listener === null) this.#listener = await this.#pending;
		return this.#listener.port;
	}

	/** The bound TCP port. Throws until `ready()` has resolved the bind. */
	get port(): number {
		if (this.#listener === null) {
			throw new Error(
				"server not bound yet; await server.ready() before reading port",
			);
		}
		return this.#listener.port;
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Connection> {
		const listener = await this.#pending;
		this.#listener = listener;
		// Closing the listener when iteration ends (a `break`, a `return`, or the
		// listener itself closing) frees the bound socket, so a one-client server
		// (`for await (const conn of server) { …; break; }`) leaves nothing holding
		// the runtime's event loop open.
		try {
			for (;;) {
				let tcp: NetConn;
				try {
					tcp = await listener.accept();
				} catch {
					return; // the listener was closed
				}
				// A handshake failure belongs to that one connection — a client that
				// dialed and died, or a stray port probe. Skipping it keeps the listener
				// accepting, so one rude caller cannot take the whole server down.
				let conn: Connection;
				try {
					conn = await Connection.accept(tcp, this.#machine);
				} catch {
					continue;
				}
				yield conn;
			}
		} finally {
			listener.close();
		}
	}

	/** Stop accepting new connections. */
	close(): void {
		if (this.#listener !== null) {
			this.#listener.close();
			return;
		}
		void this.#pending.then((l) => l.close()).catch(() => {});
	}
}

/** Accept connections on `host:port`, returning a `Server` you iterate for each
 * accepted `Connection`. The bind completes asynchronously; `await
 * server.ready()` for the bound port. */
export function listen(
	host: string,
	port: number,
	machine: Machine = new Machine(),
): Server {
	return new Server(net.listen(host, port), machine);
}

// ── OCapN locator URIs ───────────────────────────────────────────────────────
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
// must outlive the call (they do — they are locals of the caller above).
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

/** Dial a partner from its `ocapn://` locator — the one dialer, dispatching on
 * the locator's transport: `iroh` dials the endpoint id with its
 * `direct-addresses` hints, `tcp` dials the `host:port` designator. There is no
 * other dial: a literal address is a `tcp` locator, built with `tcpLocator`. The
 * binding parses the URI once and the core grammar decides the netlayer.
 *
 * A `tcp` locator needs only this core module. An `iroh` locator reaches into
 * the `@pancake/iroh` package (the optional encrypted-QUIC artifact), loaded
 * lazily with `import()` so the core never hard-depends on it — the import only
 * resolves if the consumer added that package; `reachability`
 * (a `Reachability` from `@pancake/iroh`, its numeric value) sets the iroh
 * dialer's posture and is required only for an `iroh` locator. A `tcp` locator
 * ignores it, so a plain TCP dial needs nothing but the locator. An iroh locator
 * with no posture fails closed rather than guessing one. Identical in shape to
 * the Python, Rust, and Racket bindings. */
export async function connect(
	uri: string,
	reachability?: number,
): Promise<Connection> {
	const loc = parseLocator(uri);
	switch (loc.transport) {
		case "iroh": {
			if (reachability === undefined) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					`connect: an iroh locator requires a reachability posture: ${uri}`,
				);
			}
			const iroh = await import("@pancake/iroh");
			return iroh.connectIroh(
				loc.designator,
				loc.hints.get("direct-addresses") ?? "",
				reachability,
			);
		}
		case "tcp": {
			const colon = loc.designator.lastIndexOf(":");
			if (colon < 0) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					`tcp locator designator is not host:port: ${loc.designator}`,
				);
			}
			return Connection.connect(
				loc.designator.slice(0, colon),
				Number(loc.designator.slice(colon + 1)),
			);
		}
		default:
			throw new PancakeError(
				INVALID_ARGUMENT,
				`connect: unsupported transport "${loc.transport}"`,
			);
	}
}

/** Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
 * rendered through the core grammar. The convenience for the common case — a
 * caller holding a host and port passes `connect(tcpLocator(host, port))`
 * instead of hand-formatting the URI. `host:port` is not a dial of its own; it
 * is a locator like any other. */
export function tcpLocator(host: string, port: number): string {
	return formatPeerUri("tcp", `${host}:${port}`);
}
