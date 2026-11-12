// What Rooms says when something does not work.
//
// A refusal here does three jobs:
//
// 1. What happened, in the reader's terms.
// 2. What they can do next, when there is something.
// 3. The exact cause, for whoever is debugging.
//
// The same screen is the engineering tool, so a friendly sentence must not
// drop the error code. The cause rides along, in parentheses or in the
// detail card, under a sentence that stands without it. The unreadable-value
// arm of `failureView` is the worked example.

// Import the taxonomy only, never `errors.ts`: reading a `VowBroken` carrier
// needs `@glowcap/runtime`, a host module the browser bundle must not contain.
import {
	ROOMS_FAILURES,
	type RoomsErrorCode,
	roomsErrorIn,
	type RoomsFailureRetry,
	structuredFailure,
} from "../error_codes.ts";
import { retryCountdown, retryLimit } from "./admission.ts";
import { LOCAL_REFUSALS, type LocalRefusalCode, type LocalRefusalKey } from "./local_refusals.ts";

type FailureRetry = RoomsFailureRetry | "unknown";
export interface FailureView {
	readonly code: string;
	readonly subject: string;
	readonly retry: FailureRetry;
	readonly summary: string;
	readonly action: string | null;
	readonly detail: string;
}

/** A local refusal has one catalog key for its code, sentence and retry advice.
 * Internal invariants remain plain errors. A cause is diagnostic detail only. */
export class LocalRefusal extends Error {
	readonly code: LocalRefusalCode;
	readonly retry: RoomsFailureRetry;
	constructor(key: LocalRefusalKey, options?: ErrorOptions) {
		const definition = LOCAL_REFUSALS[key];
		super(definition.summary, options);
		this.name = "LocalRefusal";
		this.code = `local-${key}`;
		this.retry = definition.retry;
	}
}

/** Causes supply diagnostics, never classification or retry authority. */
function diagnosticText(cause: unknown): string {
	if (cause == null) return "";
	if (Array.isArray(cause)) return cause.map(diagnosticText).filter(Boolean).join("\n");
	if (cause instanceof LocalRefusal) return diagnosticText(cause.cause) || cause.code;
	return cause instanceof Error ? cause.message : String(cause);
}

/** One bounded, machine-readable answer for every caught failure. Known Rooms
 * refusals use Rust's definition, and the page's own refusals say their own
 * instruction. Unknown carriers keep their diagnostic and get no retry
 * advice. */
export function failureView(err: unknown): FailureView {
	if (err instanceof LocalRefusal) {
		const cause = diagnosticText(err.cause);
		return {
			code: err.code,
			subject: "request",
			retry: err.retry,
			summary: err.message,
			action: null,
			detail: cause,
		};
	}
	const typed = roomsErrorIn(err);
	if (typed !== null) {
		const definition = ROOMS_FAILURES[typed.code];
		// Validated advice says when, in whole seconds. The delay leaves the
		// detail, which names the limited work and its owner in the reader’s words.
		const delay = typed.retryAfterMs;
		if (delay != null && typed.advice != null) {
			return {
				code: typed.code,
				...definition,
				action: retryCountdown(Math.ceil(delay / 1000)),
				detail: retryLimit(typed.advice),
			};
		}
		return { code: typed.code, detail: typed.detail, ...definition };
	}
	const detail = err instanceof Error ? err.message : String(err);
	const failure = structuredFailure(err);
	// -2 is an argument glowcap refused to read: a locator, a link, or a swiss
	// number that does not parse. Text that stopped short is the mistake the
	// reader can act on. It suggests instead of diagnosing, because the code
	// does not say where the text went wrong.
	if (failure?.status === -2) {
		return {
			code: "unreadable-value",
			subject: "address",
			retry: "after-request-change",
			summary: "Rooms couldn't read that address or link.",
			action: "Check it's all there, from ocapn:// to the end.",
			detail,
		};
	}
	// -12 is a broken call. Only this reason from glowcap establishes denial, and
	// detail that merely contains the word says nothing about access.
	if (failure?.status === -12 && failure.reason === "Denied") {
		return {
			code: "access-denied",
			subject: "access",
			retry: "after-state-change",
			summary: "This access doesn't allow that action.",
			action: "Ask whoever shared it to review the permissions.",
			detail,
		};
	}
	return {
		code: "unexpected",
		subject: "operation",
		retry: "unknown",
		summary: "Rooms couldn't complete that action.",
		action: "Try again. If it keeps failing, report the text in parentheses.",
		detail,
	};
}

// The arms of `failureView` that read an untyped error keep its whole
// message as the detail, which already names itself.
const UNTYPED: ReadonlySet<string> = new Set(["unexpected", "access-denied", "unreadable-value"]);
export function renderFailure(view: FailureView): string {
	const said = view.action === null ? view.summary : `${view.summary} ${view.action}`;
	if (view.detail === "") return said;
	// A Rooms refusal is named by its code.
	const cause = UNTYPED.has(view.code) ? view.detail : `${view.code}: ${view.detail}`;
	return `${said} (${cause})`;
}

