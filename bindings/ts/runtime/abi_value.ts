// C-ABI value projection: encode a native `Argument` into the C ABI's flat
// `PancakeArgument` structs and decode them back. The one place the ABI struct
// layout is spelled: every size and field offset comes from the active layout
// `L`, and pointer-width fields go through its width-aware accessors, so the
// same body projects the 64-bit dlopen targets and the wasm32 browser module.
// Zig alone owns the CapTP wire codecs and protocol semantics.
// All of this is package-internal — the peer/vat/connection
// modules import what they need (`encodeArgs`, `readArg`, `readArgArray`,
// `refStruct`, `readReference`); the barrel exposes none of it. `encodeArg` and
// `writeReference` are module-private, used only by their exported wrappers.

import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { L } from "./internal/layout.ts";
import { readBytes } from "./internal/seam.ts";
import {
	ARG_BIG_INTEGER,
	ARG_BOOLEAN,
	ARG_BYTES,
	ARG_ERROR,
	ARG_FLOAT64,
	ARG_INTEGER,
	ARG_KEYWORD,
	ARG_LIST,
	ARG_REFERENCE,
	ARG_SET,
	ARG_STRING,
	ARG_STRUCT,
	ARG_SYMBOL,
	ARG_TAGGED,
	ARG_VOID,
	INTERNAL,
	UNSUPPORTED_VALUE,
} from "@pancake/abi";
import { PancakeError } from "./errors.ts";
import { type Argument, isReference, Kw, PSet, PStruct, Ref, refFromId, Sym, Tagged } from "./value.ts";

function writeReference(dv: DataView, off: number, ref: Ref): void {
	if (ref.released) {
		throw new Error("pancake: this capability was released and is no longer usable");
	}
	dv.setBigUint64(off + L.REF_ID_OFF, ref.id, true);
}

export function refStruct(ref: Ref): Uint8Array {
	const buf = new Uint8Array(L.REF_SIZE);
	writeReference(new DataView(buf.buffer), 0, ref);
	return buf;
}

// Encodes args into one contiguous Uint8Array of ARG_SIZE structs, pushing any
// backing byte/child buffers onto `keep` so they outlive the FFI call.
export function encodeArgs(args: Argument[], keep: Uint8Array[]): Uint8Array {
	const buf = new Uint8Array(L.ARG_SIZE * args.length);
	const dv = new DataView(buf.buffer);
	args.forEach((arg, i) => encodeArg(dv, i * L.ARG_SIZE, arg, keep));
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
		dv.setUint32(off + L.ARG_KIND_OFF, kind, true);
		L.setPtr(dv, off + L.ARG_BYTES_OFF, ffi.pointerOf(bytes));
		L.setUsize(dv, off + L.ARG_BYTES_LEN_OFF, bytes.length);
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
			dv.setUint32(off + L.ARG_BOOLEAN_OFF, negative ? 1 : 0, true);
		} else {
			dv.setUint32(off + L.ARG_KIND_OFF, ARG_INTEGER, true);
			dv.setBigInt64(off + L.ARG_INTEGER_OFF, arg, true);
		}
	} else if (typeof arg === "number") {
		dv.setUint32(off + L.ARG_KIND_OFF, ARG_FLOAT64, true);
		dv.setFloat64(off + L.ARG_FLOAT64_OFF, arg, true);
	} else if (typeof arg === "boolean") {
		dv.setUint32(off + L.ARG_KIND_OFF, ARG_BOOLEAN, true);
		dv.setUint32(off + L.ARG_BOOLEAN_OFF, arg ? 1 : 0, true);
	} else if (arg instanceof Uint8Array) {
		setBytes(ARG_BYTES, arg);
	} else if (arg instanceof Sym) {
		setBytes(ARG_SYMBOL, new TextEncoder().encode(arg.value));
	} else if (arg instanceof Kw) {
		setBytes(ARG_KEYWORD, new TextEncoder().encode(arg.value));
	} else if (typeof arg === "string") {
		setBytes(ARG_STRING, new TextEncoder().encode(arg));
	} else if (arg instanceof Error) {
		// Returning an Error fulfills with an OCapN Error value. Throwing it is
		// the separate operation that breaks a reply.
		setBytes(ARG_ERROR, new TextEncoder().encode(arg.message));
	} else if (arg === null) {
		dv.setUint32(off + L.ARG_KIND_OFF, ARG_VOID, true);
	} else if (isReference(arg)) {
		dv.setUint32(off + L.ARG_KIND_OFF, ARG_REFERENCE, true);
		writeReference(dv, off + L.ARG_REFERENCE_OFF, arg);
	} else if (Array.isArray(arg)) {
		writeItems(ARG_LIST, arg);
	} else if (arg instanceof PSet) {
		writeItems(ARG_SET, arg.items);
	} else if (arg instanceof Tagged) {
		setBytes(ARG_TAGGED, new TextEncoder().encode(arg.tag));
		writeItems(ARG_TAGGED, arg.value);
	} else if (arg instanceof PStruct) {
		const flat: Argument[] = [];
		for (const [key, value] of arg.entries) flat.push(key, value);
		writeItems(ARG_STRUCT, flat);
	} else {
		throw new PancakeError(UNSUPPORTED_VALUE, "unsupported argument value");
	}

	function writeItems(kind: number, items: Argument[]): void {
		dv.setUint32(off + L.ARG_KIND_OFF, kind, true);
		const child = encodeArgs(items, keep);
		L.setPtr(dv, off + L.ARG_ITEMS_OFF, ffi.pointerOf(child));
		L.setUsize(dv, off + L.ARG_ITEMS_LEN_OFF, items.length);
	}
}

