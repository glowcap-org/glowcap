// Internal: the one place the binding touches a runtime.
//
// The whole binding is runtime-neutral TypeScript except for two seams: the FFI
// that loads the pancake archives and calls their symbols, and the sockets the
// async transport rides. This module declares both as interfaces, detects which
// JavaScript runtime is hosting the binding (Deno or Bun), and loads the
// matching adapter. Everything above — `mod.ts`, the transport modules, the
// actor and connection layers — speaks these interfaces and never names a
// runtime.
//
// The adapter is pulled in with a dynamic `import()` keyed on the detected
// runtime, so a runtime-specific module (`bun:ffi`) is only ever resolved on
// the runtime that has it. Selection happens at module load through top-level
// await; every dependent module that imports `ffi` / `net` waits for it, so
// the symbol tables and sockets are ready by the time application code runs.
//
// Pointers cross this seam as `bigint` addresses (`0n` is null). Deno's opaque
// `PointerValue` and Bun's numeric pointers are converted to and from `bigint`
// inside their adapters, so the layers above hold one pointer representation.

/** A native pointer as a `bigint` address. `0n` is the null pointer. */
export type Ptr = bigint;

/** The null pointer. */
export const NULL: Ptr = 0n;

/** The FFI type vocabulary the symbol tables use. Each adapter maps these to its
 * runtime's own FFI type names. `usize` is pointer-width; `pointer` is an opaque
 * handle passed as a `bigint`; `buffer` is a JS byte buffer whose backing memory
 * the call borrows. */
export type NativeType =
	| "void"
	| "bool"
	| "u16"
	| "i32"
	| "u32"
	| "i64"
	| "u64"
	| "usize"
	| "f64"
	| "pointer"
	| "buffer";

/** A C function signature: the parameter types and the result type. `nonblocking`
 * asks the runtime to run the call off the event-loop thread and return a
 * promise (honored by Deno; the Bun adapter runs it synchronously). */
export interface SymbolDef {
	parameters: readonly NativeType[];
	result: NativeType;
	nonblocking?: boolean;
}

/** A loaded archive's callable symbols. A `pointer` parameter takes a `Ptr`
 * (`bigint`); a `buffer` parameter takes a `Uint8Array` (or `null`); a `pointer`
 * result comes back as a `Ptr`. */
// deno-lint-ignore no-explicit-any
export type Symbols = Record<string, (...args: any[]) => any>;

/** A native callback backed by a JS function: its address and a release. The
 * function receives `bigint` for every pointer and 64-bit argument and returns a
 * `bigint` for a pointer result (or nothing for `void`). */
export interface NativeCallback {
	readonly pointer: Ptr;
	close(): void;
}

/** The FFI seam: load an archive, mint a native callback, take the address of a
 * JS buffer, read and write native memory, and name the platform's
 * shared-library suffix. */
export interface RuntimeFfi {
	/** Load the shared library at `path`, resolving `defs` into callable symbols.
	 * Throws if the library or a symbol is missing. */
	dlopen(path: string, defs: Record<string, SymbolDef>): Symbols;
	/** A native callback over `fn` with signature `def`. Deno and Bun both
	 * register callbacks globally (a callback pointer is callable from any
	 * loaded archive), so one runtime-level factory serves every library. Keep
	 * the handle alive while native code may invoke it; `close` releases it. */
	// deno-lint-ignore no-explicit-any
	makeCallback(def: SymbolDef, fn: (...args: any[]) => any): NativeCallback;
	/** The address of `buf`'s backing memory, stable only for the synchronous
	 * window in which it is used. `0n` for an empty buffer. */
	pointerOf(buf: Uint8Array): Ptr;
	/** A freshly-owned copy of `len` bytes at `ptr`. Empty for a null pointer or
	 * zero length. */
	readMemory(ptr: Ptr, len: number): ArrayBuffer;
	/** Write `bytes` into native memory at `ptr` (the inverse of `readMemory`),
	 * for filling a C out-parameter a callback is handed by pointer. No-op for a
	 * null pointer. */
	writeMemory(ptr: Ptr, bytes: Uint8Array): void;
	/** The platform's shared-library suffix: `so`, `dylib`, or `dll`. */
	libSuffix(): "so" | "dylib" | "dll";
}

/** One end of a TCP connection: whole-duplex byte I/O the async pump drives. */
export interface NetConn {
	/** The next chunk of inbound bytes, or `null` at a clean end of stream. */
	read(): Promise<Uint8Array | null>;
	/** Write every byte of `data`, awaiting the runtime's flush/backpressure. */
	write(data: Uint8Array): Promise<void>;
	close(): void;
	/** This socket's own bound address, the locator a keyed start-session signs. */
	localAddr(): { hostname: string; port: number };
}

/** A bound TCP listener that hands back one `NetConn` per accepted partner. */
export interface NetListener {
	readonly port: number;
	/** This listener's own bound address (kernel view; IPv6 hosts unbracketed). */
	localAddr(): { hostname: string; port: number };
	accept(): Promise<NetConn>;
	close(): void;
}

/** The socket seam: dial a partner, bind a listener. Both resolve once the
 * runtime reports the operation complete (so a listener's `port` is known). */
export interface RuntimeNet {
	connect(host: string, port: number): Promise<NetConn>;
	listen(host: string, port: number): Promise<NetListener>;
}

/** The adapter a runtime provides: its FFI seam and its socket seam. */
export interface RuntimeAdapter {
	ffi: RuntimeFfi;
	net: RuntimeNet;
}

// The two runtime globals this binding probes for. Bun and Deno each expose a
// namesake global; anything else is unsupported and fails loud.
const g = globalThis as { Bun?: unknown; Deno?: { dlopen?: unknown } };

/** The detected host runtime. */
export type RuntimeName = "deno" | "bun";

function detectRuntime(): RuntimeName {
	if (typeof g.Bun !== "undefined") return "bun";
	if (typeof g.Deno !== "undefined" && typeof g.Deno.dlopen === "function") {
		return "deno";
	}
	throw new Error("unsupported runtime (Deno and Bun are supported)");
}

async function loadAdapter(): Promise<RuntimeAdapter> {
	// A computed specifier keeps a static analyzer (Deno's `deno check`, a
	// bundler) from following into a runtime it cannot resolve: `bun.ts` imports
	// `bun:ffi`, which does not exist under Deno. The matching adapter is the
	// only one ever loaded at runtime.
	const file = `./adapters/${detectRuntime()}.ts`;
	return (await import(file)).adapter;
}

const selected = await loadAdapter();

/** The host runtime's FFI seam. */
export const ffi: RuntimeFfi = selected.ffi;

/** The host runtime's socket seam. */
export const net: RuntimeNet = selected.net;
