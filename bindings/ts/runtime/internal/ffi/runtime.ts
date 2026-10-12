// Internal: the one place the binding touches a runtime.
//
// The whole binding is runtime-neutral TypeScript except for two seams: the FFI
// that loads the glowcap archives and calls their symbols, and the sockets the
// async transport rides. This module declares both as interfaces, detects which
// JavaScript runtime is hosting the binding (Deno or Bun), and loads the
// matching adapter. Everything above (`mod.ts`, the transport modules, the
// actor and connection layers) speaks these interfaces and never names a
// runtime.
//
// Deno's adapter is selected synchronously. Bun's adapter is pulled in with a
// dynamic `import()` only when `ensureRuntimeReady` is awaited, so `bun:ffi`
// stays off every other runtime's static graph. A browser injects its wasm
// adapter before importing this module. No module-level top-level await is
// used: symbol tables open lazily on their first real call.
//
// Pointers cross this seam as `bigint` addresses (`0n` is null). Deno's opaque
// `PointerValue` and Bun's numeric pointers are converted to and from `bigint`
// inside their adapters, so the layers above hold one pointer representation.

import { type AbiLayout, layout64, setActiveLayout } from "../layout.ts";
// Deno's adapter constructs synchronously (it touches only `Deno.*` globals,
// and only inside its methods), so it can be static-imported and selected
// without a top-level await. Bun's adapter imports `bun:ffi` and is loaded
// lazily instead, keeping that runtime-only specifier off Deno's and the
// browser bundle's static graph.
import { adapter as denoAdapter } from "./adapters/deno.ts";

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
	| "u8"
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
 * promise (honored by Deno; the Bun adapter runs it synchronously).
 * `outBuffers` names the `buffer` parameter indexes the callee writes into:
 * the dlopen adapters ignore it (calls borrow the JS memory directly), and
 * the wasm adapter copies only those buffers back out of linear memory after
 * the call, so an input-only buffer (a fed frame chunk) never pays a
 * copy-back. Undefined means every buffer is copied back, the safe default
 * for an unannotated table. */
export interface SymbolDef {
	parameters: readonly NativeType[];
	result: NativeType;
	nonblocking?: boolean;
	outBuffers?: readonly number[];
}

/** A loaded archive's callable symbols. A `pointer` parameter takes a `Ptr`
 * (`bigint`); a `buffer` parameter takes a `Uint8Array` (or `null`); a `pointer`
 * result comes back as a `Ptr`. */
// deno-lint-ignore no-explicit-any
export type Symbols = Record<string, (...args: any[]) => any>;

export interface ArchiveFingerprint {
	readonly symbol: string;
	readonly expected: bigint;
	readonly archive: string;
}

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
	/** Whether a `SymbolDef.nonblocking` call leaves this JavaScript
	 * event-loop thread. A promise-shaped wrapper is not enough: transports use
	 * this capability before entering a native call that may wait on I/O. */
	offloadsBlockingCalls(): boolean;
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
	 * window in which it is used. Concretely: valid across at most one
	 * subsequent outermost symbol call (the wasm adapter stages a copy and
	 * frees stale stagings at call entry; a caller that retries a call must
	 * re-take its pointers). `0n` for an empty buffer. */
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

/** The adapter a runtime provides: its FFI seam and its socket seam, plus an
 * optional ABI layout when the target's struct offsets differ from the
 * generated 64-bit mirror (the browser adapter reports wasm32 offsets). */
