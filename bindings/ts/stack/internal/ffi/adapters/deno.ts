// Internal: the Deno runtime adapter.
//
// Deno's FFI (`Deno.dlopen`, `Deno.UnsafePointer`, `Deno.UnsafePointerView`,
// `Deno.UnsafeCallback`) and its native sockets (`Deno.connect`/`Deno.listen`)
// implement the runtime seams declared in `../runtime.ts`. Pointers cross the
// seam as `bigint`; this adapter converts to and from Deno's opaque
// `PointerValue` at each call so the layers above hold one representation.

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

function toPtr(p: Deno.PointerValue): Ptr {
	return p === null ? 0n : BigInt(D.UnsafePointer.value(p));
}

function fromPtr(p: Ptr): Deno.PointerValue {
	return D.UnsafePointer.create(p);
}

const ffi: RuntimeFfi = {
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols {
		const denoDefs: Record<string, Deno.ForeignFunction> = {};
		for (const [name, def] of Object.entries(defs)) {
			denoDefs[name] = denoDef(def);
		}
		const lib = D.dlopen(path, denoDefs);
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
			// deno-lint-ignore no-explicit-any
			out[name] = (...args: any[]) => {
				for (const i of ptrParams) args[i] = fromPtr(args[i] as Ptr);
				const r = fn(...args);
				return ptrResult ? toPtr(r as Deno.PointerValue) : r;
			};
		}
		return out;
	},

	pointerOf(buf: Uint8Array): Ptr {
		return toPtr(D.UnsafePointer.of(buf));
	},

	readMemory(ptr: Ptr, len: number): ArrayBuffer {
		if (ptr === 0n || len === 0) return new ArrayBuffer(0);
		const view = new D.UnsafePointerView(fromPtr(ptr));
		// getArrayBuffer copies; slice keeps the result owned regardless.
		return (view.getArrayBuffer(len) as ArrayBuffer).slice(0);
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
		const cb = new D.UnsafeCallback(
			denoDef(def),
			// deno-lint-ignore no-explicit-any
			(...args: any[]) => {
				for (const i of ptrParams) {
					args[i] = toPtr(args[i] as Deno.PointerValue);
				}
				const r = fn(...args);
				return ptrResult ? fromPtr(r as Ptr) : r;
			},
		);
		return {
			pointer: toPtr(cb.pointer),
			close: () => cb.close(),
		};
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
		const bound = (listener.addr as Deno.NetAddr).port;
		return Promise.resolve({
			port: bound,
			async accept(): Promise<NetConn> {
				return wrapConn(await listener.accept());
			},
			close(): void {
				listener.close();
			},
		});
	},
};

export const adapter: RuntimeAdapter = { ffi, net };
