// Internal: the Node runtime adapter (experimental).
//
// Node's built-in `node:ffi` (added in Node 26, behind `--experimental-ffi`)
// and its `node:net` sockets provide the runtime seams declared in
// `../runtime.ts`. Node already models a pointer as a `bigint`, so this adapter
// does no per-call pointer conversion, it only translates the FFI type
// vocabulary and takes addresses through `ffi.getRawPointer`.
//
// This path is experimental and ungated: it requires Node 26+ run with
// `--experimental-ffi` (and `--allow-ffi` under the permission model), and
// `node:ffi` itself is a stability-1 API. It is shipped so a Node consumer can
// try the binding; it is not covered by a build gate.

// @ts-nocheck, typed against node:ffi/node:net ambient types, present under Node.
import * as ffiMod from "node:ffi";
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

function nodeType(t: NativeType): string {
	switch (t) {
		case "usize":
			return "u64";
		default:
			return t;
	}
}

function nodeSig(def: SymbolDef): { arguments: string[]; return: string } {
	return {
		arguments: def.parameters.map(nodeType),
		return: nodeType(def.result),
	};
}

// The most recently loaded library; callbacks register against it. The core
// archive loads first and stays loaded, so it is always available here.
let lastLib: {
	registerCallback: (sig: unknown, fn: unknown) => bigint;
	unregisterCallback: (p: bigint) => void;
	refCallback: (p: bigint) => void;
} | null = null;

const ffi: RuntimeFfi = {
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols {
		const definitions: Record<string, { arguments: string[]; return: string }> = {};
		for (const [name, def] of Object.entries(defs)) {
			definitions[name] = nodeSig(def);
		}
		const { lib, functions } = ffiMod.dlopen(path, definitions);
		lastLib = lib;
		// Node pointers are bigint already; the resolved wrappers need no per-call
		// conversion, so they are the seam's symbols directly.
		return functions as Symbols;
	},

	pointerOf(buf: Uint8Array): Ptr {
		if (buf.byteLength === 0) return 0n;
		return ffiMod.getRawPointer(buf.buffer) + BigInt(buf.byteOffset);
	},

	readMemory(p: Ptr, len: number): ArrayBuffer {
		if (p === 0n || len === 0) return new ArrayBuffer(0);
		return ffiMod.toArrayBuffer(p, len, true);
	},

	makeCallback(
		def: SymbolDef,
		fn: (...args: unknown[]) => unknown,
	): NativeCallback {
		if (lastLib === null) {
			throw new Error(
				"node:ffi callback requested before any library was loaded",
			);
		}
		const lib = lastLib;
		const pointer = lib.registerCallback(nodeSig(def), fn);
		lib.refCallback(pointer);
		return {
			pointer,
			close: () => lib.unregisterCallback(pointer),
		};
	},

	libSuffix() {
		return ffiMod.suffix as "so" | "dylib" | "dll";
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
