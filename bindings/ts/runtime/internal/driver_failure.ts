// The one TypeScript projection of driver failures. Event failures and
// deterministic provider/release barriers share the same typed facts; the
// binding copies borrowed names and attaches the first counted consequence,
// but owns no transport or lifecycle policy.

import { DRIVER_FAILURE_ABI_VERSION, INTERNAL, OK, WOULD_BLOCK } from "@glowcap/abi";
import { GlowcapError, retainSecondaryFailure } from "../errors.ts";
import { type CarrierFailure, decodeCarrierFailure } from "../carrier_failure.ts";
import { loopS } from "./ffi/driver.ts";
import { ffi, NULL, type Ptr } from "./ffi/runtime.ts";
import { L } from "./layout.ts";
import { ab, readBytes, readErrorSlot } from "./seam.ts";

const utf8 = new TextDecoder("utf-8", { fatal: true });

export function driverLastError(): string | null {
	return readErrorSlot(loopS.glowcap_driver_last_error);
}

export function checkDriver(rc: number): void {
	if (rc !== OK) throw new GlowcapError(rc, driverLastError() ?? undefined);
}

export interface DriverFailure {
	readonly primaryResult: number;
	readonly primaryName: string;
	readonly secondaryResult: number;
	readonly secondaryCount: number;
	readonly secondaryName: string;
	readonly carrierFailure: CarrierFailure | null;
}

export interface DriverCallOutcome {
	readonly code: number;
	readonly failure: DriverFailure | null;
	readonly error: GlowcapError | null;
}

function text(ptr: Ptr, len: bigint, field: string): string {
	if (len === 0n) {
		return "";
	}
	if (ptr === NULL) throw new GlowcapError(INTERNAL, `driver returned null ${field} with nonzero length`);
	try {
		return utf8.decode(readBytes(ptr, len));
	} catch {
		throw new GlowcapError(INTERNAL, `driver returned non-UTF-8 ${field}`);
	}
}

export function driverFailureError(failure: DriverFailure, operation: string): GlowcapError {
	const detail = failure.primaryName.length > 0
		? `${operation} failed: ${failure.primaryName}`
		: `${operation} failed`;
	const error = new GlowcapError(failure.primaryResult, detail);
	error.carrierFailure = failure.carrierFailure;
	if (failure.secondaryCount > 0) {
		retainSecondaryFailure(
			error,
			new GlowcapError(failure.secondaryResult, failure.secondaryName),
			failure.secondaryCount,
		);
	}
	return error;
}

function decodeRecord(code: number, bytes: Uint8Array, operation: string): DriverCallOutcome {
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	const failure: DriverFailure = {
		primaryResult: view.getInt32(L.DRIVER_FAILURE_PRIMARY_RESULT_OFF, true),
		primaryName: text(
			L.getPtr(view, L.DRIVER_FAILURE_PRIMARY_NAME_OFF),
			L.getUsize(view, L.DRIVER_FAILURE_PRIMARY_NAME_LEN_OFF),
			"primary failure name",
		),
		secondaryResult: view.getInt32(L.DRIVER_FAILURE_SECONDARY_RESULT_OFF, true),
		secondaryCount: view.getUint32(L.DRIVER_FAILURE_SECONDARY_COUNT_OFF, true),
		secondaryName: text(
			L.getPtr(view, L.DRIVER_FAILURE_SECONDARY_NAME_OFF),
			L.getUsize(view, L.DRIVER_FAILURE_SECONDARY_NAME_LEN_OFF),
			"secondary failure name",
		),
		carrierFailure: decodeCarrierFailure(
			view.getUint32(L.DRIVER_FAILURE_CARRIER_PHASE_OFF, true),
			view.getUint32(L.DRIVER_FAILURE_CARRIER_DETAIL_FLAGS_OFF, true),
			view.getUint32(L.DRIVER_FAILURE_CARRIER_VERIFICATION_FLAGS_OFF, true),
			view.getUint32(L.DRIVER_FAILURE_CARRIER_PEER_ALERT_OFF, true),
			view.getInt32(L.DRIVER_FAILURE_CARRIER_ENGINE_CODE_OFF, true),
		),
	};
	if (code === OK) {
		if (
			failure.primaryResult === OK && failure.secondaryResult === OK &&
			failure.secondaryCount === 0 && failure.primaryName === "" && failure.secondaryName === "" &&
			failure.carrierFailure === null
		) return { code, failure: null, error: null };
		throw new GlowcapError(INTERNAL, `${operation} returned success with failure data`);
	}
	if (failure.primaryResult !== code || failure.primaryName === "") {
		throw new GlowcapError(INTERNAL, `${operation} returned an inconsistent failure record`);
	}
	if (
		(failure.secondaryCount === 0 && (failure.secondaryResult !== OK || failure.secondaryName !== "")) ||
		(failure.secondaryCount > 0 && (failure.secondaryResult === OK || failure.secondaryName === ""))
	) throw new GlowcapError(INTERNAL, `${operation} returned an inconsistent secondary failure`);
	return { code, failure, error: driverFailureError(failure, operation) };
}

/** Invoke one driver barrier with a fresh versioned caller-owned record. */
export function driverCall(
	operation: string,
	call: (out: Uint8Array<ArrayBuffer>) => number,
): DriverCallOutcome {
	const bytes = new Uint8Array(L.DRIVER_FAILURE_SIZE);
	const view = new DataView(bytes.buffer);
	view.setUint32(L.DRIVER_FAILURE_ABI_VERSION_OFF, DRIVER_FAILURE_ABI_VERSION, true);
	L.setUsize(view, L.DRIVER_FAILURE_STRUCT_SIZE_OFF, L.DRIVER_FAILURE_SIZE);
	const code = call(ab(bytes));
	try {
		return decodeRecord(code, bytes, operation);
	} catch (error) {
		return {
			code,
			failure: null,
			error: error instanceof GlowcapError
				? error
				: new GlowcapError(INTERNAL, `${operation} failure projection: ${String(error)}`),
		};
	}
}

/** Pointer-form convenience for FFI package registration. */
export function addDriverProvider(
	call: (provider: Ptr, out: Uint8Array<ArrayBuffer>) => number,
	provider: Uint8Array,
): void {
	const outcome = driverCall("driver add_provider", (out) => call(ffi.pointerOf(provider), out));
	if (outcome.error !== null) throw outcome.error;
}

/** Request one listener stop. False means FFI retirement is committed and
 * the loop must keep stepping before the same identity can be claimed. */
export function closeDriverListener(handle: Ptr, listener: bigint): boolean {
	const outcome = driverCall(
		"driver listener_close",
		(out) => loopS.glowcap_driver_listener_close(handle, listener, out),
	);
	if (outcome.code === WOULD_BLOCK) return false;
	if (outcome.error !== null) throw outcome.error;
	return true;
}
