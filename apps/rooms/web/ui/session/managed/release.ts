// Giving up one receipt: the session answers a release with one word, and a
// `running` answer is asked again until the receipt's job ends or its bound
// passes. `released` and `kept` end the wait.
import { RoomsError, SESSION_UNREACHABLE } from "../../../../lib/error_codes.ts";
import { RUNNING_BOUND_MS } from "../../../../lib/limits.ts";
import { isReceiptRelease, type ReceiptRelease } from "../../../../lib/session_content_data.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { invariant } from "../../../../lib/invariant.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import type { LinkClock } from "./link.ts";
import type { Stamp } from "./link_port.ts";

/** How a release ends: `released`, or `kept` when the receipt's result was
 * already adopted, so the workspace holds what it returned and the release
 * changed nothing. */
export type ReleaseEnd = Exclude<ReceiptRelease, "running">;

/** How long the page waits before asking again after a `running` answer. */
export const RELEASE_ASK_MS = 2_000;

/** What waiting between two asks needs of the page. */
export interface ReleaseWait {
	readonly clock: Pick<LinkClock, "now" | "after">;
	stopped(): boolean;
	isCurrent(stamp: Stamp): boolean;
	change(): number;
	wait(change: number, signal?: AbortSignal): Promise<void>;
}

/** When a release stops asking: `RUNNING_BOUND_MS` after the first
 * `running` answer, over whichever link that came, or null before one. The
 * gesture that waits makes it and shares it only between its own asks, over
 * one link or the next, so a person who asks again later starts a new bound.
 * A `released` or `kept` answer ends the wait. */
export interface ReleaseBound {
	deadline: number | null;
}

/** Release `request`, which travels the link `stamp` names, and return the
 * session's answer once it is `released` or `kept`. A `running` answer
 * changed nothing, so the same request is asked again every `RELEASE_ASK_MS`
 * until the session answers otherwise or `since`'s deadline passes, which
 * fails with the refusal `bound` names, without asking again. A closed page
 * ends the wait, and a newer link ends it as a lost connection, for the
 * caller to ask again over that link with the same `since`. A refusal stands,
 * and an answer that is none of the words fails with that answer as its
 * cause. */
export async function releaseReceipt(
	request: { release(): Promise<unknown> },
	stamp: Stamp,
	page: ReleaseWait,
	bound: LocalRefusalKey,
	since: ReleaseBound = { deadline: null },
): Promise<ReleaseEnd> {
	stillRunning(page, since, bound);
	let ended: ReleaseEnd | null = null;
	while (ended == null) {
		const answer: unknown = await request.release();
		if (!isReceiptRelease(answer)) {
			throw new LocalRefusal("release-unconfirmed", {
				cause: `the session answered a release with ${shown(answer)}`,
			});
		}
		switch (answer) {
			case "released":
			case "kept":
				ended = answer;
				break;
			case "running": {
				const now = page.clock.now();
				since.deadline ??= now + RUNNING_BOUND_MS;
				stillRunning(page, since, bound);
				await paced(page, stamp, Math.min(RELEASE_ASK_MS, since.deadline - now));
				break;
			}
			default: {
				// A new answer fails this typecheck until its case is written.
				const undecided: never = answer;
				invariant(false, `undecided release answer: ${String(undecided)}`);
			}
		}
	}
	since.deadline = null;
	return ended;
}

/** Throw the refusal `bound` names once `since`'s deadline has passed. */
function stillRunning(page: ReleaseWait, since: ReleaseBound, bound: LocalRefusalKey): void {
	if (since.deadline == null || page.clock.now() < since.deadline) return;
	throw new LocalRefusal(bound, {
		cause: `the session still answered running ${RUNNING_BOUND_MS} ms after its first running answer`,
	});
}

function shown(answer: unknown): string {
	if (typeof answer === "string") return JSON.stringify(answer);
	const kind = typeof answer;
	return answer !== null && (kind === "object" || kind === "function") ? `a ${kind}` : String(answer);
}

/** Wait `ms` on the page's clock. Each page change wakes the wait to see
 * whether the page closed or a newer link replaced `stamp`, and either ends
 * it with that failure. */
async function paced(page: ReleaseWait, stamp: Stamp, ms: number): Promise<void> {
	const until = page.clock.now() + ms;
	waiting(page, stamp);
	while (page.clock.now() < until) {
		const change = page.change();
		const tick = Promise.withResolvers<void>();
		const cancel = page.clock.after(until - page.clock.now(), () => tick.resolve());
		const abort = new AbortController();
		try {
			await Promise.race([tick.promise, page.wait(change, abort.signal)]);
		} finally {
			cancel();
			abort.abort();
		}
		waiting(page, stamp);
	}
}

/** Throw why the wait ends once the page closed or a newer link replaced `stamp`. */
function waiting(page: ReleaseWait, stamp: Stamp): void {
	if (page.stopped()) throw new LocalRefusal("session-closed");
	if (!page.isCurrent(stamp)) throw new RoomsError(SESSION_UNREACHABLE, "a newer link replaced this one");
}
