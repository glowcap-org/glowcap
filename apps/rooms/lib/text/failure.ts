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
// detail card, under a sentence that stands without it. `locatorRefusal` is
// the worked example.

// Import the taxonomy only, never `errors.ts`: reading a native break carrier
// needs `@glowcap/runtime`, a host module the browser bundle must not contain.
import { ROOMS_FAILURES, roomsErrorInMessage, type RoomsFailureRetry } from "../error_codes.ts";

type FailureRetry = RoomsFailureRetry | "unknown";
interface FailureView {
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

export function renderFailure(view: FailureView): string {
	const said = view.action === null ? view.summary : `${view.summary} ${view.action}`;
	if (view.detail === "") return said;
	const cause = view.code === "unexpected" || view.code === "access-denied"
		? view.detail
		: `${view.code}: ${view.detail}`;
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

/** A refusal in the reader's words for a pasted link that was not taken.
 *
 * The native error code and diagnostic give a reader nothing to act on. A
 * paste that stopped short is something they can act on, so the sentence
 * suggests it and keeps the original words after it for whoever is debugging.
 *
 * It suggests instead of diagnosing, because a peer that answered and declined
 * reads like a link that was never whole. `noun` names what the link was meant
 * to be. */
export function locatorRefusal(why: string, noun: string): string {
	if (why === "" || !why.startsWith("glowcap error")) return why;
	return `That ${noun} didn't work. Check you pasted the whole thing, from ocapn:// to the end. (${why})`;
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
