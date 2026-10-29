// Diagnostics and the typed error hierarchy: the per-archive thread-local
// last-error reads, the `GlowcapError` family every failed C ABI call raises,
// and the internal guards (`check`, `checkHost`) the rest of the binding
// shares. `mod.ts` re-exports the public error classes; the readers and
// guards stay package-internal.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { hostS } from "./internal/ffi/host.ts";
import { readErrorSlot } from "./internal/seam.ts";
import { ABORT_DOMAIN_CODEC, ABORT_DOMAIN_FOREIGN, ABORT_DOMAIN_SESSION, BROKEN, INTERNAL, OK } from "@glowcap/abi";
import type { CarrierFailure } from "./carrier_failure.ts";

/** The calling thread's last core-archive (`glowcap_*`) error message, or null
 * when there is none. */
export function lastError(): string | null {
	return readErrorSlot(s.glowcap_last_error);
}

/** The calling thread's last host-archive (`glowcap_host_*`) error message, or
 * null when there is none. The driver archive keeps its own slot, so a host
 * call's diagnostic never scrapes the core's unrelated one. */
export function hostLastError(): string | null {
	return readErrorSlot(hostS.glowcap_host_last_error);
}

/** The typed cause of a peer's most recent local dispatch failure, the
 * counterpart of the C ABI's `GlowcapLastAbort`. `domain` names the layer that
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

/** Map `GlowcapLastAbort.domain` to the host label the waist defines. */
export function abortDomainLabel(
	domainNum: number,
): AbortDetail["domain"] {
	if (domainNum === ABORT_DOMAIN_CODEC) return "codec";
	if (domainNum === ABORT_DOMAIN_SESSION) return "session";
	if (domainNum === ABORT_DOMAIN_FOREIGN) return "foreign";
	throw new GlowcapError(INTERNAL, `glowcap ABI returned unknown abort domain ${domainNum}`);
}

export class GlowcapError extends Error {
	/** The thread-local diagnostic captured when this error was raised, if any. */
	readonly detail: string | null;
	/** The typed abort cause, attached when a peer refused an inbound frame. */
	abort: AbortDetail | null = null;
	/** FFI carrier phase and engine detail when the failure originated there. */
	carrierFailure: CarrierFailure | null = null;
	constructor(public readonly code: number, detail?: string) {
		// For a code an FFI call returned, capture the thread-local message now.
		// A client-side validation throw passes an explicit `detail` instead, so it
		// never scrapes an unrelated thread-local left by some earlier call. status-allow: event or source ordering
		const d = detail ?? lastError();
		super(d ? `glowcap error ${code}: ${d}` : `glowcap error ${code}`);
		this.detail = d;
		this.name = "GlowcapError";
	}
}

export {
	FirstFailure,
	retainCleanupFailures,
	retainSecondaryFailure,
	secondaryFailureCount,
	secondaryFailures,
} from "./cleanup.ts";

/** A promise the partner broke, the typed rejection an awaited `send` (or any
 * settled vow) produces. `reason` is the partner's break message. */
export class VowBroken extends GlowcapError {
	constructor(public readonly reason: string) {
		super(BROKEN, reason);
		this.name = "VowBroken";
	}
}

/** A durable publication the remote Host no longer knows. This is the status-allow: lifecycle transition
 * application-facing lifecycle fact behind CapTP's canonical
 * `unknown swissnum` break: consumers can reconcile retained sturdyrefs
 * without branching on protocol text. */
export class PublicationNotFound extends VowBroken {
	constructor() {
		super("unknown swissnum");
		this.name = "PublicationNotFound";
	}
}

/** Project a core-issued vow failure code into the binding's typed hierarchy. */
export function vowFailure(code: number, reason: string): GlowcapError {
	return code === BROKEN
		? reason === "unknown swissnum" ? new PublicationNotFound() : new VowBroken(reason)
		: new GlowcapError(code, reason);
}

/** A `fetch` that settled, but not with a capability, the application-level
 * outcome (the partner answered, and the answer was not a reference), distinct
 * from a marshalling failure or a broken promise. `capabilityName` is the
 * swiss-number the fetch asked for. */
export class FetchFailed extends GlowcapError {
	constructor(public readonly capabilityName: string, detail?: string) {
		super(
			BROKEN,
			detail ?? `fetch("${capabilityName}") did not resolve to a capability`,
		);
		this.name = "FetchFailed";
	}
}

export function check(code: number): void {
	if (code !== OK) throw new GlowcapError(code);
}

/** A failed `glowcap_host_*` call as a typed error, its diagnostic read from
 * the driver archive's own slot so it never scrapes the core's unrelated one. */
export function hostError(code: number): GlowcapError {
	return new GlowcapError(code, hostLastError() ?? `host call failed (code ${code})`);
}

/** As `check`, for `glowcap_host_*` calls. */
export function checkHost(code: number): void {
	if (code !== OK) throw hostError(code);
}
