// The Rooms failure carrier. Code membership and recovery metadata are
// generated from Rust's application authority in `failure_data.ts`; this file
// only reconstructs that typed cause from the generic Glowcap error display.

import {
	ADMISSION_OWNERS,
	ADMISSION_SCOPES,
	MAX_RETRY_DELAY_MS,
	ROOMS_ERROR_CODES,
	type RoomsErrorCode,
} from "./failure_data.ts";
export * from "./failure_data.ts";

const CODES: ReadonlySet<string> = new Set(ROOMS_ERROR_CODES);

/** A failure with a machine-readable code. The message the wire carries is
 * `"<code>: <detail>"`, so a peer can reconstruct the code with `RoomsError.from`. */
export class RoomsError extends Error {
	constructor(readonly code: RoomsErrorCode, readonly detail: string) {
		super(`${code}: ${detail}`);
		this.name = "RoomsError";
	}

	/** Validated server delay. Other failures and malformed metadata confer no
	 * permission to schedule a retry. The delay never promises admission. */
	get retryAfterMs(): number | null {
		if (this.code !== "rate-limited") return null;
		const match = /^retry-after-ms=(\d+); scope=([a-z-]+)(?:; owner=([a-z-]+))?$/.exec(this.detail);
		if (match === null || !(ADMISSION_SCOPES as readonly string[]).includes(match[2])) return null;
		if (match[3] != null && !(ADMISSION_OWNERS as readonly string[]).includes(match[3])) return null;
		const delay = Number(match[1]);
		return Number.isSafeInteger(delay) && delay >= 1 && delay <= MAX_RETRY_DELAY_MS ? delay : null;
	}

	get retryScope(): string | null {
		if (this.retryAfterMs == null) return null;
		const start = this.detail.indexOf("; scope=") + "; scope=".length;
		const end = this.detail.indexOf("; owner=", start);
		return this.detail.slice(start, end < 0 ? undefined : end);
	}
	/** Reconstruct the canonical reason or the generic Glowcap error wrapper.
	 * Code-shaped text inside detail is never promoted to a machine code. */
	static from(reason: string): RoomsError | null {
		let payload = reason;
		if (payload.startsWith("glowcap error ")) {
			const split = payload.indexOf(": ");
			if (split < 0) return null;
			const statusText = payload.slice("glowcap error ".length, split);
			if (!/^-?\d+$/.test(statusText)) return null;
			const status = Number(statusText);
			if (!Number.isInteger(status) || status < -2_147_483_648 || status > 2_147_483_647) return null;
			payload = payload.slice(split + 2);
		}
		const split = payload.indexOf(": ");
		const code = split < 0 ? payload : payload.slice(0, split);
		if (!CODES.has(code)) return null;
		return new RoomsError(code as RoomsErrorCode, split < 0 ? "" : payload.slice(split + 2));
	}
}

/** The code out of an ordinary caught error, for a consumer with no native
 * break carrier. `errors.ts` adds the native `VowBroken` arm. */
export function roomsErrorInMessage(err: unknown): RoomsError | null {
	if (err instanceof RoomsError) return err;
	return RoomsError.from(err instanceof Error ? err.message : String(err));
}
