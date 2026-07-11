// Internal: the Bun runtime adapter.
//
// Bun's FFI (`bun:ffi`: `dlopen`, `ptr`, `toArrayBuffer`, `JSCallback`,
// `FFIType`) and the `node:net` sockets Bun implements provide the runtime seams
// declared in `../runtime.ts`. Bun models a pointer as a JavaScript number; the
// shared spine in `ptr_wrap.ts` converts to and from `bigint` at the seam so the
// layers above hold one representation.

// @ts-nocheck, typed against Bun's ambient types, which only exist under Bun.
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
import { type PtrBridge, wrapCallbackFn, wrapSymbols } from "./ptr_wrap.ts";

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
const bridge: PtrBridge<number | null> = {
	toPtr(p: number | null): Ptr {
		return p === null || p === 0 ? 0n : BigInt(p);
	},
	fromPtr(p: Ptr): number | null {
		return p === 0n ? null : Number(p);
	},
};

const ffi: RuntimeFfi = {
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols {
		const symbolDefs: Record<string, { args: FFIType[]; returns: FFIType }> = {};
		for (const [name, def] of Object.entries(defs)) {
			symbolDefs[name] = bunDef(def);
		}
		return wrapSymbols(defs, bunDlopen(path, symbolDefs).symbols, bridge);
	},

	makeCallback(
		def: SymbolDef,
		fn: (...args: unknown[]) => unknown,
	): NativeCallback {
		const cb = new JSCallback(wrapCallbackFn(def, fn, bridge), bunDef(def));
		return {
			pointer: bridge.toPtr(cb.ptr),
			close: () => cb.close(),
		};
	},

	pointerOf(buf: Uint8Array): Ptr {
		if (buf.byteLength === 0) return 0n;
		return bridge.toPtr(ptr(buf));
	},

	readMemory(p: Ptr, len: number): ArrayBuffer {
		if (p === 0n || len === 0) return new ArrayBuffer(0);
		// toArrayBuffer is a view onto native memory; slice keeps the copy owned.
		return toArrayBuffer(Number(p), 0, len).slice(0);
	},

	writeMemory(p: Ptr, bytes: Uint8Array): void {
		if (p === 0n || bytes.length === 0) return;
		// toArrayBuffer (unsliced) is a live view onto native memory.
		new Uint8Array(toArrayBuffer(Number(p), 0, bytes.length)).set(bytes);
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
