// Bounded JavaScript error custody. This module requires no Host or FFI.
import { BINDING_SECONDARY_FAILURE_CAP } from "@glowcap/abi";

const SECONDARY_FAILURE_CAP = BINDING_SECONDARY_FAILURE_CAP;
interface SecondaryFailures {
	readonly retained: unknown[];
	total: number;
}
const secondaryByFailure = new WeakMap<object, SecondaryFailures>();

/** Cleanup and consequence failures retained without replacing the exact
 * object originally thrown. Works for frozen Error subclasses as well as
 * ordinary extensible errors; primitives have no identity-bearing attachment
 * surface and therefore report no secondary list. */
export function secondaryFailures(error: unknown): readonly unknown[] {
	return typeof error === "object" && error !== null ? secondaryByFailure.get(error)?.retained ?? [] : [];
}

/** Total consequences observed, including those beyond the bounded exact list. */
export function secondaryFailureCount(error: unknown): number {
	return typeof error === "object" && error !== null ? secondaryByFailure.get(error)?.total ?? 0 : 0;
}

/** Attach a later failure while returning the exact primary unchanged. */
export function retainSecondaryFailure(primary: unknown, secondary: unknown, observedCount = 1): unknown {
	if (Object.is(primary, secondary)) return primary;
	if (typeof primary !== "object" || primary === null) return primary;
	const state = secondaryByFailure.get(primary) ?? { retained: [], total: 0 };
	state.total = Math.min(Number.MAX_SAFE_INTEGER, state.total + Math.max(1, observedCount));
	if (state.retained.length < SECONDARY_FAILURE_CAP) state.retained.push(secondary);
	secondaryByFailure.set(primary, state);
	if (primary instanceof Error) {
		try {
			primary.cause = state.retained.length === 1
				? state.retained[0]
				: new AggregateError(state.retained, "additional glowcap cleanup failures");
		} catch {
			// The WeakMap remains authoritative for frozen application errors.
		}
	}
	return primary;
}

/** The first failure a barrier observes, boxed so that `null`, `undefined`,
 * and every other falsy reason still counts as a failure. Each later failure
 * is attached to it in observation order. */
export class FirstFailure {
	#first: { readonly error: unknown } | null = null;

	add(error: unknown): void {
		if (this.#first === null) this.#first = { error };
		else retainSecondaryFailure(this.#first.error, error);
	}

	addRejections(outcomes: readonly PromiseSettledResult<unknown>[]): void {
		for (const outcome of outcomes) {
			if (outcome.status === "rejected") this.add(outcome.reason);
		}
	}

	throwIfAny(): void {
		if (this.#first !== null) throw this.#first.error;
	}
}

/** Run rollback barriers in order, attaching every refusal to the unchanged
 * construction failure. Cleanup is cold-path and must never short-circuit the
 * owners that follow it. */
export async function retainCleanupFailures(
	primary: unknown,
	cleanups: readonly (() => void | Promise<void>)[],
): Promise<unknown> {
	for (const cleanup of cleanups) {
		try {
			await cleanup();
		} catch (error) {
			retainSecondaryFailure(primary, error);
		}
	}
	return primary;
}
