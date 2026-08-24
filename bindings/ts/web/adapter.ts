// The browser runtime adapter (ADR-0070): the runtime's FFI seam implemented
// over a WebAssembly instance of `pancake_host.wasm`, and its socket seam
// implemented over WebSocket. Installed by `mod.ts`'s `init` before the runtime
// loads, so `internal/ffi/runtime.ts` resolves this adapter instead of probing
// for Deno or Bun.
//
// Marshalling across the JS/wasm boundary: wasm has no view into JS buffers,
// so every `buffer` parameter and every `pointerOf` target is copied into
// linear memory (`pancake_wasm_alloc`), and every buffer parameter is copied
// back after the call so C out-parameters land in the caller's JS buffer.
// Those two copies are the named cost of the linear-memory boundary, the
// wasm sibling of the dlopen adapters' `readMemory` ownership copy.
//
// Lifetime of the copies: one arena, drained lazily at the start of the next
// OUTERMOST symbol call. `pointerOf` results must stay valid after the call
// that consumed them (the dial planner returns views aliasing its input
// buffers, decoded by the caller after the call returns), and a behavior
// trampoline runs nested symbol calls inside an outer `feed`, so the arena
// frees only when a new top-level call begins. `pointerOf` memoizes by buffer
// identity within the arena window, so a view returned by one call still
// aliases the same linear-memory copy a later `pointerOf` of the same buffer
// reports.

import type {
	NativeCallback,
	NativeType,
	RuntimeAdapter,
	RuntimeFfi,
	RuntimeNet,
	SymbolDef,
	Symbols,
} from "../runtime/internal/ffi/runtime.ts";
import { type AbiLayout, layoutFromWasmDescriptor } from "../runtime/internal/layout.ts";
import { webSocketChannel } from "../runtime/websocket.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";

/** The wasm exports the adapter itself drives; every `pancake_*` symbol the
 * runtime asks for is looked up dynamically on the same exports object. */
type WasmExports = {
	memory: WebAssembly.Memory;
	pancake_wasm_alloc: (len: number) => number;
	pancake_wasm_free: (ptr: number, len: number) => void;
	pancake_wasm_abi_layout: (out: number, cap: number) => number;
	pancake_wasm_behavior_trampoline_addr: () => number;
	pancake_wasm_hosted_free_trampoline_addr: () => number;
} & Record<string, CallableFunction>;

/** How a dial's host:port maps to the WebSocket URL that carries its bytes.
 * The default dials the peer directly (`ws://host:port/`); a deployment with
 * a byte gateway in front of its peers supplies its own mapping. */
export type WsUrl = (host: string, port: number) => string;

const defaultWsUrl: WsUrl = (host, port) => `ws://${host}:${port}/`;

/** What `makeWebAdapter` hands back: the runtime adapter plus the behavior and
 * hosted-free functions the module's imports forward to (`mod.ts` wires their
 * late-bound slots after instantiation). */
export interface WebAdapter {
	adapter: RuntimeAdapter;
	behaviorTrampolineImport: (
		ctx: number,
		turn: number,
		verbPtr: number,
		verbLen: number,
		argsPtr: number,
		argsLen: number,
		outReply: number,
	) => number;
	hostedFreeTrampolineImport: (ctx: number) => void;
}

/** Build the runtime adapter over an instantiated wasm module. `mod.ts` owns
 * instantiation and supplies the two hosted-object imports that forward to the
 * callbacks registered through `makeCallback`. */
