// The allocation scope: a `Context` routes every allocation of a handle family
// created in it through a host-supplied backend. `mod.ts` re-exports `Context`
// and `ContextAllocator`.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, type NativeCallback, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { outPointer } from "./internal/seam.ts";
import {
	ALLOCATOR_ALLOC_OFF,
	ALLOCATOR_FREE_OFF,
	ALLOCATOR_SIZE,
	ALLOCATOR_USER_DATA_OFF,
} from "./internal/abi.ts";
import { OK } from "@pancake/abi";
import { PancakeError } from "./errors.ts";

interface ContextState {
	raw: Ptr;
	allocCb: NativeCallback | null;
	freeCb: NativeCallback | null;
	handleCount: number;
	releaseRequested: boolean;
}

const states = new WeakMap<Context, ContextState>();

function releaseState(state: ContextState): void {
	if (state.raw !== NULL) {
		s.pancake_context_release(state.raw);
		state.raw = NULL;
	}
	state.allocCb?.close();
	state.freeCb?.close();
	state.allocCb = null;
	state.freeCb = null;
}

const contextFinalizer = new FinalizationRegistry<ContextState>(releaseState);

function stateFor(context: Context): ContextState {
	const state = states.get(context);
	if (state === undefined) throw new Error("invalid pancake Context");
	return state;
}

/** Retain the allocation policy for one native handle family. Package-internal. */
export function retainContext(context: Context): Ptr {
	const state = stateFor(context);
	if (state.releaseRequested || state.raw === NULL) {
		throw new Error("pancake Context is released");
	}
	state.handleCount++;
	return state.raw;
}

/** End one native handle family's borrow. Package-internal. */
export function releaseContext(context: Context): void {
	const state = stateFor(context);
	if (state.handleCount === 0) throw new Error("pancake Context ownership underflow");
	state.handleCount--;
	if (state.handleCount === 0 && state.releaseRequested) {
		contextFinalizer.unregister(context);
		releaseState(state);
	}
}

/** A host allocation backend for `Context.withAllocator`. Methods may be called
 * from any thread that touches a handle created in the context. */
export interface ContextAllocator {
	/** Return a block of at least `size` bytes aligned to `alignment`. */
	alloc(size: number, alignment: number): Uint8Array;
	/** Release a block previously returned by `alloc`. */
	free(block: Uint8Array, size: number, alignment: number): void;
}

/** An allocation scope. A host created in it (`new Host(seed, { context })`)
 * routes every byte it owns through it. Releasing the Context stops new handle
 * creation immediately and frees its native policy after existing handles end. */
export class Context {
	private constructor() {
		states.set(this, {
			raw: NULL,
			allocCb: null,
			freeCb: null,
			handleCount: 0,
			releaseRequested: false,
		});
	}

	/** A context that routes every allocation through `allocator`. The host
	 * callbacks are kept alive for the context's whole lifetime. */
	static withAllocator(allocator: ContextAllocator): Context {
		const ctx = new Context();
		const state = stateFor(ctx);
		// pointer value -> the JS-owned block backing it, so free can reclaim it and
		// GC cannot collect a block C still references. Owned by the alloc/free
		// closures below (retained for the context's life via `#allocCb`/`#freeCb`).
		const live = new Map<bigint, Uint8Array>();

		// Deno and Bun register callbacks globally, so these trampolines are
		// callable from whichever archive allocates — the core that created the
		// context, or a driver-archive host created in it.
		const allocCb = ffi.makeCallback(
			{ parameters: ["pointer", "usize", "usize"], result: "pointer" },
			(_user: Ptr, size: bigint, alignment: bigint): Ptr => {
				const n = Number(size);
				if (n === 0) return NULL;
				const block = allocator.alloc(n, Number(alignment));
				const ptr = ffi.pointerOf(block);
				if (ptr === NULL) return NULL;
				live.set(ptr, block);
				return ptr;
			},
		);
		const freeCb = ffi.makeCallback(
			{ parameters: ["pointer", "pointer", "usize", "usize"], result: "void" },
			(_user: Ptr, ptr: Ptr, size: bigint, alignment: bigint): void => {
				if (ptr === NULL) return;
				const block = live.get(ptr);
				live.delete(ptr);
				if (block !== undefined) {
					allocator.free(block, Number(size), Number(alignment));
				}
			},
		);
		state.allocCb = allocCb;
		state.freeCb = freeCb;

		// PancakeAllocator, laid out by the generated ABI mirror. The C side copies
		// its three fields out at the call (it never retains this pointer), so the
		// struct is transient — only the callback pointers it carries must stay
		// live, and `#allocCb`/`#freeCb` own those.
		const allocStruct = new Uint8Array(ALLOCATOR_SIZE);
		const dv = new DataView(allocStruct.buffer);
		dv.setBigUint64(ALLOCATOR_ALLOC_OFF, allocCb.pointer, true);
		dv.setBigUint64(ALLOCATOR_FREE_OFF, freeCb.pointer, true);
		// user_data unused; state lives in the closures.
		dv.setBigUint64(ALLOCATOR_USER_DATA_OFF, 0n, true);

		const out = new Uint8Array(8);
		const rc = s.pancake_context_new_with_allocator(allocStruct, out);
		if (rc !== OK) {
			releaseState(state);
			throw new PancakeError(rc);
		}
		state.raw = outPointer(out);
		contextFinalizer.register(ctx, state, ctx);
		return ctx;
	}

	/** Opaque handle passed to `new Host(seed, { context })`. */
	get pointer(): Ptr {
		const state = stateFor(this);
		if (state.releaseRequested || state.raw === NULL) {
			throw new Error("pancake Context is released");
		}
		return state.raw;
	}

	release(): void {
		const state = stateFor(this);
		if (state.releaseRequested) return;
		state.releaseRequested = true;
		if (state.handleCount === 0) {
			contextFinalizer.unregister(this);
			releaseState(state);
		}
	}

	[Symbol.dispose](): void {
		this.release();
	}
}
