// What Rooms says when something does not work.
//
// A refusal here does three jobs, and a refusal that does fewer is unfinished:
//
// 1. What happened, in the reader's terms.
// 2. What they can do next, when there is something.
// 3. The exact cause, kept, for whoever is debugging.
//
// The third is why these are not simply plain-language rewrites. The same
// screen is the engineering tool, and a sentence that throws away the native
// error code to sound friendly has helped nobody: the reader still cannot act,
// and the operator has lost the one thing they needed. So the cause rides
// along, in parentheses or in the detail card, under a sentence that stands
// without it.
//
// `locatorRefusal` is the worked example and was the shape before this file
// existed. The rest of the product is being brought to it.

// The taxonomy only, never `errors.ts`: reading a native break carrier needs
// `@glowcap/runtime`, a host module the browser bundle must not contain, and
// the page is the consumer that most needs these sentences.
import { ROOMS_FAILURES, roomsErrorInMessage, type RoomsFailureRetry } from "../error_codes.ts";

export type FailureRetry = RoomsFailureRetry | "unknown";
export interface FailureView {
	readonly code: string;
	readonly subject: string;
	readonly retry: FailureRetry;
	readonly summary: string;
	readonly action: string | null;
	readonly detail: string;
}

/** One bounded, machine-readable answer for every caught failure. Known Rooms
 * refusals use Rust's definition; unknown carriers keep their diagnostic but
 * receive no invented retry authority. */
export function failureView(err: unknown): FailureView {
	const typed = roomsErrorInMessage(err);
	if (typed !== null) {
		const definition = ROOMS_FAILURES[typed.code];
		return { code: typed.code, detail: typed.detail, ...definition };
	}
	return {
		code: "unexpected",
		subject: "operation",
		retry: "unknown",
		summary: "Rooms couldn't complete that action.",
		action: "Check the diagnostic before trying again.",
		detail: err instanceof Error ? err.message : String(err),
	};
}

export function renderFailure(view: FailureView): string {
	const said = view.action === null ? view.summary : `${view.summary} ${view.action}`;
	if (view.detail === "") return said;
	const cause = view.code === "unexpected" ? view.detail : `${view.code}: ${view.detail}`;
	return `${said} (${cause})`;
}

/** A failure in the reader's words, with its cause kept.
 *
 * This is the boundary the whole file exists for. Above it a caught failure is
 * a native error carrying a code; below it a person reads a sentence. A caller
 * that hands `error.message` to a notice instead has skipped the boundary, and
 * what reaches the screen is whatever the wire said.
 *
 * A failure this cannot name keeps its original words rather than being
 * flattened into an empty result: unknown failures receive the generic summary
 * while retaining the diagnostic that exposed the gap. */
export function refusalText(err: unknown): string {
	return renderFailure(failureView(err));
}

/** Whether the rest of an error belongs in a card rather than only where it
 * appeared.
 *
 * A short refusal stays with the field, the notice, or the tile it describes.
 * A locator, a paragraph, or anything that would shove that control off the
 * page is the same fact: the place it appeared still says that something went
 * wrong, and the card is where the rest of it is read. */
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
 * What arrives here is a native error code and a diagnostic, which says
 * nothing a reader can act on. What they can act on is a paste that stopped
 * short, so the sentence offers that and keeps the original words after it
 * for whoever is debugging.
 *
 * It offers rather than diagnoses, because the same shape carries refusals
 * this cannot tell apart: a peer that answered and declined reads exactly
 * like a link that was never whole. Telling a reader their link is truncated
 * when the peer simply said no sends them to check the one thing that was
 * never wrong. `noun` names what the link was meant to be. */
export function locatorRefusal(why: string, noun: string): string {
	if (why === "" || !why.startsWith("glowcap error")) return why;
	return `That ${noun} didn't work. Check you pasted the whole thing, from ocapn:// to the end. (${why})`;
}

/** What a session capability has to look like before it is worth trying.
 *
 * Both places that take one — the establishment screen and the Settings attach
 * card — ask this first, because the two mistakes it catches are the ones a
 * reader actually makes, and neither is worth a round trip to the peer to
 * find out. The parser's own answer to either is `UriParseError`, which tells
 * a reader nothing about which of their several ocapn:// strings they should
 * have reached for. */
export function sessionCapabilityRefusal(capability: string): string {
	if (capability === "") return "";
	if (!capability.startsWith("ocapn://")) return "That doesn't look like a session link. They start with ocapn://.";
	if (!capability.includes("/s/")) {
		return "That's a server address, not a session link. " +
			"A session link has /s/ in it, after the address.";
	}
	return "";
}