export function makeWebAdapter(
	exports: WasmExports,
	descriptorWords: Uint32Array,
	urls: { wsUrl?: WsUrl } = {},
): WebAdapter {
	const wsUrl = urls.wsUrl ?? defaultWsUrl;
	const layout: AbiLayout = layoutFromWasmDescriptor(descriptorWords);

	// A memory view must be re-taken after any call that can grow memory.
	const u8 = () => new Uint8Array(exports.memory.buffer);

	// The generational staging arena. A staged copy must survive across one
	// whole call boundary in both directions: `pointerOf` results made before
	// a call are that call's inputs (a codec child buffer, a locator pointer
	// array), and the views a call returns alias its staged inputs and are
	// decoded after it returns. So each slot is stamped with the outermost-call
	// epoch it was staged in, and an outermost call entry frees only the slots
	// two epochs back, whose pre-call inputs and post-call reads are both over
	// by construction. At most two windows of stagings are ever live.
	interface Slot {
		ptr: number;
		len: number;
		epoch: number;
	}
	let slots: Slot[] = [];
	const memo = new Map<Uint8Array, Slot>();
	const memoOf = new Map<Slot, Uint8Array>();
	let epoch = 0;
	let depth = 0;

	function sweepArena(): void {
		const keep: Slot[] = [];
		for (const slot of slots) {
			if (slot.epoch <= epoch - 2) {
				if (slot.ptr !== 0) exports.pancake_wasm_free(slot.ptr, slot.len);
				const source = memoOf.get(slot);
				if (source !== undefined) {
					memo.delete(source);
					memoOf.delete(slot);
				}
			} else {
				keep.push(slot);
			}
		}
		slots = keep;
	}

	/** Copy `buf` into linear memory (memoized by buffer identity; a hit
	 * re-syncs the bytes so the copy always reflects the buffer's current
	 * content) and return its slot. Empty buffers are address 0. */
	function stage(buf: Uint8Array): Slot {
		const found = memo.get(buf);
		if (found !== undefined) {
			found.epoch = epoch;
			if (found.ptr !== 0) u8().set(buf, found.ptr);
			return found;
		}
		let slot: Slot;
		if (buf.length === 0) {
			slot = { ptr: 0, len: 0, epoch };
		} else {
			const ptr = exports.pancake_wasm_alloc(buf.length) >>> 0;
			if (ptr === 0) {
				throw new Error(
					`pancake wasm: linear-memory allocation failed for ${buf.length} bytes ` +
						`(${slots.length} staged allocations, ${exports.memory.buffer.byteLength} bytes of linear memory)`,
				);
			}
			u8().set(buf, ptr);
			slot = { ptr, len: buf.length, epoch };
		}
		memo.set(buf, slot);
		memoOf.set(slot, buf);
		slots.push(slot);
		return slot;
	}

	// The two hosted-object callbacks have distinct C signatures. `mod.ts` wires
	// the wasm imports to these slots; `makeCallback` admits only these exact
	// definitions and fills them with the runtime's shared trampolines.
	let behaviorTrampoline: ((...args: unknown[]) => unknown) | null = null;
	let hostedFreeTrampoline: ((...args: unknown[]) => unknown) | null = null;

	/** The import the instantiation supplies: convert the raw i32s to the
	 * `bigint` pointer vocabulary the runtime's trampoline expects and forward. */
	function behaviorTrampolineImport(
		ctx: number,
		turn: number,
		verbPtr: number,
		verbLen: number,
		argsPtr: number,
		argsLen: number,
		outReply: number,
	): number {
		// This boundary owns the no-throw invariant: a JS exception unwinding
		// through the wasm frames would skip the vat's defers mid-turn. The
		// worst case must be a non-OK return, which settles the answer broken.
		try {
			if (behaviorTrampoline === null) return INVALID_ARGUMENT;
			const rc = behaviorTrampoline(
				BigInt(ctx >>> 0),
				BigInt(turn >>> 0),
				BigInt(verbPtr >>> 0),
				verbLen >>> 0,
				BigInt(argsPtr >>> 0),
				argsLen >>> 0,
				BigInt(outReply >>> 0),
			);
			return typeof rc === "number" ? rc | 0 : Number(rc);
		} catch {
			return INVALID_ARGUMENT;
		}
	}

	/** Native actor retirement must not let a JavaScript exception unwind
	 * through wasm teardown. The registered callback only releases JS-owned
	 * bookkeeping, and a missing callback is harmless before any pointer to it
	 * can have been handed to the Host. */
	function hostedFreeTrampolineImport(ctx: number): void {
		try {
			hostedFreeTrampoline?.(BigInt(ctx >>> 0));
		} catch {
			// Preserve the C destructor's no-throw boundary.
		}
	}

	function lowerArg(type: NativeType, value: unknown): unknown {
		switch (type) {
			case "buffer": {
				if (value === null || value === undefined) return 0;
				return stage(value as Uint8Array).ptr;
			}
			case "pointer":
			case "usize":
				return Number(value ?? 0);
			case "u64":
			case "i64":
				return BigInt((value ?? 0n) as bigint | number);
			default:
				return Number(value ?? 0);
		}
	}

	function liftResult(type: NativeType, value: unknown): unknown {
		switch (type) {
			case "void":
				return undefined;
			case "pointer":
			case "usize":
				return BigInt((Number(value) >>> 0) >>> 0);
			case "u64":
			case "i64":
				return value as bigint;
			default:
				return Number(value);
		}
	}

	function wrapSymbol(name: string, def: SymbolDef): (...args: unknown[]) => unknown {
		const fn = exports[name];
		if (typeof fn !== "function") {
			throw new Error(
				`pancake wasm module exports no "${name}": only the ocapn and driver ` +
					"families live in pancake_host.wasm (the transport archives are native-only)",
			);
		}
		return (...args: unknown[]) => {
			if (depth === 0) {
				epoch += 1;
				sweepArena();
			}
			depth += 1;
			try {
				const lowered = def.parameters.map((t, i) => lowerArg(t, args[i]));
				const ret = fn(...lowered);
				// Copy out-parameter buffers back so the callee's writes reach the
				// caller's JS buffer. An annotated table (`SymbolDef.outBuffers`)
				// pays this only for its true outputs; an unannotated one copies
				// every buffer back, the safe default.
				const mem = u8();
				for (let i = 0; i < def.parameters.length; i++) {
					if (def.parameters[i] !== "buffer") continue;
					if (def.outBuffers !== undefined && !def.outBuffers.includes(i)) continue;
					const buf = args[i] as Uint8Array | null | undefined;
					if (buf === null || buf === undefined || buf.length === 0) continue;
					const slot = memo.get(buf);
					if (slot !== undefined && slot.ptr !== 0) {
						buf.set(mem.subarray(slot.ptr, slot.ptr + slot.len));
					}
				}
				const result = liftResult(def.result, ret);
				return def.nonblocking ? Promise.resolve(result) : result;
			} finally {
				depth -= 1;
			}
		};
	}

	const ffi: RuntimeFfi = {
		offloadsBlockingCalls: () => false,
		dlopen(_path: string, defs: Record<string, SymbolDef>): Symbols {
			const table: Symbols = {};
			for (const [name, def] of Object.entries(defs)) {
				table[name] = wrapSymbol(name, def);
			}
			return table;
		},

		makeCallback(def: SymbolDef, fn: (...args: unknown[]) => unknown): NativeCallback {
			const behaviorParameters = [
				"pointer",
				"pointer",
				"pointer",
				"usize",
				"pointer",
				"usize",
				"pointer",
			];
			const isBehavior = def.result === "i32" &&
				def.parameters.length === behaviorParameters.length &&
				def.parameters.every((parameter, index) => parameter === behaviorParameters[index]);
			if (isBehavior) {
				behaviorTrampoline = fn;
				return {
					pointer: BigInt(exports.pancake_wasm_behavior_trampoline_addr() >>> 0),
					close() {
						behaviorTrampoline = null;
					},
				};
			}
			const isHostedFree = def.result === "void" &&
				def.parameters.length === 1 && def.parameters[0] === "pointer";
			if (isHostedFree) {
				hostedFreeTrampoline = fn;
				return {
					pointer: BigInt(exports.pancake_wasm_hosted_free_trampoline_addr() >>> 0),
					close() {
						hostedFreeTrampoline = null;
					},
				};
			}
			throw new Error(
				"pancake wasm: callbacks are limited to hosted behavior and lifecycle " +
					"trampolines (custom-allocator contexts are dlopen-only)",
			);
		},

		pointerOf(buf: Uint8Array): bigint {
			if (buf.byteLength === 0) return 0n;
			return BigInt(stage(buf).ptr);
		},

		readMemory(ptr: bigint, len: number): ArrayBuffer {
			if (ptr === 0n || len === 0) return new ArrayBuffer(0);
			const start = Number(ptr);
			return u8().slice(start, start + len).buffer;
		},

		writeMemory(ptr: bigint, bytes: Uint8Array): void {
			if (ptr === 0n || bytes.length === 0) return;
			u8().set(bytes, Number(ptr));
		},

		libSuffix() {
			// Never consulted on this adapter (dlopen ignores paths), but the
			// seam requires an answer; `so` is the neutral one.
			return "so";
		},
	};

	const net: RuntimeNet = {
		connect(host: string, port: number) {
			return connectWebSocket(wsUrl(host, port));
		},
		listen(): never {
			throw new Error(
				"a browser cannot bind a listener; host the accepting side on a dlopen runtime",
			);
		},
	};

	return { adapter: { ffi, net, layout }, behaviorTrampolineImport, hostedFreeTrampolineImport };
}

/** Open a WebSocket carrying raw OCapN frame bytes and adapt it to the
 * runtime's byte-channel seam. Each binary message is one inbound chunk; the
 * host's stream delimiter owns framing, exactly as over TCP. */
function connectWebSocket(url: string): Promise<{
	read(): Promise<Uint8Array | null>;
	write(data: Uint8Array): Promise<void>;
	close(): void;
	localAddr(): { hostname: string; port: number };
}> {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(url);
		// A pre-open error rejects the connect. Once open, `webSocketChannel`
		// re-wires the handlers for the byte lifecycle (a later error is then
		// an end-of-stream the session's teardown classifies).
		ws.onerror = () => reject(new Error(`WebSocket connect failed: ${url}`));
		ws.onopen = () => {
			resolve({
				...webSocketChannel(ws),
				localAddr(): { hostname: string; port: number } {
					// A browser socket has no kernel-visible local address; only
					// the accepting side (a dlopen runtime) ever signs one.
					throw new Error("a browser WebSocket has no local address");
				},
			});
		};
	});
}
