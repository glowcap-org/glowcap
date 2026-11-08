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

// Import the taxonomy only, never `errors.ts`: reading a native break carrier
// needs `@glowcap/runtime`, a host module the browser bundle must not contain.
import { ROOMS_FAILURES, roomsErrorInMessage, type RoomsFailureRetry } from "../error_codes.ts";

type FailureRetry = RoomsFailureRetry | "unknown";
export interface FailureView {
	readonly code: string;
	readonly subject: string;
	readonly retry: FailureRetry;
	readonly summary: string;
	readonly action: string | null;
	readonly detail: string;
}

/** One bounded, machine-readable answer for every caught failure. Known Rooms
 * refusals use Rust's definition. Unknown carriers keep their diagnostic and
 * get no retry advice. */
export function failureView(err: unknown): FailureView {
	const typed = roomsErrorInMessage(err);
	if (typed !== null) {
		const definition = ROOMS_FAILURES[typed.code];
		return { code: typed.code, detail: typed.detail, ...definition };
	}
	const detail = err instanceof Error ? err.message : String(err);
	// -2 is an argument glowcap refused to read: a locator, a link, or a swiss
	// number that does not parse. Text that stopped short is the mistake the
	// reader can act on. It suggests instead of diagnosing, because the code
	// does not say where the text went wrong.
	if (detail.startsWith("glowcap error -2: ")) {
		return {
			code: "unreadable-value",
			subject: "address",
			retry: "after-request-change",
			summary: "Rooms couldn't read that address or link.",
			action: "Check it's all there, from ocapn:// to the end.",
			detail,
		};
	}
	// -12 is a broken call. Only this native reason establishes denial, and
	// detail that merely contains the word says nothing about access.
	if (detail === "glowcap error -12: Denied") {
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
		action: "Check the diagnostic before trying again.",
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
 * A caught failure is a native error carrying a code, and a person reads a
 * sentence. A caller that hands `error.message` to a notice skips this
 * conversion, and the screen shows whatever the wire said.
 *
 * An unknown failure gets the generic summary and keeps the diagnostic that
 * exposed the gap. */
export function refusalText(err: unknown): string {
	return renderFailure(failureView(err));
}

/** An unexplained failure while the Rooms server this browser connects through
 * turns it away. That server is the cause a person can do something about,
 * and Settings > Reachability is where. */
export const relayUnreachable = (host: string, detail: string) =>
	serverUnreachable(host, "Rooms keeps trying. To use another server, open Settings, then Reachability.", detail);
/** A break through the Rooms server this browser connects through. `remedy`
 * is what the screen saying it offers, since each one changes the server
 * from somewhere else. */
export const serverUnreachable = (host: string, remedy: string, detail: string) =>
	`Rooms can't reach the Rooms server at ${host}, which this browser connects through. ${remedy} (${detail})`;

/** An unexplained failure to reach a directory while the relay answers. A
 * browser sees only a closed socket, so the two causes it cannot tell apart are
 * both named, and the original words follow for whoever is debugging. */
export const directoryUnreachable = (host: string, detail: string) =>
	`Rooms couldn't reach that directory. This browser connects through the Rooms server at ${host}, which may not forward to it, or the directory isn't answering. (${detail})`;

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
 * and never the pasted link: a broken call (-12) wrapping the break's own
 * glowcap error. Null for any other failure, including a denial the peer
 * answered, which -12 carries with no error inside. */
export function transportBreak(error: unknown): string | null {
	const view = failureView(error);
	return view.code === "unexpected" && /^glowcap error -12: glowcap error -\d+:/.test(view.detail)
		? view.detail
		: null;
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