export interface RuntimeAdapter {
	ffi: RuntimeFfi;
	net: RuntimeNet;
	layout?: AbiLayout;
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

/** The global key an out-of-package adapter installs itself under, before it
 * imports the runtime. The browser package (`bindings/ts/web`) instantiates the
 * wasm module, builds its adapter (FFI over linear memory, sockets over
 * WebSocket, layout from the module's own descriptor), sets this global, and
 * only then imports `@glowcap/runtime`, so this seam resolves it here instead
 * of probing for a runtime the browser does not have. */
export const injected_adapter_key = Symbol.for("glowcap.runtime.adapter");

/** The active adapter, resolved without a top-level await. An injected
 * adapter (the wasm browser binding) and Deno resolve here synchronously; Bun
 * is undefined until `ensureRuntimeReady` loads it. Keeping this module free
 * of top-level await is what lets a browser bundle it into one file: esbuild
 * flattens every module's top-level await, and the runtime's import graph
 * deadlocks around one. */
function resolveSync(): RuntimeAdapter | undefined {
	const injected = (globalThis as Record<symbol, unknown>)[injected_adapter_key];
	if (injected !== undefined) return injected as RuntimeAdapter;
	if (typeof g.Bun === "undefined" && typeof g.Deno?.dlopen === "function") {
		return denoAdapter;
	}
	return undefined;
}

let selected: RuntimeAdapter | undefined = resolveSync();
if (selected) setActiveLayout(selected.layout ?? layout64);

// True once the active adapter has been used for real work (`active()` handed
// it to an FFI or socket op). Before this, an explicit injection may still
// override an auto-resolved adapter; after it, the adapter is committed and can
// never be swapped, because a cached symbol table would point at the wrong
// runtime.
let committed = false;

let readying: Promise<RuntimeAdapter> | undefined;

// Adopt an adapter injected after this module loaded. The browser binding sets
// its global then imports the runtime, but a static import chain may have
// evaluated this module first, so the injection can land after `resolveSync`
// already picked the host's own adapter. An explicit injection (the wasm
// browser binding, ADR-0070) is authoritative: it overrides an adapter
// auto-resolved from the host runtime, so a Deno or Bun process that
// instantiates a wasm peer (a browser peer under test, or a relay harness)
// runs on the injected adapter instead of its own native FFI. The override is
// safe only before the auto-resolved adapter is committed to real work; after
// that its symbol tables are live, so a committed adapter is never swapped.
// Both the synchronous `active()` and the async `ensureRuntimeReady()` resolve
// through here. Idempotent once the injected adapter is the selected one.
function adoptInjectedAdapter(): void {
	const injected = (globalThis as Record<symbol, unknown>)[injected_adapter_key];
	if (injected === undefined || selected === injected) return;
	if (selected !== undefined && committed) return;
	selected = injected as RuntimeAdapter;
	setActiveLayout(selected.layout ?? layout64);
}

/** Ensure the FFI runtime is resolved. Deno and the injected browser adapter
 * are ready synchronously at import; Bun loads its adapter here (its `bun:ffi`
 * import is off the static graph). Await this before the first FFI or socket
 * use on Bun; the async public entry points (`connect`, `listen`, a `Server`'s
 * accept) already do. Idempotent. */
export function ensureRuntimeReady(): Promise<RuntimeAdapter> {
	// A browser adapter injected after this module loaded resolves here too: the
	// async `connect`/`listen` path awaits this before its first dial, so without
	// this check it would fall through to `detectRuntime()` and wrongly reject the
	// injected wasm adapter as an unsupported runtime.
	adoptInjectedAdapter();
	if (selected) return Promise.resolve(selected);
	readying ??= (async () => {
		const file = `./adapters/${detectRuntime()}.ts`;
		const adapter = (await import(file)).adapter as RuntimeAdapter;
		selected = adapter;
		setActiveLayout(adapter.layout ?? layout64);
		return adapter;
	})();
	return readying;
}

function active(): RuntimeAdapter {
	adoptInjectedAdapter();
	if (!selected) {
		throw new Error(
			"glowcap: FFI runtime not ready — await ensureRuntimeReady() before " +
				"the first FFI/socket use (Bun); Deno and the browser resolve synchronously",
		);
	}
	// The adapter is handed to a real FFI/socket op; lock it so a later
	// injection cannot swap a runtime whose symbol tables are already live.
	committed = true;
	return selected;
}

/** The host runtime's FFI seam. Delegates to the active adapter so this module
 * needs no top-level await; the adapter is resolved by the time any real call
 * lands (synchronously on Deno and the browser, after `ensureRuntimeReady` on
 * Bun). */
export const ffi: RuntimeFfi = {
	offloadsBlockingCalls: () => active().ffi.offloadsBlockingCalls(),
	dlopen: (path, defs) => active().ffi.dlopen(path, defs),
	makeCallback: (def, fn) => active().ffi.makeCallback(def, fn),
	pointerOf: (buf) => active().ffi.pointerOf(buf),
	readMemory: (ptr, len) => active().ffi.readMemory(ptr, len),
	writeMemory: (ptr, bytes) => active().ffi.writeMemory(ptr, bytes),
	libSuffix: () => active().ffi.libSuffix(),
};

/** The host runtime's socket seam. Delegates to the active adapter for the
 * same reason as `ffi`. */
export const net: RuntimeNet = {
	connect: (host, port) => active().net.connect(host, port),
	listen: (host, port) => active().net.listen(host, port),
};

/** A lazily-opened archive: the library is `dlopen`ed on first symbol access,
 * not at module load, so a symbol table can be declared before the runtime is
 * ready (Bun) and a browser bundle carries no eager `dlopen` at import time.
 * `pathFn` is resolved on first open too (it reads `ffi.libSuffix()`, which
 * needs the runtime ready). Deno and the browser open on the first real call,
 * which is already past import. */
export function requireArchiveFingerprint(symbols: Symbols, contract: ArchiveFingerprint): void {
	const read = symbols[contract.symbol];
	if (typeof read !== "function") {
		throw new Error(
			`${contract.archive}: missing archive fingerprint; rebuild the native libraries from this checkout`,
		);
	}
	// The wasm boundary hands i64 back signed; normalize both sides to the
	// unsigned word the generator emits, so a high-bit fingerprint compares
	// and prints identically on every adapter.
	const actual = BigInt.asUintN(64, BigInt(read()));
	const expected = BigInt.asUintN(64, contract.expected);
	if (actual !== expected) {
		throw new Error(
			`${contract.archive}: callable surface does not match this binding ` +
				`(expected ${expected.toString(16)}, got ${actual.toString(16)}); rebuild the native libraries`,
		);
	}
}

export function lazySymbols(
	pathFn: () => string,
	defs: Record<string, SymbolDef>,
	contract?: ArchiveFingerprint,
): Symbols {
	let opened: Symbols | undefined;
	const open = (): Symbols => {
		if (opened !== undefined) return opened;
		const symbols = active().ffi.dlopen(pathFn(), defs);
		if (contract !== undefined) requireArchiveFingerprint(symbols, contract);
		opened = symbols;
		return symbols;
	};
	return new Proxy({} as Symbols, {
		get: (_t, prop) => open()[prop as string],
		has: (_t, prop) => prop in open(),
	});
}
