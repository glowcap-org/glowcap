import {
	CLOSE_GRACE_FINITE,
	CLOSE_GRACE_UNBOUNDED,
	CLOSE_GRACE_UNSPECIFIED,
	CLOSE_MAX_GRACE_MS,
	CLOSE_OPTIONS_ABI_VERSION,
	INTERNAL,
	INVALID_ARGUMENT,
	LIFECYCLE_ACTIVE,
	LIFECYCLE_CLOSED,
	LIFECYCLE_FINISHING,
	LIFECYCLE_TERMINATING,
	PENDING_CANCEL,
	PENDING_FINISH,
} from "@pancake/abi";
import { PancakeError } from "./errors.ts";
import { L } from "./internal/layout.ts";

/** What explicit close does with operations admitted before its barrier.
 * Omitted options cancel. Finish always names its grace budget explicitly;
 * `null` is the deliberate unbounded form. */
export type CloseOptions =
	| {
		readonly pending?: "cancel";
		readonly graceMs?: never;
	}
	| {
		readonly pending: "finish";
		readonly graceMs: number | null;
	};

/** Whether final native release crossed its ownership boundary. */
export function releaseConsumed(code: number): boolean {
	return code !== INVALID_ARGUMENT;
}

/** Decode the closed/not-closed fact without allowing a future or corrupted
 * native discriminant to masquerade as ordinary progress forever. */
export function lifecycleClosed(raw: number): boolean {
	switch (raw) {
		case LIFECYCLE_ACTIVE:
		case LIFECYCLE_FINISHING:
		case LIFECYCLE_TERMINATING:
			return false;
		case LIFECYCLE_CLOSED:
			return true;
		default:
			throw new PancakeError(INTERNAL, `pancake ABI returned unknown lifecycle state ${raw}`);
	}
}

function pendingId(pending: CloseOptions["pending"]): number {
	if (pending === undefined || pending === "cancel") return PENDING_CANCEL;
	if (pending === "finish") return PENDING_FINISH;
	return 0xffff_ffff;
}

/** Marshal the versioned shared C close options through the active target layout. */
export function encodeCloseOptions(options: CloseOptions = {}): Uint8Array {
	const graceMs = options.graceMs;
	if (
		graceMs !== undefined && graceMs !== null &&
		(!Number.isInteger(graceMs) || graceMs < 0 || graceMs > CLOSE_MAX_GRACE_MS)
	) {
		throw new PancakeError(INVALID_ARGUMENT, `graceMs must be an integer from 0 through ${CLOSE_MAX_GRACE_MS}`);
	}
	const out = new Uint8Array(L.CLOSE_OPTIONS_SIZE);
	const view = new DataView(out.buffer);
	view.setUint32(
		L.CLOSE_OPTIONS_ABI_VERSION_OFF,
		CLOSE_OPTIONS_ABI_VERSION,
		true,
	);
	L.setUsize(view, L.CLOSE_OPTIONS_STRUCT_SIZE_OFF, out.length);
	view.setUint32(L.CLOSE_OPTIONS_PENDING_OFF, pendingId(options.pending), true);
	view.setUint32(
		L.CLOSE_OPTIONS_GRACE_MODE_OFF,
		graceMs === undefined ? CLOSE_GRACE_UNSPECIFIED : graceMs === null ? CLOSE_GRACE_UNBOUNDED : CLOSE_GRACE_FINITE,
		true,
	);
	view.setUint32(L.CLOSE_OPTIONS_GRACE_MS_OFF, graceMs ?? 0, true);
	return out;
}

export function monotonicNowMs(): bigint {
	return BigInt(Math.trunc(performance.now()));
}
