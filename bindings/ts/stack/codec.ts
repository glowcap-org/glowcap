// Argument marshalling: encode a native `Argument` into the C ABI's flat
// `PancakeArgument` structs and decode them back. The one place the wire struct
// layout is spelled. All of this is package-internal — the peer/vat/connection
// modules import what they need (`encodeArgs`, `readArg`, `readArgArray`,
// `refStruct`, `readReference`); the barrel exposes none of it. `encodeArg` and
// `writeReference` are module-private, used only by their exported wrappers.

import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { readBytes } from "./internal/seam.ts";
import {
	ARG_BIG_INTEGER,
	ARG_BOOLEAN,
	ARG_BOOLEAN_OFF,
	ARG_BYTES,
	ARG_BYTES_LEN_OFF,
	ARG_BYTES_OFF,
	ARG_FLOAT64,
	ARG_FLOAT64_OFF,
	ARG_INTEGER,
	ARG_INTEGER_OFF,
	ARG_ITEMS_LEN_OFF,
	ARG_ITEMS_OFF,
	ARG_KEYWORD,
	ARG_KIND_OFF,
	ARG_LIST,
	ARG_REFERENCE,
	ARG_REFERENCE_OFF,
	ARG_SET,
	ARG_SIZE,
	ARG_STRING,
	ARG_SYMBOL,
	ARG_TAGGED,
	ARG_VOID,
	INVALID_ARGUMENT,
	REF_BROKEN,
	REF_FAR,
	REF_ID_OFF,
	REF_KIND_OFF,
	REF_NEAR,
	REF_PROMISE,
	REF_SIZE,
	REF_STURDY,
	REF_SUB_KIND_OFF,
	REF_SUB_OBJECT,
	REF_SUB_PROMISE,
	UNSUPPORTED_VALUE,
} from "./internal/abi.ts";
import { PancakeError } from "./errors.ts";
import { type Argument, isReference, Kw, PSet, type Reference, Sym, Tagged } from "./value.ts";

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
	dv.setUint32(off + REF_KIND_OFF, kind, true);
	dv.setUint32(off + REF_SUB_KIND_OFF, sub, true);
	dv.setBigUint64(off + REF_ID_OFF, id, true);
}

export function refStruct(ref: Reference): Uint8Array {
	const buf = new Uint8Array(REF_SIZE);
	writeReference(new DataView(buf.buffer), 0, ref);
	return buf;
}

// Encodes args into one contiguous Uint8Array of ARG_SIZE structs, pushing any
// backing byte/child buffers onto `keep` so they outlive the FFI call.
export function encodeArgs(args: Argument[], keep: Uint8Array[]): Uint8Array {
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
		dv.setUint32(off + ARG_KIND_OFF, kind, true);
		dv.setBigUint64(off + ARG_BYTES_OFF, ffi.pointerOf(bytes), true);
		dv.setBigUint64(off + ARG_BYTES_LEN_OFF, BigInt(bytes.length), true);
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
			dv.setUint32(off + ARG_BOOLEAN_OFF, negative ? 1 : 0, true);
		} else {
			dv.setUint32(off + ARG_KIND_OFF, ARG_INTEGER, true);
			dv.setBigInt64(off + ARG_INTEGER_OFF, arg, true);
		}
	} else if (typeof arg === "number") {
		dv.setUint32(off + ARG_KIND_OFF, ARG_FLOAT64, true);
		dv.setFloat64(off + ARG_FLOAT64_OFF, arg, true);
	} else if (typeof arg === "boolean") {
		dv.setUint32(off + ARG_KIND_OFF, ARG_BOOLEAN, true);
		dv.setUint32(off + ARG_BOOLEAN_OFF, arg ? 1 : 0, true);
	} else if (arg instanceof Uint8Array) {
		setBytes(ARG_BYTES, arg);
	} else if (arg instanceof Sym) {
		setBytes(ARG_SYMBOL, new TextEncoder().encode(arg.value));
	} else if (arg instanceof Kw) {
		setBytes(ARG_KEYWORD, new TextEncoder().encode(arg.value));
	} else if (typeof arg === "string") {
		setBytes(ARG_STRING, new TextEncoder().encode(arg));
	} else if (arg === null) {
		dv.setUint32(off + ARG_KIND_OFF, ARG_VOID, true);
	} else if (isReference(arg)) {
		dv.setUint32(off + ARG_KIND_OFF, ARG_REFERENCE, true);
		writeReference(dv, off + ARG_REFERENCE_OFF, arg);
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
		dv.setUint32(off + ARG_KIND_OFF, kind, true);
		const child = encodeArgs(items, keep);
		dv.setBigUint64(off + ARG_ITEMS_OFF, ffi.pointerOf(child), true);
		dv.setBigUint64(off + ARG_ITEMS_LEN_OFF, BigInt(items.length), true);
	}
}

export function readReference(view: DataView, off: number): Reference {
	const kind = view.getUint32(off + REF_KIND_OFF, true);
	const sub = view.getUint32(off + REF_SUB_KIND_OFF, true);
	const id = view.getBigUint64(off + REF_ID_OFF, true);
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

export function readArg(view: DataView, off: number): Argument {
	// The `(bytes, len)` and `(items, len)` pairs each appear in several arms; read
	// them through one spelling so the ARG struct layout lives in one place.
	const argBytes = () =>
		readBytes(
			view.getBigUint64(off + ARG_BYTES_OFF, true),
			view.getBigUint64(off + ARG_BYTES_LEN_OFF, true),
		);
	const argString = () => new TextDecoder().decode(argBytes());
	const argItems = () =>
		readArgArray(
			view.getBigUint64(off + ARG_ITEMS_OFF, true),
			view.getBigUint64(off + ARG_ITEMS_LEN_OFF, true),
		);
	const kind = view.getUint32(off + ARG_KIND_OFF, true);
	switch (kind) {
		case ARG_INTEGER:
			return view.getBigInt64(off + ARG_INTEGER_OFF, true);
		case ARG_FLOAT64:
			return view.getFloat64(off + ARG_FLOAT64_OFF, true);
		case ARG_BOOLEAN:
			return view.getUint32(off + ARG_BOOLEAN_OFF, true) !== 0;
		case ARG_BYTES:
			return argBytes();
		case ARG_STRING:
			return argString();
		case ARG_SYMBOL:
			return new Sym(argString());
		case ARG_REFERENCE:
			return readReference(view, off + ARG_REFERENCE_OFF);
		case ARG_LIST:
			return argItems();
		case ARG_SET:
			return new PSet(argItems());
		case ARG_TAGGED:
			return new Tagged(argString(), argItems());
		case ARG_KEYWORD:
			return new Kw(argString());
		case ARG_VOID:
			return null;
		case ARG_BIG_INTEGER: {
			// Canonical decimal digits + sign flag back to a native bigint (ADR-0049).
			const magnitude = BigInt(argString());
			return view.getUint32(off + ARG_BOOLEAN_OFF, true) !== 0 ? -magnitude : magnitude;
		}
		default:
			throw new PancakeError(
				INVALID_ARGUMENT,
				"unrecognized decoded argument kind",
			);
	}
}

export function readArgArray(ptrValue: Ptr, len: bigint): Argument[] {
	if (ptrValue === NULL || len === 0n) return [];
	const view = new DataView(ffi.readMemory(ptrValue, Number(len) * ARG_SIZE));
	const out: Argument[] = [];
	for (let i = 0; i < Number(len); i++) out.push(readArg(view, i * ARG_SIZE));
	return out;
}
