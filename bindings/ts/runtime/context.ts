// The allocation scope: a `Context` routes every allocation of a handle family
// created in it through a host-supplied backend. `mod.ts` re-exports `Context`
// and `ContextAllocator`.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { ffi, type FfiCallback, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { outPointer, outUsize, readBytes } from "./internal/seam.ts";
import { L } from "./internal/layout.ts";
import {
	BUFFER_TOO_SMALL,
	FAILURE_LAYER_APPLICATION_OBSERVER,
	FAILURE_LAYER_BINDING,
	FAILURE_LAYER_CORE,
	FAILURE_LAYER_DRIVER,
	FAILURE_LAYER_TRANSPORT,
	FAILURE_SCOPE_CONTEXT,
	FAILURE_SCOPE_HOST,
	FAILURE_SCOPE_LISTENER,
	FAILURE_SCOPE_OPERATION,
	FAILURE_SCOPE_PROCESS,
	FAILURE_SCOPE_SESSION,
	FAILURE_SCOPE_TRANSPORT,
	INTERNAL,
	OK,
	WOULD_BLOCK,
} from "@glowcap/abi";
import { GlowcapError } from "./errors.ts";
import { drainFinalizerRetries } from "./finalizer_retry.ts";
import {
	type FailureEvent,
	type FailureLayer,
	type FailureReport,
	type FailureScope,
	recordRuntimeFailure,
	validateFailureReport,
} from "./failure_journal.ts";

export type { FailureEvent, FailureLayer, FailureReport, FailureScope } from "./failure_journal.ts";
export { takeRuntimeFailures } from "./failure_journal.ts";

const failureLayers: readonly (readonly [number, FailureLayer])[] = [
	[FAILURE_LAYER_CORE, "core"],
	[FAILURE_LAYER_DRIVER, "driver"],
	[FAILURE_LAYER_TRANSPORT, "transport"],
	[FAILURE_LAYER_BINDING, "binding"],
	[FAILURE_LAYER_APPLICATION_OBSERVER, "application-observer"],
];
const failureScopes: readonly (readonly [number, FailureScope])[] = [
	[FAILURE_SCOPE_PROCESS, "process"],
	[FAILURE_SCOPE_CONTEXT, "context"],
	[FAILURE_SCOPE_HOST, "host"],
	[FAILURE_SCOPE_SESSION, "session"],
	[FAILURE_SCOPE_LISTENER, "listener"],
	[FAILURE_SCOPE_TRANSPORT, "transport"],
	[FAILURE_SCOPE_OPERATION, "operation"],
];

function failureVocabularyId<T extends string>(entries: readonly (readonly [number, T])[], value: T): number {
	return entries.find((entry) => entry[1] === value)?.[0] ?? -1;
}

function failureVocabularyName<T extends string>(
	entries: readonly (readonly [number, T])[],
	value: number,
): T | undefined {
	return entries.find((entry) => entry[0] === value)?.[1];
}

const failureEventDecoder = new TextDecoder("utf-8", { fatal: true });

/** Record a callerless failure into its Context owner. Package-internal;
 * ordinary returned failures must never also pass through this function. */
