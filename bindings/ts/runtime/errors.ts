// Diagnostics and the typed error hierarchy: the per-archive thread-local
// last-error reads, the `PancakeError` family every failed C ABI call raises,
// and the internal guards (`check`, `checkHost`) the rest of the binding
// shares. `mod.ts` re-exports the public error classes; the readers and
// guards stay package-internal.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { hostS } from "./internal/ffi/host.ts";
import { readErrorSlot } from "./internal/seam.ts";
import {
	ABORT_DOMAIN_CODEC,
	ABORT_DOMAIN_FOREIGN,
	ABORT_DOMAIN_SESSION,
	BINDING_SECONDARY_FAILURE_CAP,
	BROKEN,
	INTERNAL,
	OK,
} from "@pancake/abi";
import type { CarrierFailure } from "./carrier_failure.ts";

/** The calling thread's last core-archive (`pancake_*`) error message, or null
 * when there is none. */
export function lastError(): string | null {
	return readErrorSlot(s.pancake_last_error);
}

/** The calling thread's last host-archive (`pancake_host_*`) error message, or
 * null when there is none. The driver archive keeps its own slot, so a host
 * call's diagnostic never scrapes the core's unrelated one. */
export function hostLastError(): string | null {
	return readErrorSlot(hostS.pancake_host_last_error);
}

/** The typed cause of a peer's most recent local dispatch failure, the
 * counterpart of the C ABI's `PancakeLastAbort`. `domain` names the layer that
 * refused, `kind` the projected `op:abort` kind when one exists, `message` the
 * static diagnostic, `errorName` the originating error, and
 * `abortDeliveryErrorName` a failure publishing the terminal abort, and
 * `secondaryErrorName` / `secondaryErrorCount` the bounded cleanup or
 * consequence failures that followed the originating error. */
export interface AbortDetail {
	domain: "codec" | "session" | "foreign";
	kind: string | null;
	message: string;
	errorName: string;
	abortDeliveryErrorName: string | null;
	secondaryErrorName: string | null;
	secondaryErrorCount: number;
}

/** Map `PancakeLastAbort.domain` to the host label the waist defines. */
export function abortDomainLabel(
	domainNum: number,
): AbortDetail["domain"] {
	if (domainNum === ABORT_DOMAIN_CODEC) return "codec";
	if (domainNum === ABORT_DOMAIN_SESSION) return "session";
	if (domainNum === ABORT_DOMAIN_FOREIGN) return "foreign";
	throw new PancakeError(INTERNAL, `pancake ABI returned unknown abort domain ${domainNum}`);
}

export class PancakeError extends Error {
	/** The thread-local diagnostic captured when this error was raised, if any. */
	readonly detail: string | null;
	/** The typed abort cause, attached when a peer refused an inbound frame. */
	abort: AbortDetail | null = null;
	/** Native carrier phase and engine detail when the failure originated there. */
	carrierFailure: CarrierFailure | null = null;
	constructor(public readonly code: number, detail?: string) {
		// For a code an FFI call returned, capture the thread-local message now.
		// A client-side validation throw passes an explicit `detail` instead, so it
		// never scrapes an unrelated thread-local left by some earlier call.
		const d = detail ?? lastError();
		super(d ? `pancake error ${code}: ${d}` : `pancake error ${code}`);
		this.detail = d;
		this.name = "PancakeError";
	}
}

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
				: new AggregateError(state.retained, "additional pancake cleanup failures");
		} catch {
			// The WeakMap remains authoritative for frozen application errors.
		}
	}
	return primary;
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

/** A promise the partner broke, the typed rejection an awaited `send` (or any
 * settled vow) produces. `reason` is the partner's break message. */
export class VowBroken extends PancakeError {
	constructor(public readonly reason: string) {
		super(BROKEN, reason);
		this.name = "VowBroken";
	}
}

/** Project a core-issued vow failure code into the binding's typed hierarchy. */
export function vowFailure(code: number, reason: string): PancakeError {
	return code === BROKEN ? new VowBroken(reason) : new PancakeError(code, reason);
}

/** A `fetch` that settled, but not with a capability, the application-level
 * outcome (the partner answered, and the answer was not a reference), distinct
 * from a marshalling failure or a broken promise. `capabilityName` is the
 * swiss-number the fetch asked for. */
export class FetchFailed extends PancakeError {
	constructor(public readonly capabilityName: string, detail?: string) {
		super(
			BROKEN,
			detail ?? `fetch("${capabilityName}") did not resolve to a capability`,
		);
		this.name = "FetchFailed";
	}
}

export function check(code: number): void {
	if (code !== OK) throw new PancakeError(code);
}

/** A failed `pancake_host_*` call as a typed error, its diagnostic read from
 * the driver archive's own slot so it never scrapes the core's unrelated one. */
export function hostError(code: number): PancakeError {
	return new PancakeError(code, hostLastError() ?? `host call failed (code ${code})`);
}

/** As `check`, for `pancake_host_*` calls. */
export function checkHost(code: number): void {
	if (code !== OK) throw hostError(code);
}
