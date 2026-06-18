// Internal: the Bun runtime adapter.
//
// Bun's FFI (`bun:ffi`: `dlopen`, `ptr`, `toArrayBuffer`, `JSCallback`,
// `FFIType`) and the `node:net` sockets Bun implements provide the runtime seams
// declared in `../runtime.ts`. Bun models a pointer as a JavaScript number; this
// adapter converts to and from `bigint` at the seam so the layers above hold one
// representation.

// @ts-nocheck — typed against Bun's ambient types, which only exist under Bun.
import { dlopen as bunDlopen, FFIType, JSCallback, ptr, toArrayBuffer } from "bun:ffi";
import { socketConnect, socketListen } from "./node_net.ts";
import type {
	NativeCallback,
	NativeType,
	NetConn,
	NetListener,
	Ptr,
	RuntimeAdapter,
	RuntimeFfi,
	RuntimeNet,
	SymbolDef,
	Symbols,
} from "../runtime.ts";

function bunType(t: NativeType): FFIType {
	switch (t) {
		case "void":
			return FFIType.void;
		case "bool":
			return FFIType.bool;
		case "u16":
			return FFIType.u16;
		case "i32":
			return FFIType.i32;
		case "u32":
			return FFIType.u32;
		case "i64":
			return FFIType.i64;
		case "u64":
			return FFIType.u64;
		case "usize":
			return FFIType.u64;
		case "f64":
			return FFIType.f64;
		case "pointer":
		case "buffer":
			return FFIType.ptr;
	}
}

function bunDef(def: SymbolDef): { args: FFIType[]; returns: FFIType } {
	return { args: def.parameters.map(bunType), returns: bunType(def.result) };
}

// Bun pointers are numbers; the seam speaks bigint.
function toPtr(p: number | null): Ptr {
	return p === null || p === 0 ? 0n : BigInt(p);
}
function fromPtr(p: Ptr): number | null {
	return p === 0n ? null : Number(p);
}

const ffi: RuntimeFfi = {
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols {
		const symbolDefs: Record<string, { args: FFIType[]; returns: FFIType }> = {};
		for (const [name, def] of Object.entries(defs)) {
			symbolDefs[name] = bunDef(def);
		}
		const lib = bunDlopen(path, symbolDefs);
		const out: Symbols = {};
		for (const [name, def] of Object.entries(defs)) {
			const fn = lib.symbols[name];
			const ptrParams: number[] = [];
			def.parameters.forEach((t, i) => {
				if (t === "pointer") ptrParams.push(i);
			});
			const ptrResult = def.result === "pointer";
			if (ptrParams.length === 0 && !ptrResult) {
				out[name] = fn;
				continue;
			}
			out[name] = (...args: unknown[]) => {
				for (const i of ptrParams) args[i] = fromPtr(args[i] as Ptr);
				const r = fn(...args);
				return ptrResult ? toPtr(r as number | null) : r;
			};
		}
		return out;
	},

	pointerOf(buf: Uint8Array): Ptr {
		if (buf.byteLength === 0) return 0n;
		return toPtr(ptr(buf));
	},

	readMemory(p: Ptr, len: number): ArrayBuffer {
		if (p === 0n || len === 0) return new ArrayBuffer(0);
		// toArrayBuffer is a view onto native memory; slice keeps the copy owned.
		return toArrayBuffer(Number(p), 0, len).slice(0);
	},

	makeCallback(
		def: SymbolDef,
		fn: (...args: unknown[]) => unknown,
	): NativeCallback {
		const ptrParams: number[] = [];
		def.parameters.forEach((t, i) => {
			if (t === "pointer") ptrParams.push(i);
		});
		const ptrResult = def.result === "pointer";
		const cb = new JSCallback(
			(...args: unknown[]) => {
				for (const i of ptrParams) args[i] = toPtr(args[i] as number | null);
				const r = fn(...args);
				return ptrResult ? fromPtr(r as Ptr) : r;
			},
			bunDef(def),
		);
		return {
			pointer: toPtr(cb.ptr),
			close: () => cb.close(),
		};
	},

	libSuffix() {
		return process.platform === "darwin"
			? "dylib"
			: process.platform === "win32"
			? "dll"
			: "so";
	},
};

const net: RuntimeNet = {
	connect(host: string, port: number): Promise<NetConn> {
		return socketConnect(host, port);
	},
	listen(host: string, port: number): Promise<NetListener> {
		return socketListen(host, port);
	},
};

export const adapter: RuntimeAdapter = { ffi, net };
