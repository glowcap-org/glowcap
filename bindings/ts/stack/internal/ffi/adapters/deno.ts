// Internal: the Deno runtime adapter.
//
// Deno's FFI (`Deno.dlopen`, `Deno.UnsafePointer`, `Deno.UnsafePointerView`,
// `Deno.UnsafeCallback`) and its native sockets (`Deno.connect`/`Deno.listen`)
// implement the runtime seams declared in `../runtime.ts`. Pointers cross the
// seam as `bigint`; the shared spine in `ptr_wrap.ts` converts to and from
// Deno's opaque `PointerValue` at each call so the layers above hold one
// representation.

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

// deno-lint-ignore no-explicit-any
const D = (globalThis as any).Deno;

// Deno's FFI type names match our vocabulary one for one.
function denoType(t: NativeType): Deno.NativeType {
	return t as Deno.NativeType;
}

function denoDef(def: SymbolDef): Deno.ForeignFunction {
	return {
		parameters: def.parameters.map(denoType),
		result: denoType(def.result),
		...(def.nonblocking ? { nonblocking: true } : {}),
	};
}

const bridge: PtrBridge<Deno.PointerValue> = {
	toPtr(p: Deno.PointerValue): Ptr {
		return p === null ? 0n : BigInt(D.UnsafePointer.value(p));
	},
	fromPtr(p: Ptr): Deno.PointerValue {
		return D.UnsafePointer.create(p);
	},
};

const ffi: RuntimeFfi = {
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols {
		const denoDefs: Record<string, Deno.ForeignFunction> = {};
		for (const [name, def] of Object.entries(defs)) {
			denoDefs[name] = denoDef(def);
		}
		return wrapSymbols(defs, D.dlopen(path, denoDefs).symbols, bridge);
	},

	makeCallback(
		def: SymbolDef,
		fn: (...args: unknown[]) => unknown,
	): NativeCallback {
		const cb = new D.UnsafeCallback(denoDef(def), wrapCallbackFn(def, fn, bridge));
		return {
			pointer: bridge.toPtr(cb.pointer),
			close: () => cb.close(),
		};
	},

	pointerOf(buf: Uint8Array): Ptr {
		// 0n for an empty buffer, matching the RuntimeFfi contract and the bun
		// adapter explicitly rather than relying on `UnsafePointer.of` returning
		// null for a zero-length view.
		if (buf.byteLength === 0) return 0n;
		return bridge.toPtr(D.UnsafePointer.of(buf));
	},

	readMemory(ptr: Ptr, len: number): ArrayBuffer {
		if (ptr === 0n || len === 0) return new ArrayBuffer(0);
		const view = new D.UnsafePointerView(bridge.fromPtr(ptr));
		// getArrayBuffer copies; slice keeps the result owned regardless.
		return (view.getArrayBuffer(len) as ArrayBuffer).slice(0);
	},

	writeMemory(ptr: Ptr, bytes: Uint8Array): void {
		if (ptr === 0n || bytes.length === 0) return;
		// getArrayBuffer here is a live view over the native memory, so writing
		// through it writes the pointer's bytes directly.
		const view = new D.UnsafePointerView(bridge.fromPtr(ptr));
		new Uint8Array(view.getArrayBuffer(bytes.length) as ArrayBuffer).set(bytes);
	},

	libSuffix() {
		return D.build.os === "darwin" ? "dylib" : D.build.os === "windows" ? "dll" : "so";
	},
};

function wrapConn(conn: Deno.Conn): NetConn {
	return {
		async read(): Promise<Uint8Array | null> {
			const buf = new Uint8Array(64 * 1024);
			const n = await conn.read(buf);
			return n === null ? null : buf.subarray(0, n);
		},
		async write(data: Uint8Array): Promise<void> {
			let off = 0;
			while (off < data.length) off += await conn.write(data.subarray(off));
		},
		close(): void {
			try {
				conn.close();
			} catch {
				// already closed
			}
		},
		localAddr() {
			const a = conn.localAddr as Deno.NetAddr;
			return { hostname: a.hostname, port: a.port };
		},
	};
}

const net: RuntimeNet = {
	async connect(host: string, port: number): Promise<NetConn> {
		return wrapConn(await D.connect({ hostname: host, port }));
	},
	listen(host: string, port: number): Promise<NetListener> {
		const listener = D.listen({ hostname: host, port });
		const addr = listener.addr as Deno.NetAddr;
		const boundHost = addr.hostname;
		const boundPort = addr.port;
		return Promise.resolve({
			port: boundPort,
			localAddr(): { hostname: string; port: number } {
				return { hostname: boundHost, port: boundPort };
			},
			async accept(): Promise<NetConn> {
				return wrapConn(await listener.accept());
			},
			close(): void {
				try {
					listener.close();
				} catch {
					// Idempotent: the async-iterator finally may already have closed.
				}
			},
		});
	},
};

export const adapter: RuntimeAdapter = { ffi, net };
