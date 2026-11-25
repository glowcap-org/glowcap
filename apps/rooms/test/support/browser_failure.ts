// Failures as a test meets them: the browser binding's error, and the code a
// refusal the page makes itself carries.
import { LocalRefusal } from "../../lib/text/failure.ts";

/** The binding's error for `status` and `reason`. A refusal Rooms names itself
 * carries its `code`, and a refusal with no binding status has a null one. */
export function browserFailure(
	status: number | null,
	reason: string,
	code: string | null = null,
	detail = reason,
): Error {
	return Object.assign(new Error(`glowcap error ${status}: ${reason}`), { status, reason, code, detail });
}

/** The codes Rust raises for this side's own session, and so projects with no
 * binding status. Every other code rides a break the binding reported. */
const OWN_SESSION_CODES: ReadonlySet<string> = new Set([
	"session-unreachable",
	"session-request-timed-out",
	"session-not-reached-yet",
]);

/** The failure a reach of the session ended with, as Rust projects `code`: a
 * line this side's own session raised has no binding status, and any other is
 * a break a peer wrote. */
export function reachFailure(reason: string, code: string): Error {
	return browserFailure(OWN_SESSION_CODES.has(code) ? null : -12, reason, code);
}

/** The code of a refusal the page made itself, or `error` unchanged, so an
 * assertion on the code shows any other failure as it is. */
export function refusalCode(error: unknown): unknown {
	return error instanceof LocalRefusal ? error.code : error;
}