function reportValidatedFailure(context: Context, input: FailureReport): void {
	const state = stateFor(context);
	// Releasing refuses new FFI families, but a retained Host still owns
	// this Context and its diagnostic queue until it gives back its lease.
	if (state.raw === NULL) throw new Error("glowcap Context is released");
	const encode = (text: string): Uint8Array => new TextEncoder().encode(text);
	const fields = [
		encode(input.operation),
		encode(input.primaryName),
		encode(input.primaryMessage ?? ""),
		encode(input.secondaryName ?? ""),
		encode(input.secondaryMessage ?? ""),
	] as const;
	const report = new Uint8Array(L.FAILURE_REPORT_SIZE);
	const dv = new DataView(report.buffer);
	const layer = failureVocabularyId(failureLayers, input.layer);
	const scope = failureVocabularyId(failureScopes, input.scope);
	if (layer < 0 || scope < 0) throw new TypeError("invalid failure layer or scope");
	dv.setUint32(L.FAILURE_REPORT_ABI_VERSION_OFF, 1, true);
	L.setUsize(dv, L.FAILURE_REPORT_STRUCT_SIZE_OFF, L.FAILURE_REPORT_SIZE);
	dv.setUint32(L.FAILURE_REPORT_LAYER_OFF, layer, true);
	dv.setUint32(L.FAILURE_REPORT_SCOPE_KIND_OFF, scope, true);
	dv.setBigUint64(L.FAILURE_REPORT_SCOPE_ID_OFF, input.scopeId ?? 0n, true);
	dv.setBigUint64(L.FAILURE_REPORT_OPERATION_ID_OFF, input.operationId ?? 0n, true);
	dv.setInt32(L.FAILURE_REPORT_PRIMARY_RESULT_OFF, input.primaryResult, true);
	dv.setInt32(L.FAILURE_REPORT_SECONDARY_RESULT_OFF, input.secondaryResult ?? 0, true);
	dv.setUint32(L.FAILURE_REPORT_SECONDARY_COUNT_OFF, input.secondaryCount ?? 0, true);
	const views = [
		[L.FAILURE_REPORT_OPERATION_OFF, L.FAILURE_REPORT_OPERATION_LEN_OFF],
		[L.FAILURE_REPORT_PRIMARY_NAME_OFF, L.FAILURE_REPORT_PRIMARY_NAME_LEN_OFF],
		[L.FAILURE_REPORT_PRIMARY_MESSAGE_OFF, L.FAILURE_REPORT_PRIMARY_MESSAGE_LEN_OFF],
		[L.FAILURE_REPORT_SECONDARY_NAME_OFF, L.FAILURE_REPORT_SECONDARY_NAME_LEN_OFF],
		[L.FAILURE_REPORT_SECONDARY_MESSAGE_OFF, L.FAILURE_REPORT_SECONDARY_MESSAGE_LEN_OFF],
	] as const;
	for (let i = 0; i < fields.length; i++) {
		L.setPtr(dv, views[i][0], ffi.pointerOf(fields[i]));
		L.setUsize(dv, views[i][1], fields[i].byteLength);
	}
	const rc = s.glowcap_context_report_failure(state.raw, ffi.pointerOf(report));
	if (rc !== OK) throw new GlowcapError(rc);
}

export function reportFailure(context: Context, input: FailureReport): void {
	reportValidatedFailure(context, validateFailureReport(input));
}

/** Retain a callerless failure without letting failure of its preferred
 * Context recorder alter application or protocol control flow. */
export function recordCallerlessFailure(context: Context | null, input: FailureReport): void {
	const valid = validateFailureReport(input);
	if (context == null) {
		recordRuntimeFailure(valid);
		return;
	}
	try {
		reportValidatedFailure(context, valid);
	} catch (error) {
		recordRuntimeFailure(valid);
		recordRuntimeFailure({
			layer: "binding",
			scope: "process",
			operation: `${input.operation}.diagnostic`,
			primaryName: error instanceof Error ? error.name : "ThrownValue",
			primaryResult: INTERNAL,
			primaryMessage: error instanceof Error ? error.message : String(error),
		});
	}
}

/** Retain a binding-owned failure after no Host/Context remains to receive it.
 * Package-internal transport helpers use this for late cleanup whose initiating
 * operation already returned. It is a projection onto the one process fallback
 * journal, not a second diagnostic authority. */
export function recordProcessBindingFailure(operation: string, error: unknown): void {
	recordCallerlessFailure(null, {
		layer: "binding",
		scope: "process",
		operation,
		primaryName: error instanceof Error ? error.name : "ThrownValue",
		primaryResult: INTERNAL,
		primaryMessage: error instanceof Error ? error.message : String(error),
	});
}

interface ContextState {
	raw: Ptr;
	allocCb: FfiCallback | null;
	freeCb: FfiCallback | null;
	handleCount: number;
	releaseRequested: boolean;
}

const states = new WeakMap<Context, ContextState>();