export function readReference(view: DataView, off: number): Ref {
	return refFromId(view.getBigUint64(off + L.REF_ID_OFF, true));
}

export function readArg(view: DataView, off: number): Argument {
	// The `(bytes, len)` and `(items, len)` pairs each appear in several arms; read
	// them through one spelling so the ARG struct layout lives in one place.
	const argBytes = () =>
		readBytes(
			L.getPtr(view, off + L.ARG_BYTES_OFF),
			L.getUsize(view, off + L.ARG_BYTES_LEN_OFF),
		);
	const argString = () => new TextDecoder().decode(argBytes());
	const argItems = () =>
		readArgArray(
			L.getPtr(view, off + L.ARG_ITEMS_OFF),
			L.getUsize(view, off + L.ARG_ITEMS_LEN_OFF),
		);
	const kind = view.getUint32(off + L.ARG_KIND_OFF, true);
	switch (kind) {
		case ARG_INTEGER:
			return view.getBigInt64(off + L.ARG_INTEGER_OFF, true);
		case ARG_FLOAT64:
			return view.getFloat64(off + L.ARG_FLOAT64_OFF, true);
		case ARG_BOOLEAN:
			return view.getUint32(off + L.ARG_BOOLEAN_OFF, true) !== 0;
		case ARG_BYTES:
			return argBytes();
		case ARG_STRING:
			return argString();
		case ARG_SYMBOL:
			return new Sym(argString());
		case ARG_ERROR:
			return new Error(argString());
		case ARG_REFERENCE:
			return readReference(view, off + L.ARG_REFERENCE_OFF);
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
			return view.getUint32(off + L.ARG_BOOLEAN_OFF, true) !== 0 ? -magnitude : magnitude;
		}
		case ARG_STRUCT: {
			const flat = argItems();
			if (flat.length % 2 !== 0) {
				throw new PancakeError(INTERNAL, "pancake ABI returned an odd Struct item count");
			}
			const entries: Array<readonly [string, Argument]> = [];
			for (let i = 0; i < flat.length; i += 2) {
				if (typeof flat[i] !== "string") {
					throw new PancakeError(INTERNAL, "pancake ABI returned a non-String Struct key");
				}
				entries.push([flat[i] as string, flat[i + 1]]);
			}
			return new PStruct(entries);
		}
		default:
			throw new PancakeError(
				INTERNAL,
				`pancake ABI returned unknown argument kind ${kind}`,
			);
	}
}

export function readArgArray(ptrValue: Ptr, len: bigint): Argument[] {
	if (ptrValue === NULL || len === 0n) return [];
	const view = new DataView(ffi.readMemory(ptrValue, Number(len) * L.ARG_SIZE));
	const out: Argument[] = [];
	for (let i = 0; i < Number(len); i++) out.push(readArg(view, i * L.ARG_SIZE));
	return out;
}