/** A failure in the reader's words, with its cause kept.
 *
 * A caught failure is a glowcap or Rooms error carrying a code, and a person reads a
 * sentence. A caller that hands `error.message` to a notice skips this
 * conversion, and the screen shows whatever the wire said.
 *
 * An unknown failure gets the generic summary and keeps the diagnostic that
 * exposed the gap. */
export function refusalText(err: unknown): string {
	return renderFailure(failureView(err));
}

/** A refusal whose next step counts down live beside it: what happened and
 * its cause, without a "try again in" that would stand still. */
export function refusalBesideCountdown(err: unknown): string {
	return renderFailure({ ...failureView(err), action: null });
}

/** An unexplained failure while the Rooms server this browser connects through
 * turns it away. That server is the cause a person can do something about,
 * and Settings, under Connection, is where. */
export const relayUnreachable = (host: string, detail: string) =>
	`Rooms couldn't reach the Rooms server at ${host}, which this browser connects through. Rooms keeps trying. To use another server, open Settings, under Connection. (${detail})`;

/** This browser stands between a public page and a server on the person's own
 * computer or network, asking once or refusing until they allow it. */
export const browserBlocks = (permission: "prompt" | "denied") =>
	permission === "denied"
		? "This browser blocks this page from reaching servers on your computer or network. Allow local network access for this site in the browser's site settings"
		: "This browser asks before this page reaches a server on your computer or network. Allow it when the browser asks";

/** A reach through a server that did not get through: the page's Rooms
 * server, or with none the relay door a directory's address or a session's
 * link named. A browser sees only a closed socket, so both causes are named,
 * and the server is the one address a person can check. `detail` is the break's
 * own words when the dial reported them, and empty when it reported another
 * door's refusal instead. */
export const doorUnreachable = (subject: "directory" | "session", relayHost: string, detail: string) =>
	`Rooms couldn't reach that ${subject} through the server at ${relayHost}. It may be off, or that server isn't answering.${
		detail === "" ? "" : ` (${detail})`
	}`;
/** The same reach while this browser stands between the page and a relay on
 * the person's own computer or network. */
export const doorBlocked = (permission: "prompt" | "denied", detail: string) =>
	`${browserBlocks(permission)}, then connect again. (${detail})`;

/** An unexplained failure to reach a directory while the relay answers. A
 * browser sees only a closed socket, so the two causes it cannot tell apart are
 * both named, and the original words follow for whoever is debugging. */
export const directoryUnreachable = (host: string, detail: string) =>
	`Rooms couldn't reach that directory. The Rooms server at ${host} may not forward to it, or the directory isn't answering. Try again in a moment, or check the Rooms server in Settings, under Connection. (${detail})`;

/** Whether the rest of an error belongs in a card as well as where it
 * appeared.
 *
 * A short refusal stays with the field, notice, or tile it describes. A
 * locator, a paragraph, or anything that would push that control off the page
 * still shows that something went wrong in place, and the card holds the rest. */
export function needsErrorDetail(text: string): boolean {
	if (text.includes("\n")) return true;
	if (/ocapn:\/\//i.test(text)) return true;
	return [...text].length > 96;
}

/** What the card is called, from the kind of notice that opened it. */
export function errorDetailTitle(kind: "failure" | "warning" | "success"): string {
	return kind === "failure" ? "What went wrong" : "The full message";
}

/** The cause when a reach broke on the way, which is the relay or the peer
 * and never the pasted link: a peer the dial could not reach, or a dial
 * failure (-8) that carries no code. Null for any other failure, including a
 * denial the peer answered. */
export function transportBreak(error: unknown): string | null {
	if (roomsErrorIn(error)?.code === "peer-unreachable") {
		return error instanceof Error ? error.message : structuredFailure(error)?.reason ?? null;
	}
	const failure = structuredFailure(error);
	return failure?.status === -8 ? failure.reason : null;
}

/** Whether a call failed because the connection it travelled on is gone: the
 * connection closed under it (-7), or the reach broke on the way. False for
 * anything the other side answered. */
export function connectionLost(error: unknown): boolean {
	return structuredFailure(error)?.status === -7 || transportBreak(error) != null;
}

/** What one act calls the failures it can name more exactly than the layer
 * that reported them. That layer says a peer could not be reached. The act
 * knows whether it reached for a member or a session. */
export type FailureNames = ReadonlyMap<RoomsErrorCode, RoomsErrorCode>;
export function namedFailure(view: FailureView, names: ReadonlyMap<string, RoomsErrorCode>): FailureView {
	const named = names.get(view.code);
	return named == null ? view : { ...view, code: named, ...ROOMS_FAILURES[named] };
}

/** What a session capability has to look like before it is worth trying.
 *
 * The establishment screen and the Settings attach card both ask this first.
 * It catches the two mistakes readers make, and neither is worth a round trip
 * to the peer. The parser's own answer is `UriParseError`, which does not say
 * which of a reader's several ocapn:// strings to use. */
export function sessionCapabilityRefusal(capability: string): string {
	if (capability === "") return "";
	if (!capability.startsWith("ocapn://")) return "That doesn't look like a session link. They start with ocapn://.";
	if (!capability.includes("/s/")) {
		return "That's a server address, not a session link. " +
			"A session link has /s/ in it, after the address.";
	}
	return "";
}
