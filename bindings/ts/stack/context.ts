// The allocation scope: a `Context` routes every allocation of a handle family
// created in it through a host-supplied backend. `mod.ts` re-exports `Context`
// and `HostAllocator`.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, type NativeCallback, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { outPointer } from "./internal/seam.ts";
import {
	ALLOCATOR_ALLOC_OFF,
	ALLOCATOR_FREE_OFF,
	ALLOCATOR_SIZE,
	ALLOCATOR_USER_DATA_OFF,
	OK,
} from "./internal/abi.ts";
import { PancakeError } from "./errors.ts";

/** A host allocation backend for `Context.withAllocator`. Methods may be called
 * from any thread that touches a handle created in the context. */
export interface HostAllocator {
	/** Return a block of at least `size` bytes aligned to `alignment`. */
	alloc(size: number, alignment: number): Uint8Array;
	/** Release a block previously returned by `alloc`. */
	free(block: Uint8Array, size: number, alignment: number): void;
}

/** An allocation scope. A host created in it (`new Node(seed, { context })`)
 * routes every byte it owns through it. A context must outlive
 * every handle created in it; release it (via `using` / `[Symbol.dispose]`)
 * only after those handles. */
export class Context {
	#raw: Ptr;
	// Kept alive while C holds them so the GC cannot reclaim the trampolines
	// or the live allocation blocks the trampolines manage.
	#allocCb: NativeCallback | null = null;
	#freeCb: NativeCallback | null = null;

	private constructor(raw: Ptr) {
		this.#raw = raw;
	}

	/** A context that routes every allocation through `allocator`. The host
	 * callbacks are kept alive for the context's whole lifetime. */
	static withAllocator(allocator: HostAllocator): Context {
		const ctx = new Context(NULL);
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
		ctx.#allocCb = allocCb;
		ctx.#freeCb = freeCb;

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
			allocCb.close();
			freeCb.close();
			throw new PancakeError(rc);
		}
		ctx.#raw = outPointer(out);
		return ctx;
	}

	/** Opaque handle, for use by `Peer.rawOpenIn`. */
	get pointer(): Ptr {
		return this.#raw;
	}

	release(): void {
		if (this.#raw !== NULL) {
			// Release the context first — it frees its tables through the allocator —
			// then close the callbacks the trampolines borrowed.
			s.pancake_context_release(this.#raw);
			this.#raw = NULL;
		}
		this.#allocCb?.close();
		this.#freeCb?.close();
		this.#allocCb = null;
		this.#freeCb = null;
	}

	[Symbol.dispose](): void {
		this.release();
	}
}
