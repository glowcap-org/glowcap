// Diagnostics and the typed error hierarchy: the per-archive thread-local
// last-error reads, the `GlowcapError` family every failed C ABI call raises,
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
	BreakCause,
	BROKEN,
	INTERNAL,
	INVALID_ARGUMENT,
	OK,
	type RawBreakCause,
	RouteFailure,
	routeFailureCause,
} from "@glowcap/abi";
import { readBreakCause } from "./internal/break_cause.ts";
import { L } from "./internal/layout.ts";
import { retainSecondaryFailure } from "./cleanup.ts";
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

/** The partner's `op:abort`: its wire kind name (for example
 * `"ProtocolError"`) and its diagnostic, bounded by the Host. */
export interface PartnerAbort {
	kind: string;
	message: string;
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

/** An ABI failure with separate local provenance and diagnostic detail. */
export class GlowcapError extends Error {
	/** A connector cannot realize this route in its current configuration, before opening a channel. */
	static transportUnavailable(detail: string): GlowcapError {
		return new GlowcapError(INVALID_ARGUMENT, detail, routeFailureCause(RouteFailure.TransportUnavailable));
	}

	/** The thread-local diagnostic captured when this error was raised, if any. */
	readonly detail: string | null;
	/** The typed abort cause, attached when a peer refused an inbound frame. */
	abort: AbortDetail | null = null;
	/** FFI carrier phase and engine detail when the failure originated there. */
	carrierFailure: CarrierFailure | null = null;
	constructor(
		public readonly code: number,
		detail?: string,
		public readonly breakCause: BreakCause = new BreakCause(),
	) {
		// For a code an FFI call returned, capture the thread-local message now.
		// A client-side validation throw passes an explicit `detail` instead, so it
		// never scrapes an unrelated thread-local left by some earlier call.
		const d = detail ?? lastError();
		const label = breakCause.label();
		const display = label == null ? d : d ? `${label}: ${d}` : label;
		super(display ? `glowcap error ${code}: ${display}` : `glowcap error ${code}`);
		this.detail = d;
		this.name = "GlowcapError";
	}

	/** An application protocol message, excluding runtime diagnostics and operation wrappers. */
	applicationMessage(): string | null {
		return this.code === BROKEN && this.breakCause.isApplication() ? this.detail : null;
	}

	/** Whether the operation refused an unverified peer identity. */
	isPeerIdentityUnverified(): boolean {
		return this.breakCause.isPeerIdentityUnverified();
	}

	/** Whether every route to the exporter failed. */
	isExporterUnreachable(): boolean {
		return this.breakCause.isExporterUnreachable();
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
	constructor(public readonly reason: string, cause: BreakCause = new BreakCause()) {
		super(BROKEN, reason, cause);
		this.name = "VowBroken";
	}
}

/** A durable publication the remote Host has forgotten. This is the
 * application-facing lifecycle fact behind CapTP's canonical
 * `unknown swissnum` break: consumers can reconcile retained sturdyrefs
 * without branching on protocol text. */
export class PublicationNotFound extends VowBroken {
	constructor(reason: string, cause: BreakCause) {
		super(reason, cause);
		this.name = "PublicationNotFound";
	}
}

/** Project a core-issued vow failure code into the binding's typed hierarchy. */
export function vowFailure(code: number, reason: string, rawCause: RawBreakCause = new BreakCause()): GlowcapError {
	const decoded = BreakCause.fromRaw(rawCause);
	const cause = decoded ?? new BreakCause();
	const failure = code === BROKEN
		? cause.isPublicationNotFound(reason) ? new PublicationNotFound(reason, cause) : new VowBroken(reason, cause)
		: new GlowcapError(code, reason, cause);
	if (decoded === null) {
		retainSecondaryFailure(
			failure,
			new GlowcapError(INTERNAL, `glowcap ABI returned unknown failure metadata ${JSON.stringify(rawCause)}`),
		);
	}
	return failure;
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

/** A failed `glowcap_host_*` call as a typed error, its diagnostic and stable
 * name read from the driver archive's own slots so it never scrapes the core's
 * unrelated one. */
export function hostError(code: number): GlowcapError {
	const raw = new Uint8Array(L.BREAK_CAUSE_SIZE);
	hostS.glowcap_host_last_error_cause(raw);
	return vowFailure(
		code,
		hostLastError() ?? `host call failed (code ${code})`,
		readBreakCause(new DataView(raw.buffer)),
	);
}

/** As `check`, for `glowcap_host_*` calls. */
export function checkHost(code: number): void {
	if (code !== OK) throw hostError(code);
}

export { BreakCause, BreakContext, BreakOrigin, BreakReason } from "@glowcap/abi";
