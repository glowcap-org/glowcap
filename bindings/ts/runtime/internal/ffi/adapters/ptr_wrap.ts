// Internal: the pointer-marshalling spine the runtime adapters share.
//
// Deno and Bun each model a native pointer their own way (Deno an opaque
// `PointerValue`, Bun a JavaScript number) while the seam above speaks only
// `bigint`. Both adapters apply the identical plan: convert the
// pointer-typed parameters and result at each call, and leave a pointer-free
// signature untouched. The plan lives here once, parameterized by the
// adapter's own `toPtr`/`fromPtr` pair. Each adapter keeps only what is
// runtime-specific: its FFI type map, its dlopen/callback
// constructors, its memory and socket primitives.

import type { Ptr, SymbolDef, Symbols } from "../runtime.ts";

/** An adapter's pointer bridge: its native pointer representation to and from
 * the seam's `bigint`. */
export interface PtrBridge<NP> {
	toPtr(p: NP): Ptr;
	fromPtr(p: Ptr): NP;
}

// The marshalling plan for one signature: which parameter positions carry a
// pointer, and whether the result does.
function ptrPlan(def: SymbolDef): { params: number[]; result: boolean } {
	const params: number[] = [];
	def.parameters.forEach((t, i) => {
		if (t === "pointer") params.push(i);
	});
	return { params, result: def.result === "pointer" };
}

/** Wrap a dlopen'd symbol table so pointer parameters and results cross the
 * seam as `bigint`. A pointer-free symbol passes through unwrapped. */
export function wrapSymbols<NP>(
	defs: Record<string, SymbolDef>,
	// deno-lint-ignore no-explicit-any
	raw: Record<string, (...args: any[]) => any>,
	bridge: PtrBridge<NP>,
): Symbols {
	const out: Symbols = {};
	for (const [name, def] of Object.entries(defs)) {
		const fn = raw[name];
		const { params, result } = ptrPlan(def);
		if (params.length === 0 && !result) {
			out[name] = fn;
			continue;
		}
		// deno-lint-ignore no-explicit-any
		out[name] = (...args: any[]) => {
			for (const i of params) args[i] = bridge.fromPtr(args[i] as Ptr);
			const r = fn(...args);
			return result ? bridge.toPtr(r as NP) : r;
		};
	}
	return out;
}

/** Wrap a callback body so pointer arguments arrive as `bigint` and a pointer
 *  result returns as the runtime's native pointer. This is the mirror image of
 * `wrapSymbols`, for the JS function a native callback invokes. */
export function wrapCallbackFn<NP>(
	def: SymbolDef,
	fn: (...args: unknown[]) => unknown,
	bridge: PtrBridge<NP>,
	// deno-lint-ignore no-explicit-any
): (...args: any[]) => any {
	const { params, result } = ptrPlan(def);
	// deno-lint-ignore no-explicit-any
	return (...args: any[]) => {
		for (const i of params) args[i] = bridge.toPtr(args[i] as NP);
		const r = fn(...args);
		return result ? bridge.fromPtr(r as Ptr) : r;
	};
}