function releaseState(state: ContextState): void {
	if (state.raw !== NULL) {
		s.glowcap_context_release(state.raw);
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
	if (state === undefined) throw new Error("invalid glowcap Context");
	return state;
}

/** Retain the allocation policy for one FFI handle family. Package-internal. */
export function retainContext(context: Context): Ptr {
	const state = stateFor(context);
	if (state.releaseRequested || state.raw === NULL) {
		throw new Error("glowcap Context is released");
	}
	state.handleCount++;
	return state.raw;
}

/** End one FFI handle family's borrow. Package-internal. */
export function releaseContext(context: Context): void {
	const state = stateFor(context);
	if (state.handleCount === 0) throw new Error("glowcap Context ownership underflow");
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
 * creation immediately and frees its FFI policy after existing handles end. */
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

	/** A context backed by glowcap's library allocator. */
	static create(): Context {
		const ctx = new Context();
		const state = stateFor(ctx);
		const out = new Uint8Array(L.ptrSize);
		const rc = s.glowcap_context_new(out);
		if (rc !== OK) throw new GlowcapError(rc);
		state.raw = outPointer(out);
		contextFinalizer.register(ctx, state, ctx);
		return ctx;
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
		// callable from whichever archive allocates (the core that created the
		// context, or a driver-archive host created in it).
		const allocCb = ffi.makeCallback(
			{ parameters: ["pointer", "usize", "usize"], result: "pointer" },
			(_user: Ptr, size: bigint, alignment: bigint): Ptr => {
				const n = Number(size);
				if (n === 0) return NULL;
				try {
					const block = allocator.alloc(n, Number(alignment));
					const ptr = ffi.pointerOf(block);
					if (ptr === NULL) return NULL;
					live.set(ptr, block);
					return ptr;
				} catch (error) {
					recordCallerlessFailure(null, {
						layer: "binding",
						scope: "process",
						operation: "context.allocator.alloc",
						primaryName: error instanceof Error ? error.name : "ThrownValue",
						primaryResult: INTERNAL,
						primaryMessage: error instanceof Error ? error.message : String(error),
					});
					return NULL;
				}
			},
		);
		const freeCb = ffi.makeCallback(
			{ parameters: ["pointer", "pointer", "usize", "usize"], result: "void" },
			(_user: Ptr, ptr: Ptr, size: bigint, alignment: bigint): void => {
				if (ptr === NULL) return;
				const block = live.get(ptr);
				if (block !== undefined) {
					try {
						allocator.free(block, Number(size), Number(alignment));
						live.delete(ptr);
					} catch (error) {
						recordCallerlessFailure(null, {
							layer: "binding",
							scope: "process",
							operation: "context.allocator.free",
							primaryName: error instanceof Error ? error.name : "ThrownValue",
							primaryResult: INTERNAL,
							primaryMessage: error instanceof Error ? error.message : String(error),
						});
					}
				}
			},
		);
		state.allocCb = allocCb;
		state.freeCb = freeCb;

		// GlowcapAllocator, laid out by the generated ABI mirror. The C side copies
		// its three fields out at the call (it never retains this pointer), so the
		// struct is transient: only the callback pointers it carries must stay
		// live, and `#allocCb`/`#freeCb` own those.
		const allocStruct = new Uint8Array(L.ALLOCATOR_SIZE);
		const dv = new DataView(allocStruct.buffer);
		L.setPtr(dv, L.ALLOCATOR_ALLOC_OFF, allocCb.pointer);
		L.setPtr(dv, L.ALLOCATOR_FREE_OFF, freeCb.pointer);
		// user_data unused; state lives in the closures.
		L.setPtr(dv, L.ALLOCATOR_USER_DATA_OFF, 0n);

		const out = new Uint8Array(L.ptrSize);
		const rc = s.glowcap_context_new_with_allocator(allocStruct, out);
		if (rc !== OK) {
			releaseState(state);
			throw new GlowcapError(rc);
		}
		state.raw = outPointer(out);
		contextFinalizer.register(ctx, state, ctx);
		return ctx;
	}

	/** Opaque handle passed to `new Host(seed, { context })`. */
	get pointer(): Ptr {
		const state = stateFor(this);
		if (state.releaseRequested || state.raw === NULL) {
			throw new Error("glowcap Context is released");
		}
		return state.raw;
	}

	/** Atomically claim the oldest unreturnable failure retained by this
	 * context. Returned errors and close-barrier failures do not also appear
	 * here, and a claimed event cannot reappear. */
	nextFailure(): FailureEvent | null {
		drainFinalizerRetries();
		const state = stateFor(this);
		if (state.raw === NULL) {
			throw new Error("glowcap Context is released");
		}
		const event = new Uint8Array(L.FAILURE_EVENT_SIZE);
		const requiredOut = new Uint8Array(L.ptrSize);
		let payload: Uint8Array | null = null;
		for (;;) {
			const rc = s.glowcap_context_next_failure(
				state.raw,
				event,
				payload,
				BigInt(payload?.byteLength ?? 0),
				requiredOut,
			);
			if (rc === WOULD_BLOCK) return null;
			if (rc === BUFFER_TOO_SMALL) {
				payload = new Uint8Array(Number(outUsize(requiredOut)));
				continue;
			}
			if (rc !== OK) throw new GlowcapError(rc);
			break;
		}

		const dv = new DataView(event.buffer);
		const text = (pointerOff: number, lengthOff: number): string =>
			failureEventDecoder.decode(readBytes(L.getPtr(dv, pointerOff), L.getUsize(dv, lengthOff)));
		const layer = failureVocabularyName(failureLayers, dv.getUint32(L.FAILURE_EVENT_LAYER_OFF, true));
		const scope = failureVocabularyName(failureScopes, dv.getUint32(L.FAILURE_EVENT_SCOPE_KIND_OFF, true));
		if (layer === undefined || scope === undefined) {
			throw new Error("invalid failure event vocabulary from glowcap ABI");
		}
		return {
			sequence: dv.getBigUint64(L.FAILURE_EVENT_SEQUENCE_OFF, true),
			droppedBefore: dv.getBigUint64(L.FAILURE_EVENT_DROPPED_BEFORE_OFF, true),
			layer,
			scope,
			scopeId: dv.getBigUint64(L.FAILURE_EVENT_SCOPE_ID_OFF, true),
			operationId: dv.getBigUint64(L.FAILURE_EVENT_OPERATION_ID_OFF, true),
			primaryResult: dv.getInt32(L.FAILURE_EVENT_PRIMARY_RESULT_OFF, true),
			secondaryResult: dv.getInt32(L.FAILURE_EVENT_SECONDARY_RESULT_OFF, true),
			secondaryCount: dv.getUint32(L.FAILURE_EVENT_SECONDARY_COUNT_OFF, true),
			truncatedFields: dv.getUint32(L.FAILURE_EVENT_FLAGS_OFF, true),
			operation: text(L.FAILURE_EVENT_OPERATION_OFF, L.FAILURE_EVENT_OPERATION_LEN_OFF),
			primaryName: text(L.FAILURE_EVENT_PRIMARY_NAME_OFF, L.FAILURE_EVENT_PRIMARY_NAME_LEN_OFF),
			primaryMessage: text(L.FAILURE_EVENT_PRIMARY_MESSAGE_OFF, L.FAILURE_EVENT_PRIMARY_MESSAGE_LEN_OFF),
			secondaryName: text(L.FAILURE_EVENT_SECONDARY_NAME_OFF, L.FAILURE_EVENT_SECONDARY_NAME_LEN_OFF),
			secondaryMessage: text(
				L.FAILURE_EVENT_SECONDARY_MESSAGE_OFF,
				L.FAILURE_EVENT_SECONDARY_MESSAGE_LEN_OFF,
			),
		};
	}

	/** Claim every unreturnable failure currently retained, in order. */
	takeFailures(): FailureEvent[] {
		const failures: FailureEvent[] = [];
		for (;;) {
			const failure = this.nextFailure();
			if (failure === null) return failures;
			failures.push(failure);
		}
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
