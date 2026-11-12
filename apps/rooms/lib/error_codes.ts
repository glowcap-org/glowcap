// Rooms codes come from the application catalog. Browser errors carry fields;
// Deno peers carry a canonical Rooms reason inside a typed partner break.
import {
	ADMISSION_OWNERS,
	ADMISSION_SCOPES,
	MAX_RETRY_DELAY_MS,
	ROOMS_ERROR_CODES,
	type RoomsErrorCode,
} from "./failure_data.ts";
export * from "./failure_data.ts";

function isCode(value: unknown): value is RoomsErrorCode {
	return typeof value === "string" && ROOMS_ERROR_CODES.some((code) => code === value);
}
export interface RetryAdvice {
	readonly retryAfterMs: number;
	readonly scope: (typeof ADMISSION_SCOPES)[number];
	readonly owner: (typeof ADMISSION_OWNERS)[number] | null;
}
function retryAdvice(delay: unknown, scope: unknown, owner: unknown): RetryAdvice | null {
	if (typeof delay !== "number" || !Number.isSafeInteger(delay) || delay < 1 || delay > MAX_RETRY_DELAY_MS) {
		return null;
	}
	const selectedScope = ADMISSION_SCOPES.find((value) => value === scope);
	if (selectedScope === undefined) return null;
	const selectedOwner = owner == null ? null : ADMISSION_OWNERS.find((value) => value === owner);
	if (selectedOwner === undefined) return null;
	return { retryAfterMs: delay, scope: selectedScope, owner: selectedOwner };
}
/** Decode advice only at the Deno peer's Rooms wire boundary. Browser advice has
 * already been decoded by Rust and arrives as fields. */
function wireAdvice(code: RoomsErrorCode, detail: string): RetryAdvice | null {
	if (code !== "rate-limited") return null;
	const match = /^retry-after-ms=(\d+); scope=([a-z-]+)(?:; owner=([a-z-]+))?$/.exec(detail);
	return match == null ? null : retryAdvice(Number(match[1]), match[2], match[3]);
}
export class RoomsError extends Error {
	constructor(readonly code: RoomsErrorCode, readonly detail: string, readonly advice = wireAdvice(code, detail)) {
		super(`${code}: ${detail}`);
		this.name = "RoomsError";
	}
	get retryAfterMs(): number | null {
		return this.advice?.retryAfterMs ?? null;
	}
	get retryScope(): string | null {
		return this.advice?.scope ?? null;
	}
	/** Read the head segment of a protocol refusal. Display wrappers and detail
	 * never select a code. */
	static from(reason: string): RoomsError | null {
		const split = reason.indexOf(": ");
		const code = split < 0 ? reason : reason.slice(0, split);
		return isCode(code) ? new RoomsError(code, split < 0 ? "" : reason.slice(split + 2)) : null;
	}
}

/** The browser's Rust boundary projects these fields on a JavaScript Error.
 * No display text can impersonate this carrier. */
export function structuredFailure(value: unknown): { status: number | null; reason: string } | null {
	if (typeof value !== "object" || value === null || !("status" in value) || !("reason" in value)) return null;
	if (typeof value.reason !== "string") return null;
	if (value.status != null && (typeof value.status !== "number" || !Number.isInteger(value.status))) return null;
	return { status: typeof value.status === "number" ? value.status : null, reason: value.reason };
}
export function roomsErrorIn(value: unknown): RoomsError | null {
	if (value instanceof RoomsError) return value;
	if (structuredFailure(value) === null || typeof value !== "object" || value === null) return null;
	if (!("code" in value) || !isCode(value.code) || !("detail" in value) || typeof value.detail !== "string") {
		return null;
	}
	const advice = value.code === "rate-limited" && "retryAfterMs" in value && "scope" in value
		? retryAdvice(value.retryAfterMs, value.scope, "owner" in value ? value.owner : null)
		: null;
	return new RoomsError(value.code, value.detail, advice);
}

/** Retain Rust's failure fields when an effect outcome becomes an exception. */
export function projectedError(value: unknown, fallback: string): Error {
	const failure = structuredFailure(value);
	if (failure === null) return new Error(fallback);
	const typed = roomsErrorIn(value);
	return Object.assign(
		new Error(failure.reason),
		failure,
		typed == null ? {} : {
			code: typed.code,
			detail: typed.detail,
			retryAfterMs: typed.retryAfterMs,
			scope: typed.advice?.scope ?? null,
			owner: typed.advice?.owner ?? null,
		},
	);
}
