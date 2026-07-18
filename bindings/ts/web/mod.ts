// @pancake/web — the browser entry for the pancake stack (ADR-0070).
//
// A browser tab becomes a real OCapN peer: the same sans-io protocol core the
// native archives link, compiled to wasm32 (`zig build wasm-driver` →
// `pancake_driver.wasm`), with the byte channel on a WebSocket. The proof
// (`zig build web-peer-test`) covers the keyed handshake, fetch and call, and
// a host call back into a wasm-hosted object. `init` instantiates the module,
// builds the runtime adapter over it (FFI over linear memory, sockets over
// WebSocket, struct layout from the module's own descriptor), installs the
// adapter, and only then loads `@pancake/stack`, so the same `Session` /
// `Server` / `connect` surface every dlopen runtime uses runs unchanged on
// top of it.
//
//   import { init } from "@pancake/web";
//   const stack = await init({ wasm: await fetch("/pancake_driver.wasm") });
//   const session = await stack.connect(locator);
//
// The one seam a page may need to shape is `wsUrl`: how a dial's host:port
// maps onto the WebSocket URL that carries its bytes (dial the peer directly
// by default, or point every dial at a byte gateway).

import { makeWebAdapter, type WsUrl } from "./adapter.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";

/** What `init` accepts as the wasm module source. */
export type WasmSource =
	| WebAssembly.Module
	| BufferSource
	| Response
	| Promise<Response>;

export interface WebInitOptions {
	/** The `pancake_driver.wasm` module: compiled module, raw bytes, or a
	 * `fetch` response (streamed when the host supports it). */
	wasm: WasmSource;
	/** Map a dial's host:port to its WebSocket URL; defaults to
	 * `ws://host:port/` (the peer itself accepts WebSocket). */
	wsUrl?: WsUrl;
}

/** The stack's public surface, as `init` returns it. */
export type PancakeStack = typeof import("@pancake/stack");

// The same registry key `internal/ffi/runtime.ts` consults before probing for
// a runtime; `Symbol.for` pairs the two without importing the stack early
// (importing it would run its adapter selection before ours is installed).
const injected_adapter_key = Symbol.for("pancake.stack.adapter");

export type { WsUrl } from "./adapter.ts";

let loaded: Promise<PancakeStack> | null = null;
let loadedOptions: WebInitOptions | null = null;

/** Instantiate the wasm peer and load the pancake stack over it. One
 * configuration per page: the stack binds its adapter at load, so a repeat
 * call with the same options object returns the first load, a repeat with a
 * different one throws, and a failed load clears the slot so a corrected
 * retry can succeed. */
export function init(options: WebInitOptions): Promise<PancakeStack> {
	if (loaded !== null) {
		if (loadedOptions !== options) {
			throw new Error(
				"pancake web: init was already called with a different configuration",
			);
		}
		return loaded;
	}
	loadedOptions = options;
	loaded = initFresh(options);
	loaded.catch(() => {
		loaded = null;
		loadedOptions = null;
	});
	return loaded;
}

async function initFresh(options: WebInitOptions): Promise<PancakeStack> {
	const registry = globalThis as Record<symbol, unknown>;
	if (registry[injected_adapter_key] !== undefined) {
		throw new Error("pancake web: a runtime adapter is already installed");
	}

	// The module's one import is the behavior-dispatch seam
	// (`env.pancake_behavior_trampoline`); the adapter fills the slot the
	// import forwards to when the stack registers its shared trampoline.
	let trampoline:
		| ((...args: number[]) => number)
		| null = null;
	const imports: WebAssembly.Imports = {
		env: {
			pancake_behavior_trampoline: (...args: number[]): number =>
				trampoline === null ? INVALID_ARGUMENT : trampoline(...args),
		},
	};

	const instance = await instantiate(options.wasm, imports);
	const exports = instance.exports as unknown as Parameters<typeof makeWebAdapter>[0];

	// Read the module's self-described wasm32 struct layout (probe the word
	// count, then fill).
	const count = exports.pancake_wasm_abi_layout(0, 0) >>> 0;
	const byteLen = count * 4;
	const ptr = exports.pancake_wasm_alloc(byteLen) >>> 0;
	if (ptr === 0) throw new Error("pancake web: descriptor allocation failed");
	let words: Uint32Array;
	try {
		if ((exports.pancake_wasm_abi_layout(ptr, count) >>> 0) !== count) {
			throw new Error("pancake web: layout descriptor returned a short blob");
		}
		words = new Uint32Array(exports.memory.buffer.slice(ptr, ptr + byteLen));
	} finally {
		exports.pancake_wasm_free(ptr, byteLen);
	}

	const web = makeWebAdapter(exports, words, options.wsUrl);
	// Route the module's trampoline import through the adapter: it converts
	// the raw i32s to the stack's bigint vocabulary and forwards to whatever
	// callback the stack registered through `makeCallback`.
	trampoline = (ctx, turn, verbPtr, verbLen, argsPtr, argsLen, outReply) =>
		web.trampolineImport(ctx, turn, verbPtr, verbLen, argsPtr, argsLen, outReply);

	registry[injected_adapter_key] = web.adapter;
	return await import("@pancake/stack");
}

async function instantiate(
	source: WasmSource,
	imports: WebAssembly.Imports,
): Promise<WebAssembly.Instance> {
	const resolved = await source;
	if (resolved instanceof WebAssembly.Module) {
		return new WebAssembly.Instance(resolved, imports);
	}
	if (typeof Response !== "undefined" && resolved instanceof Response) {
		if (typeof WebAssembly.instantiateStreaming === "function") {
			return (await WebAssembly.instantiateStreaming(resolved, imports)).instance;
		}
		const bytes = await resolved.arrayBuffer();
		return (await WebAssembly.instantiate(bytes, imports)).instance;
	}
	return (await WebAssembly.instantiate(resolved as BufferSource, imports)).instance;
}
